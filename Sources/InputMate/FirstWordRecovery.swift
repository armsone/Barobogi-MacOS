import AppKit
import ApplicationServices
import Carbon

/// 빈 입력창에서 첫 단어를 입력할 때 실시간 한글 입력 화면을 유지하면서,
/// 공백 또는 문장 부호 입력 시점에 두벌식 조합 의도와 실제 입력 결과를 비교하여 불일치할 때만 안전하게 교정한다.
/// AXValue 직접 쓰기, 클립보드, 커서 선택 조작을 일절 수행하지 않는다.
@MainActor
final class FirstWordRecovery {
    var isEnabled = true {
        didSet {
            if !isEnabled {
                cancelTracking()
                clearCompleted()
            }
        }
    }

    var targetBundleIDs: Set<String> = ["com.openai.codex"] {
        didSet {
            if targetBundleIDs != oldValue {
                cancelTracking()
                clearCompleted()
            }
        }
    }

    var replacementProvider: (() -> [String: String])?
    var textFormatter: (([Character]) -> String?)?
    var onWarning: ((String) -> Void)?

    private struct TrackingState {
        let element: AXUIElement
        let pid: pid_t
        let sourceID: String
        let baselinePrefix: String
        var recordedKeys: [Character]
    }

    /// 완료된 입력창에 묶인 AXObserver. 해제 전에 알림과 런루프 소스를 반드시 제거한다.
    private final class CompletedWatch {
        let element: AXUIElement
        let pid: pid_t
        weak var owner: FirstWordRecovery?
        var observer: AXObserver?
        var source: CFRunLoopSource?
        var sawContent = false
        var isActive = true

        init(element: AXUIElement, pid: pid_t, owner: FirstWordRecovery) {
            self.element = element
            self.pid = pid
            self.owner = owner
        }

        func stop() {
            isActive = false
            if let observer {
                AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
                if let source {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                }
            }
            source = nil
            observer = nil
        }

        deinit { stop() }
    }

    private var tracking: TrackingState?
    // 첫 단어 처리를 마친 입력창. Return, 같은 입력창이 내용 있음에서 빈 상태로 돌아온 시점(새 초안),
    // 다른 입력창에서의 새 세션 전까지 두 번째 단어를 추적하지 않는다.
    private var completedElement: AXUIElement?
    private var completedWatch: CompletedWatch?
    private var submissionBoundarySeen = false
    private var probeSuppressed = false

    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?

    private static let syntheticMarker: Int64 = 0x5447_4B54
    private static let maxChunkUnits = 20
    private static let blankProbeLimit = 16

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let watch = Unmanaged<CompletedWatch>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor [weak watch] in
            guard let watch, watch.isActive, let owner = watch.owner else { return }
            owner.completedValueChanged(watch)
        }
    }

    private static let shiftDoubledLetters: Set<Character> = ["q", "w", "e", "r", "t", "o", "p"]
    private static let navigationKeyCodes: Set<Int64> = [
        114, 115, 116, 117, 119, 121, 123, 124, 125, 126
    ]

    private static let ansiKeycodeToLetter: [Int64: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l",
        38: "j", 40: "k", 45: "n", 46: "m"
    ]

    init() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelTracking()
                self?.dropCompletedIfOwnerGone()
            }
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelTracking()
            }
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
    }

    func reset() {
        cancelTracking()
        probeSuppressed = false
    }

    func pointerPressed() {
        cancelTracking()
        probeSuppressed = false
    }

    func cancelTracking() {
        tracking = nil
    }

    func handleEvent(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Bool {
        // 자체 생성한 합성 이벤트는 필터를 통과
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return false
        }

        // 마우스 클릭 시: 추적 취소, 클릭 자체는 통과
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            cancelTracking()
            probeSuppressed = false
            if completedElement != nil, completedWatch == nil { submissionBoundarySeen = true }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // 수정자 플래그 변경 시(Shift, CapsLock 등)
        if type == .flagsChanged {
            if keyCode == 57 { // CapsLock
                cancelTracking()
            }
            return false
        }

        // keyUp: 모든 키 뗌 이벤트는 네이티브 통과
        if type == .keyUp {
            return false
        }

        guard type == .keyDown else {
            return false
        }

        // Esc(53): 사용자의 명시적 취소 액션
        if keyCode == 53 {
            cancelTracking()
            probeSuppressed = false
            return false
        }

        // 보조 키(Cmd, Ctrl, Opt) 조합: 단축키 동작 시 추적 취소 후 통과
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            cancelTracking()
            probeSuppressed = false
            return false
        }

        // Return(36), Enter(76): 줄바꿈 또는 메시지 전송 경계. 추적 리셋 후 통과 (파괴적 교정 없음)
        if keyCode == 36 || keyCode == 76 {
            cancelTracking()
            probeSuppressed = false
            if completedWatch == nil { submissionBoundarySeen = true }
            return false
        }

        // Backspace / Delete(51): 사용자 백스페이스 발생 시 조합 모호성 방지를 위해 즉시 추적 무효화 후 통과
        if keyCode == 51 {
            cancelTracking()
            return false
        }

        // 방향키 및 탐색 키: 커서 이동 시 추적 취소 후 통과
        if Self.navigationKeyCodes.contains(keyCode) {
            cancelTracking()
            probeSuppressed = false
            return false
        }

        // 공백(49) 또는 문장 부호: 첫 단어 경계. 필요 시 비교 및 교정 후 통과
        let isSpace = (keyCode == 49)
        let typedChar = typedCharacter(of: event)
        let isPunctuation = typedChar.map { Self.isPunctuationDelimiter($0) } ?? false

        if isSpace || isPunctuation {
            probeSuppressed = false
            if tracking != nil {
                handleDelimiter(proxy: proxy)
            }
            return false
        }

        // QWERTY 영문 글자 입력 처리
        if let letter = qwertyLetter(for: event) {
            handleLetter(letter, keyCode: keyCode)
            return false
        }

        // 그 외 키(숫자, Tab 등): 추적 취소 후 통과
        cancelTracking()
        return false
    }

    // MARK: - 문자 처리 및 추적

    private func handleLetter(_ letter: Character, keyCode: Int64) {
        if var active = tracking {
            // 소유권이 확인된 상태에서는 글자마다 동기 AX 조회를 하지 않고 저비용 가드 확인 후 키 열 기록
            guard isEnabled,
                  !IsSecureEventInputEnabled(),
                  frontmostPID() == active.pid,
                  currentInputSourceID == active.sourceID,
                  active.recordedKeys.count < 64 else {
                cancelTracking()
                return
            }
            active.recordedKeys.append(letter)
            tracking = active
            return
        }

        // 새 첫 단어 추적 적격성 검증
        guard isEnabled else { return }
        guard !IsSecureEventInputEnabled() else { return }
        guard !probeSuppressed else { return }

        guard let pid = frontmostPID() else { return }
        guard let bundleID = bundleIdentifier(for: pid), targetBundleIDs.contains(bundleID) else { return }
        guard isApple2SetInputSource else { return }
        guard let sourceID = currentInputSourceID else { return }

        guard let element = focusedElement(of: pid) else { return }

        // 이미 첫 단어가 처리된 필드인지 확인
        if let completed = completedElement {
            if CFEqual(completed, element) {
                // 관찰자가 없을 때 전송 경계 이후 빈 값이면 새 초안으로 재무장
                if completedWatch == nil, submissionBoundarySeen,
                   isEditableTextElement(element), editorBaseline(element) != nil {
                    clearCompleted()
                } else {
                    return
                }
            } else {
                clearCompleted()
            }
        }

        guard isEditableTextElement(element) else { return }

        guard let baseline = editorBaseline(element) else {
            // 초기 빈 필드 검사에 실패한 경우, 이번 세션 동안 반복적인 AX 조회를 억제
            probeSuppressed = true
            return
        }

        tracking = TrackingState(
            element: element,
            pid: pid,
            sourceID: sourceID,
            baselinePrefix: baseline.text,
            recordedKeys: [letter]
        )
    }

    // MARK: - 경계 시점 비교 및 교정

    private func handleDelimiter(proxy: CGEventTapProxy) {
        guard let active = tracking else { return }
        tracking = nil

        // 경계 시점 동기 스냅샷 검증:
        // 1. 비보안 선택 대상 앱 일치
        guard !IsSecureEventInputEnabled(),
              let pid = frontmostPID(), pid == active.pid,
              let bundleID = bundleIdentifier(for: pid), targetBundleIDs.contains(bundleID) else {
            return
        }

        // 2. 동일한 포커스 편집 가능 요소
        guard let element = focusedElement(of: pid),
              CFEqual(element, active.element),
              isEditableTextElement(element) else {
            return
        }

        // 3. 한글 2벌식 입력 소스 유지
        guard isApple2SetInputSource, currentInputSourceID == active.sourceID else {
            return
        }

        // 4. 선택 영역이 없고 캐럿이 텍스트 끝에 위치
        guard let currentText = textValue(of: element),
              let range = selectedRange(of: element),
              range.length == 0,
              range.location == currentText.utf16.count else {
            setCompleted(active.element, pid: active.pid)
            return
        }

        // 5. 초기 공백 접두사가 그대로 보존되어 있고, 그 뒤에 첫 단어만 존재
        guard currentText.hasPrefix(active.baselinePrefix) else {
            setCompleted(active.element, pid: active.pid)
            return
        }

        let actualWord = String(currentText.dropFirst(active.baselinePrefix.count))
        guard !actualWord.isEmpty else {
            setCompleted(active.element, pid: active.pid)
            return
        }

        // 64타 제한 이내 및 실제 기록된 키 개수 이하인지 검증 (이벤트 할당 전 바운드)
        guard actualWord.count <= active.recordedKeys.count else {
            setCompleted(active.element, pid: active.pid)
            return
        }

        // 첨부물/객체/추가 공백이 없는 순수 단어인지 확인
        guard !actualWord.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.isDefaultIgnorableCodePoint || $0.value == 0xFFFC
        }) else {
            setCompleted(active.element, pid: active.pid)
            return
        }

        // 기존 매퍼를 통해 실제 단어가 지원되는 한글 음절/자모로만 구성되어 있는지 확인(이모지/라틴/결합문자 등 제외)
        // 및 실제 물리 키 문자열이 기록된 물리 키의 부분수열(동일 키 포함)인지 검증
        guard let actualQwerty = DubeolsikComposer.qwerty(fromHangul: actualWord),
              Self.isSubsequence(actualQwerty, of: active.recordedKeys) else {
            setCompleted(active.element, pid: active.pid)
            return
        }

        // 예상 조합 단어 계산 (키 소유권 및 누락 키 검증 후에만 포매터 호출)
        let snapshot = replacementProvider?() ?? [:]
        let rendered = DubeolsikComposer.render(keys: active.recordedKeys)?.text ?? ""
        let composed = rendered.isEmpty ? String(active.recordedKeys) : rendered
        let expectedWord = snapshot[composed] ?? textFormatter?(active.recordedKeys) ?? composed

        guard !expectedWord.isEmpty, expectedWord != actualWord else {
            // 일치하거나 예상 단어를 만들 수 없으면 교정 불필요
            setCompleted(active.element, pid: active.pid)
            return
        }

        // 불일치 시 합성 이벤트 시퀀스 생성:
        // Right arrow(조합 확정) -> Backspace N회(실제 표시 글자 수만큼 삭제) -> Unicode 입력(예상 단어)
        var events: [CGEvent] = []
        let source = CGEventSource(stateID: .hidSystemState)

        guard let rightDown = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: true),
              let rightUp = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: false) else {
            setCompleted(active.element, pid: active.pid)
            return
        }
        rightDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        rightDown.flags = []
        rightUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        rightUp.flags = []
        events.append(rightDown)
        events.append(rightUp)

        for _ in 0..<actualWord.count {
            guard let bsDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let bsUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                setCompleted(active.element, pid: active.pid)
                return
            }
            bsDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            bsDown.flags = []
            bsUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            bsUp.flags = []
            events.append(bsDown)
            events.append(bsUp)
        }

        for chunk in Self.utf16Chunks(of: expectedWord) {
            guard let uDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let uUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                setCompleted(active.element, pid: active.pid)
                return
            }
            uDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            uDown.flags = []
            uDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            events.append(uDown)

            uUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            uUp.flags = []
            events.append(uUp)
        }

        // 모든 이벤트를 proxy를 통해 순서대로 게시 (원래 구분자 이벤트보다 앞에 전달됨)
        for event in events {
            event.tapPostEvent(proxy)
        }

        setCompleted(active.element, pid: active.pid)
    }

    private static func isSubsequence<S1: Sequence, S2: Sequence>(_ sub: S1, of target: S2) -> Bool
        where S1.Element == Character, S2.Element == Character {
        var targetIterator = target.makeIterator()
        for char in sub {
            var found = false
            while let targetChar = targetIterator.next() {
                if targetChar == char {
                    found = true
                    break
                }
            }
            if !found {
                return false
            }
        }
        return true
    }

    private func setCompleted(_ element: AXUIElement, pid: pid_t) {
        clearCompleted()
        completedElement = element
        startCompletedWatch(element, pid: pid)
    }

    private func clearCompleted() {
        completedElement = nil
        submissionBoundarySeen = false
        completedWatch?.stop()
        completedWatch = nil
    }

    private func startCompletedWatch(_ element: AXUIElement, pid: pid_t) {
        let watch = CompletedWatch(element: element, pid: pid, owner: self)
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.observerCallback, &created) == .success, let observer = created,
              AXObserverAddNotification(
                observer, element, kAXValueChangedNotification as CFString,
                Unmanaged.passUnretained(watch).toOpaque()
              ) == .success else {
            return
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        watch.observer = observer
        watch.source = source
        completedWatch = watch
    }

    private func completedValueChanged(_ watch: CompletedWatch) {
        guard watch === completedWatch, let completed = completedElement, CFEqual(completed, watch.element),
              !IsSecureEventInputEnabled(), isEditableTextElement(watch.element) else { return }
        let count = characterCount(of: watch.element)
        if watch.sawContent {
            if let count, count > Self.blankProbeLimit { return }
            guard editorBaseline(watch.element) != nil else { return }
            clearCompleted()
            probeSuppressed = false
        } else {
            if count == 0 { return }
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(watch.element, kAXValueAttribute as CFString, &valueRef) == .success,
                  let text = valueRef as? String,
                  !text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return }
            watch.sawContent = true
        }
    }

    private func dropCompletedIfOwnerGone() {
        guard let watch = completedWatch else { return }
        if NSRunningApplication(processIdentifier: watch.pid)?.isTerminated ?? true {
            clearCompleted()
        }
    }

    private func characterCount(of element: AXUIElement) -> Int? {
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let count, CFGetTypeID(count) == CFNumberGetTypeID() else { return nil }
        return (count as! NSNumber).intValue
    }

    private static func utf16Chunks(of text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(character.utf16)
            if !current.isEmpty, current.count + units.count > maxChunkUnits {
                chunks.append(current)
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func bundleIdentifier(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private var isApple2SetInputSource: Bool {
        currentInputSourceID == "com.apple.inputmethod.Korean.2SetKorean"
    }

    private func focusedElement(of pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else {
            return nil
        }
        return element
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleName = role as? String,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(roleName) else {
            return false
        }
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success:
            if (subrole as? String) == "AXSecureTextField" {
                return false
            }
        case .noValue, .attributeUnsupported:
            break
        default:
            return false
        }
        var enabled: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) {
        case .success:
            if (enabled as? Bool) != true {
                return false
            }
        case .noValue, .attributeUnsupported:
            break
        default:
            return false
        }
        return true
    }

    private func textValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else {
            return nil
        }
        return text
    }

    private func editorBaseline(_ element: AXUIElement) -> (text: String, caret: Int)? {
        guard let text = textValue(of: element) else { return nil }
        guard text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return nil
        }
        guard let range = selectedRange(of: element),
              range.location >= 0, range.location == text.utf16.count else {
            return nil
        }
        guard range.length == 0 else {
            return nil
        }
        return (text, range.location)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRange
        ) == .success,
              let selectedRange, CFGetTypeID(selectedRange) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = selectedRange as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func qwertyLetter(for event: CGEvent) -> Character? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let letter = Self.ansiKeycodeToLetter[keyCode] else {
            return nil
        }
        if event.flags.contains(.maskShift) {
            return Self.shiftDoubledLetters.contains(letter) ? Character(letter.uppercased()) : letter
        }
        return letter
    }

    private func typedCharacter(of event: CGEvent) -> Character? {
        var codeUnits = [UniChar](repeating: 0, count: 4)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &codeUnits)
        let string = String(utf16CodeUnits: codeUnits, count: length)
        guard string.count == 1 else {
            return nil
        }
        return string.first
    }

    private static func isPunctuationDelimiter(_ character: Character) -> Bool {
        character.isPunctuation || character.isSymbol
    }
}

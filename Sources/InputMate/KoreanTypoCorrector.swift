import AppKit
import ApplicationServices
import Carbon
import OSLog

// 영문 자판(두벌식 위치)으로 잘못 입력한 한글 구절을 구분자 입력 시점에 자동으로 교정한다.
// 모든 판단은 기기 내부의 보수적 휴리스틱으로만 수행한다.
@MainActor
final class KoreanTypoCorrector {
    var isEnabled = false {
        didSet {
            if isEnabled {
                refreshReplacements()
            } else {
                cancelPendingReplacements()
            }
        }
    }

    /// 입력 전체 비활성 / legacy conflict / stop 시 보류된 교체 및 작업을 모두 취소하고
    /// 늦은 비동기 결과가 입력을 바꾸지 않도록 차단한다.
    func cancelPendingReplacements() {
        manualTask?.cancel()
        manualTask = nil
        manualRequestID &+= 1
        pendingManualQuote = nil
        generation &+= 1
        asyncSelection?.aborted = true
        asyncSelection = nil
        uncertainSelection = nil
        pendingCorrection = nil
        lastCorrection = nil
        resetLegacy()
        liveWord = nil
        liveQuote = nil
        liveMode = .idle
        liveKoreanContext = false
    }

    // 기능별 실제 독립 토글
    var isAutomaticCorrectionEnabled = false {
        didSet {
            if !isAutomaticCorrectionEnabled {
                resetLegacy()
                liveWord = nil
                liveQuote = nil
                liveMode = .idle
                liveKoreanContext = false
            }
        }
    }
    var isManualWordConversionEnabled = true {
        didSet {
            if oldValue && !isManualWordConversionEnabled {
                invalidateManual()
            }
        }
    }
    var isSentenceTranslationEnabled = true {
        didSet {
            if oldValue && !isSentenceTranslationEnabled {
                invalidateManual()
            }
        }
    }
    var isPersonalDictionaryEnabled = true
    var isPersonalDictionaryAutoLearnEnabled = true

    // 커서 복원을 확인하지 못해 현재 키를 막았을 때 알린다. 입력 내용은 전달하지 않는다.
    var onLivePaused: (() -> Void)?
    // 수동 변환('')을 하지 못했을 때의 안내. 원문 내용은 담지 않는다.
    var onManualConversionMessage: ((String) -> Void)?
    var prefersKorean = false {
        didSet {
            if prefersKorean != oldValue { reset() }
        }
    }

    // 시스템 텍스트 대치 캐시 스냅샷을 읽기 전용으로 제공한다.
    var cachedReplacements: [String: String] {
        cachedReplacementShortcuts
    }

    // 영문+한글 어미 혼용 보정, 한글 자판 영문 복원, 직후 되돌리기를 함께 켜고 끈다.
    var correctsMixedAndEnglish = true

    // 입력 중 실시간 한영 전환. 켜져 있으면 지원되는 입력창에서는 구분자 기반 엔진 대신 이 엔진이 단어를 맡는다.
    var continuousSwitching = true {
        didSet {
            if continuousSwitching != oldValue { reset() }
        }
    }

    // 방금 적용한 교정을 Delete 한 번으로 되돌리기 위한 기록이다. 기기 메모리에만 두고 저장하지 않는다.
    private struct AppliedCorrection {
        let element: AXUIElement
        let applicationPID: pid_t?
        let displayed: String
        let original: String
        let wordKey: String
        let previousInputSource: TISInputSource?
        let at: Date
        // 교정 당시 입력 소스. 되돌릴 때 같은 소스여야 한다.
        var inputSourceID: String?
        // 이 교정이 개인 사전에 새로 추가한 쌍. 바로 되돌릴 때 그 항목만 지운다.
        var learnedSource: String? = nil
        var learnedReplacement: String? = nil
        // 수동 ('') 변환으로 만든 기록. 자동 교정 옵션과 무관하게 되돌릴 수 있다.
        var isManualConversion: Bool = false
    }

    private var buffer = ""
    private var lastCorrection: AppliedCorrection?
    private var cachedReplacementShortcuts: [String: String] = [:]
    private var cachedReplacementSequences: [(sequence: String, shortcut: String)] = []
    private var replacementShortcuts: [String: String] = [:]
    private var replacementSequences: [(sequence: String, shortcut: String)] = []
    // 이번 실행 동안 같은 단어를 세 번 되돌리면 그 단어는 교정에서 제외한다(저장하지 않음).
    private var undoCounts: [String: Int] = [:]
    private var hasKoreanContext = false
    // 직전 입력이 어포스트로피(')였는지 기억해 연속 두 번 입력(수동 강제 변환)을 감지한다.
    private var pendingApostrophe = false
    private var lastKeystrokeAt = Date.distantPast
    // reset()마다 올라가는 세대 번호. 예약된 교정은 예약 시점의 세대와 같을 때만 실행된다.
    private var generation = 0
    // 우리가 직접 일으킨 입력기 전환만 알아보기 위한 한시적 표식과, 전환이 확인된 뒤에 확정할 되돌리기 기록이다.
    private var selfSwitch: (id: String, deadline: Date)?
    private var pendingCorrection: AppliedCorrection?
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    // 실시간 전환 상태. 입력 중인 한 단어의 키만 메모리에 두며 로그·저장·전송하지 않는다.
    private var liveMode = LiveMode.idle
    private var liveWord: LiveWord?
    private var liveKoreanContext = false
    // 화면에 직접 표시한 단어 뒤에 첫 어포스트로피가 전달된 상태. 바로 다음 키가 어포스트로피일 때만 쓰며 다른 키는 비운다.
    private struct LiveQuote {
        let element: AXUIElement
        let applicationPID: pid_t
        let sourceID: String
        let keys: String
        let displayed: String
        let wordStart: Int
    }
    private var liveQuote: LiveQuote?
    // 수동 변환 트리거 키 종류. 어포스트로피('') 또는 역슬래시 두 개이며 두 키는 같은 종류여야 한다.
    @MainActor private enum ManualTrigger {
        case apostrophe
        case backslash

        func matches(_ character: Character) -> Bool {
            switch self {
            case .apostrophe: return KoreanTypoCorrector.isApostropheLike(character)
            case .backslash: return character == "\\"
            }
        }
    }
    // 수동 변환 트리거의 첫 키 입력 시점의 입력창·커서. 변환 대상 단어는 두 번째 키가 화면에 확정된 뒤에 읽는다.
    private struct PendingManualQuote {
        let element: AXUIElement
        let pid: pid_t
        let sourceID: String
        let generation: Int
        let keystrokeAt: Date
        let trigger: ManualTrigger
        // 첫 키가 들어가기 전의 접힌 커서 위치
        let caret: Int
    }

    // 비동기로 선택이 반영되는 앱에서 우리가 선택을 만든 구간의 보호 상태. 이 구간에는 선택을 지울 수 있는 키를 막는다.
    private final class AsyncSelectionGuard {
        let element: AXUIElement
        let pid: pid_t
        let caret: Int
        // 사용자가 직접 클릭·방향키·앱 전환으로 선택을 정했으면 true. 이후 우리는 선택을 건드리지 않는다.
        var aborted = false
        // 보호 구간에 들어온 키. 버리지 않고 보관했다가 접힌 커서가 확인된 뒤 순서대로 다시 전달한다.
        var queued: [CGEvent] = []
        var dropped = 0
        init(element: AXUIElement, pid: pid_t, caret: Int) {
            self.element = element
            self.pid = pid
            self.caret = caret
        }
    }
    private var asyncSelection: AsyncSelectionGuard?
    private var pendingManualQuote: PendingManualQuote?
    // 비동기 번역은 한 번에 하나만 둔다. 새 입력·초기화·앱 변경 때 requestID가 바뀌고 작업이 취소된다.
    private var manualRequestID = 0
    private var manualTask: Task<Void, Never>?
    // 실시간 전환을 쓰지 않을 앱과 입력창(쓰기 확인에 실패한 곳). 쓰기 허용 근거로는 쓰지 않는 제외 목록이다.
    private var liveDisabledPIDs: Set<pid_t> = []
    private var unverifiedElements: [AXUIElement] = []
    private var liveFailuresByPID: [pid_t: Int] = [:]
    private var asynchronousSelectionBundles: [String: Bool] = [:]
    // 우리가 지정한 선택 범위가 이 입력창에 남아 있을 수 있다. 접힌 커서가 확인되거나 사용자가 클릭·방향키로
    // 선택을 바꾸기 전까지 그 선택을 지울 수 있는 키는 보내지 않는다. reset()으로는 지우지 않는다.
    private var uncertainSelection: (element: AXUIElement, pid: pid_t, caret: Int)? {
        didSet { uncertainCollapsedSince = nil }
    }
    // 접힌 커서가 처음 관찰된 시각. 오래된 단일 읽기 값만으로 보호를 풀지 않도록 일정 시간 같은 값이 유지돼야 한다.
    private var uncertainCollapsedSince: Date?
    // 마지막 비동기 교체에서 다시 전달했거나 전달하지 못한 보호 구간 키 수
    private var lastReplayedKeyCount = 0
    private var lastLostKeyCount = 0
    private var asyncUndoStarted = false
    private let logger = Logger(subsystem: "com.armsone.TrackpadGuard", category: "KoreanCorrection")

    private static let syntheticMarker: Int64 = 0x5447_4B54
    private static let maxBufferLength = 80
    private static let staleInterval: TimeInterval = 8
    private static let punctuationDelimiters: Set<Character> = [".", ",", "!", "?", ";", ":"]
    // tab, delete, esc, keypad enter, help, home, pgup, fwd delete, end, pgdn, 방향키
    private static let resetKeyCodes: Set<Int64> = [48, 51, 53, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126]
    // 내용을 바꾸지 않는 이동 키: esc, home, pgup, end, pgdn, 방향키
    private static let navigationKeyCodes: Set<Int64> = [53, 115, 116, 119, 121, 123, 124, 125, 126]

    init() {
        refreshReplacements()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.refreshReplacements()
                self.reset()
            }
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.handleInputSourceChange()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.refreshReplacements()
            }
        }
        appObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.refreshReplacements()
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
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let appObserver {
            NotificationCenter.default.removeObserver(appObserver)
        }
    }

    func reset() {
        resetLegacy()
        liveWord = nil
        liveQuote = nil
        invalidateManual()
        liveMode = .idle
        liveKoreanContext = false
    }

    // 수동 변환 대기 상태와 진행 중인 번역을 모두 무효로 한다.
    private func invalidateManual() {
        pendingManualQuote = nil
        manualRequestID &+= 1
        manualTask?.cancel()
        manualTask = nil
    }

    // 클릭은 커서·선택을 사용자가 직접 정하므로 남은 선택 보호도 끝낸다.
    func pointerPressed() {
        uncertainSelection = nil
        asyncSelection?.aborted = true
        asyncSelection = nil
        reset()
    }

    // 비동기 선택 교체 중에는 읽기 값이 늦게 갱신될 수 있어 읽기로 판단하지 않고, 선택을 지울 수 있는 키를 그대로 막는다.
    // 방향키·앱 전환은 사용자가 선택을 직접 정한 것으로 보고 보호를 놓는다(이후 우리는 선택을 건드리지 않는다).
    private func blocksForAsyncSelection(_ event: CGEvent) -> Bool {
        guard let state = asyncSelection else { return false }
        if Self.navigationKeyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            state.aborted = true
            asyncSelection = nil
            return false
        }
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { return false }
        if let front = frontmostPID(), front != state.pid {
            state.aborted = true
            asyncSelection = nil
            return false
        }
        // 새 키를 버리지 않고 보관한다. 교체가 끝나 접힌 커서가 확인되면 같은 순서로 다시 전달한다.
        if state.queued.count < 64, let copy = event.copy() {
            state.queued.append(copy)
        } else {
            state.dropped += 1
        }
        return true
    }

    // 같은 입력창에 확인하지 못한 선택이 남아 있으면 그 선택을 지울 수 있는 글자·Delete·Tab·Return을 막는다.
    // 매 키마다 접힌 커서로 되돌리기를 다시 시도하고, 확인되면 그 키부터 평소대로 처리한다.
    private func blocksForUncertainSelection(_ event: CGEvent) -> Bool {
        guard let pending = uncertainSelection else { return false }
        if Self.navigationKeyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            uncertainSelection = nil
            return false
        }
        // 단축키는 사용자의 명시적 명령이므로 막지 않되 보호는 유지한다.
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { return false }
        let front = frontmostPID()
        if let front, front != pending.pid {
            uncertainSelection = nil
            return false
        }
        if front == pending.pid, let current = focusedElement(of: pending.pid) {
            if !CFEqual(current, pending.element) {
                uncertainSelection = nil
                return false
            }
            // 접힌 읽기 값이 한 번만 보이는 것은 오래된 캐시일 수 있어, 같은 커서가 일정 시간 유지될 때만 보호를 푼다.
            if let collapsed = collapsedCaret(of: pending.element), collapsed == pending.caret
                || selectedRange(of: pending.element)?.length == 0 {
                if let since = uncertainCollapsedSince {
                    if Date().timeIntervalSince(since) >= 0.25 {
                        uncertainSelection = nil
                        return false
                    }
                } else {
                    uncertainCollapsedSince = Date()
                }
            } else {
                uncertainCollapsedSince = nil
                _ = setSelection(CFRange(location: pending.caret, length: 0), of: pending.element)
            }
        }
        onLivePaused?()
        return true
    }

    // 구분자 기반 엔진의 상태만 비운다. 예약된 교정도 세대 번호가 바뀌어 취소된다.
    private func resetLegacy() {
        buffer.removeAll(keepingCapacity: true)
        pendingApostrophe = false
        hasKoreanContext = false
        lastCorrection = nil
        pendingCorrection = nil
        selfSwitch = nil
        generation &+= 1
    }

    // 우리가 요청한 전환이 확인되면 되돌리기 기록을 확정하고, 그 밖의 입력기 변경은 사용자 전환으로 보고 초기화한다.
    private func handleInputSourceChange() {
        if let expected = selfSwitch, Date() < expected.deadline, currentInputSourceID == expected.id {
            selfSwitch = nil
            lastCorrection = pendingCorrection
            lastCorrection?.inputSourceID = expected.id
            pendingCorrection = nil
            return
        }
        reset()
    }

    func handleKeyDown(_ event: CGEvent) -> Bool {
        guard isEnabled else { return false }
        // 교정 시 우리가 게시한 합성 이벤트는 다시 처리하지 않는다.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return false }
        let typedChar = typedCharacter(of: event)
        let hasCommandModifier = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        let isQuoteKey = !hasCommandModifier && typedChar.map { Self.isApostropheLike($0) || $0 == "\\" } == true
        // 두 번째 어포스트로피가 아닌 모든 새 입력은 대기 중인 수동 변환과 진행 중인 번역을 무효로 한다.
        if blocksForAsyncSelection(event) { return true }
        if !(isQuoteKey && pendingManualQuote != nil) { invalidateManual() }
        if blocksForUncertainSelection(event) { return true }

        pendingCorrection = nil
        // 교정 직후의 Delete 한 번은 되돌리기다. 되돌릴 수 없으면 일반 Delete로 그대로 전달한다.
        if let correction = lastCorrection {
            lastCorrection = nil
            asyncUndoStarted = false
            if event.getIntegerValueField(.keyboardEventKeycode) == 51,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
               undo(correction) {
                if asyncUndoStarted {
                    // 비동기 되돌리기 작업을 취소하지 않도록 수동 작업 상태는 그대로 둔다.
                    resetLegacy()
                    liveWord = nil
                    liveQuote = nil
                    liveMode = .idle
                    liveKoreanContext = false
                } else {
                    reset()
                }
                return true
            }
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // 수동 강제 변환('' 또는 두 개의 역슬래시): 두 키 모두 입력창에 그대로 전달하고, 화면에 확정된 뒤 변환한다.
        // 같은 종류의 두 번째 키일 때만 변환을 예약하며, 종류가 다르면 새 첫 키로 본다.
        if isQuoteKey, let ch = typedChar {
            let isApostrophe = Self.isApostropheLike(ch)
            let isBackslash = ch == "\\"
            if (isApostrophe && !isManualWordConversionEnabled) || (isBackslash && !isSentenceTranslationEnabled) {
                // 해당 수동 변환 옵션이 꺼져 있으면 일반 키로 통과시킨다
                return false
            }
            if let pending = pendingManualQuote, pending.trigger.matches(ch) {
                lastKeystrokeAt = Date()
                handleManualQuoteSecond()
                return false
            }
            // 첫 키도 기존 자동 엔진으로 넘기지 않는다. 지원하지 않으면 상태를 비우고 그대로 통과시킨다.
            if !recordPendingManualQuote(trigger: ch == "\\" ? .backslash : .apostrophe) { reset() }
            lastKeystrokeAt = Date()
            return false
        }

        if pendingApostrophe, let ch = typedChar, !Self.isApostropheLike(ch) {
            pendingApostrophe = false
            buffer.removeAll(keepingCapacity: true)
        }

        if isAutomaticCorrectionEnabled, continuousSwitching, let handled = handleLiveKeyDown(event) {
            // 기존 엔진의 예약 작업은 더 새로운 입력이 있으면 실행되지 않는다.
            lastKeystrokeAt = Date()
            return handled
        }

        if hasCommandModifier || Self.resetKeyCodes.contains(keyCode) {
            reset()
            return false
        }

        let now = Date()
        if now.timeIntervalSince(lastKeystrokeAt) > Self.staleInterval {
            if !buffer.isEmpty { logger.info("Correction buffer expired after an input pause") }
            reset()
        }
        lastKeystrokeAt = now

        guard let character = typedChar else {
            reset()
            return false
        }

        if Self.isApostropheLike(character) {
            return false
        }
        if pendingApostrophe {
            // 어포스트로피 한 번 뒤에 다른 키가 오면 화면과 버퍼가 어긋나므로 구절을 포기한다.
            reset()
        }

        switch character {
        case "a"..."z", "A"..."Z":
            if isAutomaticCorrectionEnabled {
                buffer.append(character)
                if buffer.count > Self.maxBufferLength { reset() }
            }
            return false
        case " ":
            return isAutomaticCorrectionEnabled ? handleDelimiter(" ") : false
        case "\r", "\n":
            return isAutomaticCorrectionEnabled ? handleDelimiter("\r") : false
        case let ch where Self.punctuationDelimiters.contains(ch):
            return isAutomaticCorrectionEnabled ? handleDelimiter(ch) : false
        default:
            reset()
            return false
        }
    }

    // MARK: - 감지

    private func handleDelimiter(_ delimiter: Character) -> Bool {
        guard !buffer.isEmpty else { return false }

        // 선택을 만들어 교체하는 두 보정은 선택이 비동기로 반영되는 앱에서는 시도하지 않는다.
        let selectionUnsafe = frontmostPID().map { selectsAsynchronously(pid: $0) } ?? false
        if correctsMixedAndEnglish, !selectionUnsafe, delimiter != "\r", delimiter != ".", !pendingApostrophe {
            let lastWord = String(buffer.split(separator: " ", omittingEmptySubsequences: false).last ?? "")
            if isKoreanInputSourceActive {
                // 한글 입력기에서는 화면이 자모로 보이므로 구분자를 막지 않고 입력이 확정된 뒤 검증해서 교체한다.
                if scheduleRestoration(of: lastWord, delimiter: delimiter) {
                    return false
                }
            } else if let split = Self.mixedSplit(of: lastWord),
                      scheduleMixedConversion(of: lastWord, split: split, delimiter: delimiter) {
                // 구분자는 그대로 입력창에 전달하고, 확정된 뒤 검증된 범위만 교체한다.
                logger.info("Mixed word correction scheduled: suffix=\(split.suffix.count, privacy: .public)")
                hasKoreanContext = delimiter == " "
                return false
            }
        }

        guard !isExcluded(buffer), replacementShortcuts[buffer] == nil, let replacement = automaticReplacement(for: buffer) else {
            logger.info("Correction skipped: candidate rejected, words=\(self.buffer.split(separator: " ").count, privacy: .public), preferKorean=\(self.prefersKorean, privacy: .public)")
            if delimiter == " " {
                // 화면에 전달되는 공백은 그대로 버퍼에도 반영해 삭제 문자 수가 어긋나지 않게 한다.
                buffer.append(" ")
                if buffer.count > Self.maxBufferLength { reset() }
            } else {
                reset()
            }
            return false
        }

        guard isSafeToCorrect else {
            reset()
            return false
        }
        let deletionCount = buffer.count
        let original = buffer + String(delimiter)
        let wordKey = buffer.lowercased()
        logger.info("Correction accepted: deleting=\(deletionCount, privacy: .public)")
        reset()
        // 두 단어로 한글 문맥이 확인되면 같은 문장의 나머지 단어도 교정한다.
        hasKoreanContext = delimiter == " "
        applyCorrection(deleting: deletionCount, replacement: replacement, delimiter: delimiter, undo: (original, wordKey))
        return true
    }

    // 테스트 가능한 순수 판별 단계. 보수적 모드는 문장 전체에 한글 신호가 하나 이상일 때 변환한다.
    func automaticReplacement(for text: String) -> String? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var converted: [String] = []
        var wordCount = 0
        var hasKoreanSignal = false
        for part in parts {
            if part.isEmpty {
                converted.append("")
                continue
            }
            guard let hangul = hangulCandidate(for: part, allowEnglishLikeWord: prefersKorean) else {
                return nil
            }
            converted.append(hangul)
            wordCount += 1
            if containsRareEnglishBigram(part) {
                hasKoreanSignal = true
            }
        }

        guard wordCount >= 2 || (hasKoreanContext && wordCount >= 1),
              prefersKorean || hasKoreanSignal || hasKoreanContext else { return nil }
        return converted.joined(separator: " ")
    }

    // MARK: - 수동 강제 변환('')

    // 개인 사전을 먼저 보고, 없으면 결정적 매핑·인명·번역 순으로 판단한다.
    private func manualConversion(for word: String) -> ManualTextConversion.Result? {
        if isPersonalDictionaryEnabled, let learned = PersonalDictionaryStore.shared.replacement(for: word) { return .synchronous(learned) }
        return ManualTextConversion.convertPrecedingWord(word)
    }

    private static func isManualWordBreak(_ character: Character) -> Bool {
        isWordBoundary(character) || punctuationDelimiters.contains(character) || isApostropheLike(character)
            || ["\"", "'", "“", "”", "/", "\\", "@", "#", "$"].contains(character)
    }

    // 커서 바로 앞의 완성된 한 단어만 돌려준다. 읽기는 65 UTF-16 단위로 제한하고, 경계를 찾지 못한 채
    // 읽기 범위가 잘린 더 긴 단어는 변환하지 않는다.
    private func precedingManualWord(of element: AXUIElement, caret: Int) -> String? {
        let window = min(caret, 65)
        guard window > 0, let text = precedingText(of: element, caret: caret, length: window) else { return nil }
        var characters: [Character] = []
        var foundBoundary = false
        for character in text.reversed() {
            if Self.isManualWordBreak(character) {
                foundBoundary = true
                break
            }
            characters.append(character)
        }
        guard foundBoundary || caret <= window else { return nil }
        let word = String(characters.reversed())
        guard !word.isEmpty, word.utf16.count <= 32 else { return nil }
        return word
    }

    // 첫 트리거 키 입력 시점: 입력창·커서를 기록한다. 이전 엔진 상태를 먼저 비운 뒤 기록하며, true면 이 키는 그대로 통과시킨다.
    private func recordPendingManualQuote(trigger: ManualTrigger) -> Bool {
        guard !IsSecureEventInputEnabled(), !focusedElementIsSecureTextField,
              let pid = frontmostPID(),
              let sourceID = currentInputSourceID,
              let element = editableFocusedElement(),
              belongs(element, to: pid),
              isMutable(element, pid: pid, sourceID: sourceID),
              let caret = collapsedCaret(of: element) else { return false }
        reset()
        pendingManualQuote = PendingManualQuote(
            element: element, pid: pid, sourceID: sourceID, generation: generation,
            keystrokeAt: Date(), trigger: trigger, caret: caret
        )
        return true
    }

    // 두 번째 트리거 키: 키 이벤트 안에서는 아무것도 쓰지 않는다. 두 키가 모두 입력창에 확정된 뒤 정확한 스냅샷을 확인해 변환한다.
    private func handleManualQuoteSecond() {
        guard let pending = pendingManualQuote else { return }
        pendingManualQuote = nil

        guard isEnabled,
              Date().timeIntervalSince(pending.keystrokeAt) <= 2.5,
              generation == pending.generation,
              frontmostPID() == pending.pid,
              belongs(pending.element, to: pending.pid),
              currentInputSourceID == pending.sourceID,
              !IsSecureEventInputEnabled(),
              !focusedElementIsSecureTextField,
              hasSameFocus(as: pending.element),
              isMutable(pending.element, pid: pending.pid, sourceID: pending.sourceID)
        else { return }

        manualTask?.cancel()
        manualRequestID &+= 1
        let requestID = manualRequestID
        manualTask = Task { @MainActor [weak self] in
            await self?.runDeferredManualConversion(pending, requestID: requestID)
        }
    }

    // 커서가 첫 키 직전 위치에서 정확히 트리거 두 개만큼(조합 글자 확정 시 한 글자 더) 이동했고, 바로 앞 두 글자가
    // 같은 종류의 트리거이며 그 앞이 완성된 한 단어일 때만 변환한다. 다른 위치의 쌍·경로·이스케이프 조각은 변환하지 않는다.
    private func runDeferredManualConversion(_ pending: PendingManualQuote, requestID: Int) async {
        // 역슬래시 두 개는 단어가 아니라 현재 줄 문장 번역이다. 어포스트로피 단어 흐름과 독립으로 처리한다.
        if pending.trigger == .backslash {
            await runDeferredLineConversion(pending, requestID: requestID)
            return
        }
        let element = pending.element
        let pid = pending.pid
        let sourceID = pending.sourceID
        var stable: (caret: Int, word: String)?
        var snapshot: (caret: Int, word: String, conversion: ManualTextConversion.Result)?
        for _ in 0..<24 {
            if Task.isCancelled || requestID != manualRequestID { return }
            guard isEnabled, frontmostPID() == pid, belongs(element, to: pid), currentInputSourceID == sourceID,
                  !IsSecureEventInputEnabled(), !focusedElementIsSecureTextField,
                  hasSameFocus(as: element) else { return }
            if let caret = collapsedCaret(of: element), (2...3).contains(caret - pending.caret),
               let markers = precedingText(of: element, caret: caret, length: 2),
               markers.count == 2, markers.allSatisfy({ pending.trigger.matches($0) }),
               let word = precedingManualWord(of: element, caret: caret - 2),
               isInteriorFragment(of: element, wordEnd: caret - 2, word: word) == false,
               !followedByTrigger(of: element, caret: caret, trigger: pending.trigger) {
                // 같은 스냅샷이 연속으로 읽힐 때만 확정으로 본다(입력기 확정 중간 상태 배제).
                if let previous = stable, previous.caret == caret, previous.word == word {
                    if let conversion = manualConversion(for: word) { snapshot = (caret, word, conversion) }
                    break
                }
                stable = (caret, word)
            } else {
                stable = nil
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let snapshot else { return }

        guard let tail = precedingText(
            of: element, caret: snapshot.caret, length: snapshot.word.utf16.count + 2
        ) else { return }
        switch snapshot.conversion {
        case .synchronous(let replacement):
            await commitManualResult(
                word: snapshot.word, finalText: replacement, element: element, pid: pid, sourceID: sourceID,
                expectedCaret: snapshot.caret, expectedText: tail, requestID: requestID
            )
        case .needsAsyncTranslation(let koreanWord):
            await runManualTranslation(
                word: snapshot.word, koreanWord: koreanWord, element: element, pid: pid, sourceID: sourceID,
                expectedCaret: snapshot.caret, expectedText: tail, requestID: requestID
            )
        }
    }

    // 현재 줄에서 트리거 앞까지의 원문(공백 포함)을 읽는다. 읽기는 상한+경계 확인용 1단위로 제한하며,
    // 줄 경계 없이 상한을 넘는 줄은 .tooLong으로 알린다.
    private func currentLinePrefix(of element: AXUIElement, markerStart: Int) -> ManualTextConversion.LinePrefix? {
        let limit = ManualTextConversion.maxLinePrefixUTF16
        let window = min(markerStart, limit + 1)
        guard window > 0, let text = precedingText(of: element, caret: markerStart, length: window) else { return nil }
        return ManualTextConversion.currentLinePrefix(fromWindow: text, windowReachesStart: markerStart <= limit + 1)
    }

    // 두 번째 역슬래시가 화면에 확정된 뒤, 현재 줄 앞부분(트리거 제외)을 안정적으로 읽어 번역 요청을 만든다.
    private func runDeferredLineConversion(_ pending: PendingManualQuote, requestID: Int) async {
        let element = pending.element
        let pid = pending.pid
        let sourceID = pending.sourceID
        var stable: (caret: Int, prefix: ManualTextConversion.LinePrefix)?
        var snapshot: (caret: Int, prefix: ManualTextConversion.LinePrefix)?
        for _ in 0..<24 {
            if Task.isCancelled || requestID != manualRequestID { return }
            guard isEnabled, frontmostPID() == pid, belongs(element, to: pid), currentInputSourceID == sourceID,
                  !IsSecureEventInputEnabled(), !focusedElementIsSecureTextField,
                  hasSameFocus(as: element) else { return }
            if let caret = collapsedCaret(of: element), (2...3).contains(caret - pending.caret),
               let markers = precedingText(of: element, caret: caret, length: 2),
               markers.count == 2, markers.allSatisfy({ pending.trigger.matches($0) }),
               let prefix = currentLinePrefix(of: element, markerStart: caret - 2),
               !followedByTrigger(of: element, caret: caret, trigger: pending.trigger) {
                if let previous = stable, previous.caret == caret, previous.prefix == prefix {
                    snapshot = (caret, prefix)
                    break
                }
                stable = (caret, prefix)
            } else {
                stable = nil
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let snapshot else { return }

        switch snapshot.prefix {
        case .tooLong:
            guard let tail = precedingText(of: element, caret: snapshot.caret, length: 2),
                  isManualTargetCurrent(element, pid: pid, sourceID: sourceID, caret: snapshot.caret, text: tail, requestID: requestID)
            else { return }
            onManualConversionMessage?("한 줄이 너무 길어 변환하지 않고 그대로 두었습니다. 줄을 나누거나 짧게 줄여 다시 시도해 주세요.")
        case .prefix(let line):
            // 바로 앞 글자가 역슬래시면 이스케이프나 세 번째 역슬래시일 수 있으므로 변환하지 않는다.
            guard !line.hasSuffix("\\"),
                  let request = ManualTextConversion.lineTranslationRequest(for: line) else { return }
            let expectedText = line + "\\\\"
            await runLineTranslation(
                line: line, request: request, element: element, pid: pid, sourceID: sourceID,
                expectedCaret: snapshot.caret, expectedText: expectedText, requestID: requestID
            )
        }
    }

    // 공백을 뺀 문장을 온디바이스 번역에 넘기고, 결과가 유효할 때만 원문(공백·트리거 포함)을 번역문으로 바꾼다.
    // 사전·월·인명·발음 표기는 쓰지 않으며, 실패하면 원문과 트리거를 그대로 둔다.
    private func runLineTranslation(
        line: String, request: ManualTextConversion.LineRequest, element: AXUIElement, pid: pid_t, sourceID: String,
        expectedCaret: Int, expectedText: String, requestID: Int
    ) async {
        guard isManualTargetCurrent(element, pid: pid, sourceID: sourceID, caret: expectedCaret, text: expectedText, requestID: requestID)
        else { return }

        var accepted: String?
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let (source, target) = request.direction == .koreanToEnglish ? ("ko", "en") : ("en", "ko")
            if await TranslationEngine.isInstalled(source: source, target: target),
               let translated = try? await TranslationEngine.translate(text: request.compact, source: source, target: target) {
                accepted = ManualTextConversion.acceptedLineTranslation(translated, for: request, originalLine: line)
            }
        }
        #endif
        guard !Task.isCancelled, requestID == manualRequestID else { return }

        guard let accepted else {
            guard isManualTargetCurrent(element, pid: pid, sourceID: sourceID, caret: expectedCaret, text: expectedText, requestID: requestID) else { return }
            onManualConversionMessage?("문장을 번역하지 못해 입력한 내용을 그대로 두었습니다. macOS 26 이상에서 설정 → 한글 교정 → 번역 준비로 한국어-영어 모델을 준비한 뒤 다시 시도해 주세요.")
            return
        }
        await commitManualResult(
            word: "", finalText: accepted, element: element, pid: pid, sourceID: sourceID,
            expectedCaret: expectedCaret, expectedText: expectedText, requestID: requestID, learnsWord: false
        )
    }

    // 단어 바로 앞이 경로·URL·이메일·이스케이프를 뜻하는 글자면 단어의 일부로 본다. 읽지 못해도 보수적으로 true.
    private func isInteriorFragment(of element: AXUIElement, wordEnd: Int, word: String) -> Bool {
        let start = wordEnd - word.utf16.count
        guard start > 0 else { return false }
        guard let before = precedingText(of: element, caret: start, length: 1), let ch = before.first else { return true }
        return ["/", "\\", "@", "#", "$"].contains(ch)
    }

    // 에디터의 자동 짝 입력으로 트리거가 한 쌍 더 생긴 경우 변환하지 않는다. 끝에서 읽지 못하면 없는 것으로 본다.
    private func followedByTrigger(of element: AXUIElement, caret: Int, trigger: ManualTrigger) -> Bool {
        var range = CFRange(location: caret, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return false }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &text
        ) == .success, let next = (text as? String)?.first else { return false }
        return trigger.matches(next)
    }

    // 요청·활성화·앱·입력창·입력 소스·보안 입력·접힌 커서·원문(따옴표 포함)이 모두 그대로인지 확인한다.
    private func isManualTargetCurrent(
        _ element: AXUIElement, pid: pid_t, sourceID: String, caret: Int, text: String, requestID: Int
    ) -> Bool {
        guard !Task.isCancelled, requestID == manualRequestID, isEnabled,
              frontmostPID() == pid, belongs(element, to: pid), currentInputSourceID == sourceID,
              !IsSecureEventInputEnabled(), !focusedElementIsSecureTextField,
              hasSameFocus(as: element), collapsedCaret(of: element) == caret else { return false }
        return precedingText(of: element, caret: caret, length: text.utf16.count) == text
    }

    private func manualResultStillValid(
        _ element: AXUIElement, pid: pid_t, sourceID: String, caret: Int, text: String
    ) -> Bool {
        guard isFocusedAndUnchanged(element, pid: pid, sourceID: sourceID),
              collapsedCaret(of: element) == caret else { return false }
        return precedingText(of: element, caret: caret, length: text.utf16.count) == text
    }

    private func runManualTranslation(
        word: String, koreanWord: String, element: AXUIElement, pid: pid_t, sourceID: String,
        expectedCaret: Int, expectedText: String, requestID: Int
    ) async {
        // 두 번째 키가 입력창에 반영될 때까지 잠시 기다린 뒤 번역을 시작한다.
        var visible = false
        for _ in 0..<20 {
            if Task.isCancelled || requestID != manualRequestID { return }
            if isManualTargetCurrent(element, pid: pid, sourceID: sourceID, caret: expectedCaret, text: expectedText, requestID: requestID) {
                visible = true
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard visible else { return }

        var translated: String?
        var failed = false
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            do {
                translated = try await TranslationEngine.translate(text: koreanWord)
            } catch {
                failed = true
            }
        } else {
            failed = true
        }
        #else
        failed = true
        #endif
        guard !Task.isCancelled, requestID == manualRequestID else { return }

        // 번역 결과가 비었거나 한글 그대로면 발음 기반 로마자 표기로 대신한다.
        var finalText: String?
        if !failed {
            let trimmed = (translated ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasHangul = trimmed.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
            if !trimmed.isEmpty, !hasHangul, trimmed != koreanWord, !trimmed.contains("\n") {
                finalText = trimmed
            } else {
                let romanized = ManualTextConversion.romanizeGeneral(koreanWord)
                if !romanized.isEmpty, !romanized.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                    finalText = romanized
                }
            }
        }
        guard let finalText, !failed else {
            // 번역 중 입력창·커서·텍스트가 바뀌었다면 안내하지 않는다.
            guard isManualTargetCurrent(element, pid: pid, sourceID: sourceID, caret: expectedCaret, text: expectedText, requestID: requestID) else { return }
            onManualConversionMessage?("번역하지 못해 입력한 내용을 그대로 두었습니다. 설정 → 한글 교정 → 번역 준비에서 한국어-영어 번역 모델을 준비한 뒤 다시 시도해 주세요.")
            return
        }

        await commitManualResult(
            word: word, finalText: finalText, element: element, pid: pid, sourceID: sourceID,
            expectedCaret: expectedCaret, expectedText: expectedText, requestID: requestID
        )
    }

    // 확정된 변환 결과를 쓴다. 대상이 요청 시점과 같은지 다시 확인하고, 선택이 비동기로 반영되는 앱은 검증형 트랜잭션을 쓴다.
    private func commitManualResult(
        word: String, finalText: String, element: AXUIElement, pid: pid_t, sourceID: String,
        expectedCaret: Int, expectedText: String, requestID: Int, learnsWord: Bool = true
    ) async {
        guard isManualTargetCurrent(element, pid: pid, sourceID: sourceID, caret: expectedCaret, text: expectedText, requestID: requestID) else { return }
        let length = expectedText.utf16.count
        let range = CFRange(location: expectedCaret - length, length: length)
        let outcome = await replaceRangeAsync(
            range, expected: expectedText, with: finalText,
            in: element, pid: pid, sourceID: sourceID, caret: expectedCaret, requestID: requestID
        )
        let lostNote = lastLostKeyCount > 0
            ? " 변환 중 입력한 키 \(lastLostKeyCount)개는 전달하지 못했으니 다시 입력해 주세요." : ""
        let replayed = lastReplayedKeyCount
        switch outcome {
        case .committed:
            manualTask = nil
            if !lostNote.isEmpty { onManualConversionMessage?("변환은 끝났습니다." + lostNote) }
            if replayed > 0 {
                // 변환 중 입력한 키를 다시 전달했으므로 되돌리기 대상이 아니다. 학습도 하지 않는다.
                reset()
                return
            }
            let finalCaret = expectedCaret - length + finalText.utf16.count
            guard manualResultStillValid(element, pid: pid, sourceID: sourceID, caret: finalCaret, text: finalText) else { return }
            var correction = AppliedCorrection(
                element: element, applicationPID: pid,
                displayed: finalText, original: expectedText,
                wordKey: word.lowercased(),
                previousInputSource: TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), at: Date(),
                inputSourceID: sourceID
            )
            correction.isManualConversion = true
            // 문장 번역은 한 단어용 개인 사전에 저장하지 않는다.
            if learnsWord && isPersonalDictionaryAutoLearnEnabled, PersonalDictionaryStore.shared.remember(source: word, replacement: finalText) {
                correction.learnedSource = word
                correction.learnedReplacement = finalText
            }
            lastCorrection = correction
        case .committedUnverified, .selectionUncertain:
            markUnverified(element, pid: pid)
            onManualConversionMessage?("변환 결과를 입력창에서 확인하지 못했습니다. 글자가 선택된 채로 남았다면 방향키를 눌러 선택을 해제한 뒤 확인해 주세요." + lostNote)
        case .selectionUnconfirmed:
            onManualConversionMessage?("입력창이 변환 결과를 받아들이지 않아 원문을 그대로 두었습니다." + lostNote)
        case .rejected:
            break
        }
    }

    private func hangulCandidate(for word: String, allowEnglishLikeWord: Bool) -> String? {
        let normalizedWord = word.lowercased()
        guard word.count >= 2,
              word.allSatisfy(Self.isASCIIQwertyLetter),
              allowEnglishLikeWord || !Self.commonEnglishWords.contains(normalizedWord) else { return nil }
        return DubeolsikComposer.compose(fromQwerty: word)
    }

    // 영어에서 흔한 두 글자 조합만으로 이루어진 단어는 영어일 수 있으므로 건드리지 않는다.
    private func containsRareEnglishBigram(_ word: String) -> Bool {
        let characters = Array(word)
        guard characters.count >= 2 else { return false }
        for index in 0..<(characters.count - 1) {
            let bigram = (String(characters[index]) + String(characters[index + 1])).lowercased()
            if !Self.commonEnglishBigrams.contains(bigram) { return true }
        }
        return false
    }

    // MARK: - 안전 확인

    // 호스트의 스마트 따옴표가 어포스트로피를 바꿔 쓴 경우도 같은 키로 본다.
    private static func isApostropheLike(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "\u{2018}"
    }

    private static func isASCIIQwertyLetter(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("A"..."Z").contains(character)
    }

    private var isSafeToCorrect: Bool {
        guard !IsSecureEventInputEnabled() else {
            logger.info("Correction skipped: secure event input")
            return false
        }
        guard !focusedElementIsSecureTextField else {
            logger.info("Correction skipped: secure text field")
            return false
        }
        // 입력기 이름만으로 판단하면 앱 안에서 영문을 입력하는 경우도 막힌다.
        // 한글 입력기에서는 커서 앞에 실제로 영문 후보가 있는 경우에만 교정한다.
        guard !isKoreanInputSourceActive || focusedTextMatchesBuffer else {
            logger.info("Correction skipped: Korean input source active without matching visible text")
            return false
        }
        return true
    }

    private var focusedTextMatchesBuffer: Bool {
        guard pendingApostrophe else { return focusedTextMatches(buffer) }
        return ["'", "\u{2019}", "\u{2018}"].contains { focusedTextMatches(buffer + $0) }
    }

    private func currentFocusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return focused as! AXUIElement
    }

    private func hasSameFocus(as element: AXUIElement) -> Bool {
        guard let current = currentFocusedElement() else { return false }
        return CFEqual(current, element)
    }

    private func focusedTextMatches(_ candidate: String) -> Bool {
        guard let element = currentFocusedElement(), let caret = collapsedCaret(of: element) else { return false }
        let length = candidate.utf16.count
        guard length > 0, caret >= length else { return false }
        return precedingText(of: element, caret: caret, length: length) == candidate
    }

    // 선택 영역이 없는 커서 위치만 돌려준다. 범위 선택 중이면 교정하지 않는다.
    private func collapsedCaret(of element: AXUIElement) -> Int? {
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRange
        ) == .success,
              let selectedRange, CFGetTypeID(selectedRange) == AXValueGetTypeID() else { return nil }
        let rangeValue = selectedRange as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }

    private func precedingText(of element: AXUIElement, caret: Int, length: Int) -> String? {
        guard length > 0, caret >= length else { return nil }
        var precedingRange = CFRange(location: caret - length, length: length)
        guard let parameter = AXValueCreate(.cfRange, &precedingRange) else { return nil }
        var precedingText: CFTypeRef?
        // 커서 바로 앞의 후보만 읽으며 입력 내용은 로그에 남기거나 저장하지 않는다.
        if AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &precedingText
        ) == .success, let text = precedingText as? String {
            return text
        }

        // 범위 조회가 없는 입력창에서는 현재 값과 커서 위치를 기기 안에서만 대조한다.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let units = Array(text.utf16)
        guard caret <= units.count else { return nil }
        return String(utf16CodeUnits: Array(units[(caret - length)..<caret]), count: length)
    }

    // 새 경로 전용: 포커스·역할·보안 여부를 모두 확인할 수 있는 편집 가능한 텍스트 요소만 돌려준다. 하나라도 불명확하면 nil.
    private func editableFocusedElement() -> AXUIElement? {
        guard !IsSecureEventInputEnabled(), let element = currentFocusedElement(),
              isEditableTextElement(element) else { return nil }
        return element
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleName = role as? String,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(roleName) else { return false }
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success:
            if (subrole as? String) == "AXSecureTextField" { return false }
        case .noValue, .attributeUnsupported:
            // 웹 편집창은 하위 역할이 없을 수 있다. 값이 없다는 응답만 허용한다.
            break
        default:
            return false
        }
        var enabled: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) {
        case .success:
            if (enabled as? Bool) != true { return false }
        case .noValue, .attributeUnsupported:
            break
        default:
            return false
        }
        return true
    }

    private func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // Chromium 계열 앱(Codex·Chrome·Electron 앱)은 접근성 선택 지정이 다른 프로세스로 비동기 전달된다. 읽기 값이 아직
    // 옛 접힌 커서를 보여 "선택이 없다"고 확인돼도 실제 입력창에는 우리가 지정한 선택이 나중에 남을 수 있어,
    // 다음 키가 그 선택을 지울 수 있다. 이런 앱에서는 사용자의 글자를 선택하는 교체를 시작하지 않는다.
    // 앱 번들 구조만 읽으며, 번들을 알 수 없으면 보수적으로 제외한다. 결과는 번들 경로별로 한 번만 계산한다.
    private func selectsAsynchronously(pid: pid_t) -> Bool {
        guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path else { return true }
        if let cached = asynchronousSelectionBundles[path] { return cached }
        let fileManager = FileManager.default
        let frameworks = path + "/Contents/Frameworks"
        let entries = (try? fileManager.contentsOfDirectory(atPath: frameworks)) ?? []
        let chromium = entries.contains { entry in
            if entry.hasSuffix("(Renderer).app") || entry == "Electron Framework.framework" { return true }
            guard entry.hasSuffix(".framework") else { return false }
            let helpers = (try? fileManager.contentsOfDirectory(
                atPath: frameworks + "/" + entry + "/Versions/Current/Helpers"
            )) ?? []
            return helpers.contains { $0.hasSuffix("(Renderer).app") }
        }
        if asynchronousSelectionBundles.count >= 64 { asynchronousSelectionBundles.removeAll() }
        asynchronousSelectionBundles[path] = chromium
        if chromium { logger.info("Selection-based replacement disabled: Chromium-based app") }
        return chromium
    }

    private func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
        var elementPID: pid_t = 0
        return AXUIElementGetPid(element, &elementPID) == .success && elementPID == pid
    }

    // 예약된 교정이 입력창을 바꾸기 직전에 호출한다. 입력·초기화·앱·포커스·보안 상태가 모두 그대로여야 한다.
    private func isUnchanged(
        generation expectedGeneration: Int, keystrokeAt: Date, pid: pid_t, element: AXUIElement
    ) -> Bool {
        guard isEnabled, correctsMixedAndEnglish,
              generation == expectedGeneration, lastKeystrokeAt == keystrokeAt,
              frontmostPID() == pid, belongs(element, to: pid),
              let current = editableFocusedElement(), CFEqual(current, element) else { return false }
        return true
    }

    private var focusedElementIsSecureTextField: Bool {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return false
        }
        return (subrole as? String) == "AXSecureTextField"
    }

    // MARK: - 교정 적용

    private func applyCorrection(
        deleting deletionCount: Int,
        replacement: String,
        delimiter: Character?,
        undo: (original: String, wordKey: String)? = nil
    ) {
        let applicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keystrokeAt = lastKeystrokeAt
        let expectedGeneration = generation
        let focusedElement = currentFocusedElement()
        let text: String
        if let delimiter, delimiter != "\r" {
            text = replacement + String(delimiter)
        } else {
            text = replacement
        }
        Task { @MainActor [weak self] in
            // 삭제를 게시하기 직전에 초기화·추가 입력·앱/포커스 변경·보안 입력 여부를 다시 확인한다.
            guard let self, self.isEnabled,
                  self.generation == expectedGeneration, self.lastKeystrokeAt == keystrokeAt,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID,
                  !IsSecureEventInputEnabled(), !self.focusedElementIsSecureTextField else { return }
            if let focusedElement, !self.hasSameFocus(as: focusedElement) { return }
            let source = CGEventSource(stateID: .hidSystemState)
            for _ in 0..<deletionCount {
                self.postKey(51, source: source)
            }
            self.postText(text, source: source)
            guard let focusedElement else {
                if delimiter == "\r" { self.postKey(36, source: source) }
                return
            }
            // 이벤트 게시와 실제 입력창 반영은 시점이 다르므로 표시를 확인한 뒤 전환한다.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard self.isEnabled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID,
                      self.hasSameFocus(as: focusedElement),
                      self.lastKeystrokeAt == keystrokeAt, self.generation == expectedGeneration,
                      !IsSecureEventInputEnabled(), !self.focusedElementIsSecureTextField else { break }
                if self.focusedTextMatches(text) {
                    let previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
                    if let undo, delimiter != "\r" {
                        self.recordCorrectionSwitchingToKorean(AppliedCorrection(
                            element: focusedElement, applicationPID: applicationPID, displayed: text,
                            original: undo.original, wordKey: undo.wordKey,
                            previousInputSource: previousSource, at: Date()
                        ))
                    } else {
                        self.selectKoreanInputSourceIfAvailable()
                    }
                    break
                }
            }
            if delimiter == "\r",
               self.isEnabled, self.lastKeystrokeAt == keystrokeAt,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID,
               self.hasSameFocus(as: focusedElement),
               !IsSecureEventInputEnabled(), !self.focusedElementIsSecureTextField {
                self.postKey(36, source: source)
            }
        }
    }

    private func postKey(_ keyCode: CGKeyCode, source: CGEventSource?) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postText(_ text: String, source: CGEventSource?) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                if isDown {
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                }
                event.post(tap: .cghidEventTap)
            }
            index += 20
        }
    }

    // MARK: - 혼용 단어·영문 복원·되돌리기

    // 영어 줄기 뒤에 붙은 한글 조사·어미(두벌식 키 열). 이 표에 있는 어미만 한글로 바꾼다.
    private static let koreanSuffixes: [String: String] = {
        let keys = [
            "fh", "dmfh", "dms", "sms", "dmf", "fmf", "rk", "dl", "dp", "dptj", "dpsms", "dml", "dk", "rhk",
            "eh", "aks", "ans", "dlek", "dprp", "gksxp", "qnxj", "Rkwl", "cjfja", "gkrh", "gkwl", "gkaus",
            "gkqslek", "gksms", "gksek", "gkek", "gkf", "gotj", "goTsmsep", "goTdj", "goTek", "goTtmqslek",
            "dlTsms", "dlTek"
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            DubeolsikComposer.compose(fromQwerty: key).map { (key, $0) }
        })
    }()

    // 영어 줄기가 확실할 때만(대문자 약어, 흔한 영어 단어, 또는 영어다운 긴 줄기+긴 어미) 어미 부분을 분리한다.
    static func mixedSplit(of word: String) -> (stem: String, suffix: String, hangulSuffix: String)? {
        guard word.count >= 4, word.allSatisfy(isASCIIQwertyLetter),
              !commonEnglishWords.contains(word.lowercased()) else { return nil }
        let characters = Array(word)
        for index in 2..<characters.count {
            let suffix = String(characters[index...])
            guard let hangulSuffix = koreanSuffixes[suffix] else { continue }
            let stem = String(characters[..<index])
            let isAcronym = stem.allSatisfy { ("A"..."Z").contains($0) }
            let isKnownWord = stem.count >= 3 && commonEnglishWords.contains(stem.lowercased())
            let isPlausibleStem = stem.count >= 3 && suffix.count >= 4 && looksLikeEnglish(stem)
            if isAcronym || isKnownWord || isPlausibleStem {
                return (stem, suffix, hangulSuffix)
            }
        }
        return nil
    }

    // 모음이 있고 모든 인접 글자쌍이 영어에서 흔한 소문자 단어만 영어로 본다.
    static func looksLikeEnglish(_ word: String) -> Bool {
        let lowered = Array(word)
        guard lowered.count >= 3, lowered.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }),
              word.lowercased().contains(where: { "aeiouy".contains($0) }) else { return false }
        for index in 0..<(lowered.count - 1) {
            if !commonEnglishBigrams.contains((String(lowered[index]) + String(lowered[index + 1])).lowercased()) {
                return false
            }
        }
        return true
    }

    private func isExcluded(_ word: String) -> Bool {
        undoCounts[word.lowercased(), default: 0] >= 3
    }

    // 첫 단어 보호가 확정할 최종 문자열. 기존 복원·혼용 규칙과 같은 판별만 쓰며 화면이나 상태를 바꾸지 않는다.
    // nil이면 두벌식 조합 결과를 그대로 쓴다.
    func firstWordText(forKeys keys: [Character]) -> String? {
        let word = String(keys)
        guard correctsMixedAndEnglish, word.count >= 3, word.allSatisfy(Self.isASCIIQwertyLetter),
              !isExcluded(word) else { return nil }
        if let split = Self.mixedSplit(of: word) {
            return split.stem + split.hangulSuffix
        }
        guard Self.looksLikeEnglish(word), let shown = DubeolsikComposer.render(keys: keys)?.text,
              shown.unicodeScalars.contains(where: { (0x3131...0x318E).contains($0.value) }) else { return nil }
        return word
    }

    // 한글 입력기에서 친 영어 단어를 확인 후 복원하도록 예약한다. 예약하면 true.
    private func scheduleRestoration(of word: String, delimiter: Character) -> Bool {
        guard word.count >= 3, word.allSatisfy(Self.isASCIIQwertyLetter), !isExcluded(word) else { return false }
        let split = Self.mixedSplit(of: word)
        guard split != nil || Self.looksLikeEnglish(word) else { return false }
        // 포커스 요소를 알 수 없거나 보안·미지원 입력이면 교체하지 않는다.
        guard let element = editableFocusedElement(), let applicationPID = frontmostPID(),
              !selectsAsynchronously(pid: applicationPID),
              belongs(element, to: applicationPID) else { return false }
        let target = split.map { $0.stem + $0.hangulSuffix } ?? word
        reset()
        let expectedGeneration = generation
        let keystrokeAt = lastKeystrokeAt
        Task { @MainActor [weak self] in
            // 구분자가 입력창에 확정될 시간을 준 뒤, 그 사이 입력·클릭·앱·포커스가 바뀌지 않았을 때만 진행한다.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, self.isKoreanInputSourceActive, let sourceID = self.currentInputSourceID,
                  self.isUnchanged(
                    generation: expectedGeneration, keystrokeAt: keystrokeAt, pid: applicationPID, element: element
                  ) else { return }
            self.restore(
                word: word, target: target, requiresLooseJamo: split == nil,
                delimiter: delimiter, in: element, applicationPID: applicationPID, sourceID: sourceID
            )
        }
        return true
    }

    // 영어 입력기에서 친 영문 줄기+한글 어미 단어의 어미 부분만 확인 후 교체하도록 예약한다.
    private func scheduleMixedConversion(
        of word: String, split: (stem: String, suffix: String, hangulSuffix: String), delimiter: Character
    ) -> Bool {
        guard !isExcluded(word), !pendingApostrophe, let sourceID = currentInputSourceID,
              let element = editableFocusedElement(), let applicationPID = frontmostPID(),
              !selectsAsynchronously(pid: applicationPID),
              belongs(element, to: applicationPID) else { return false }
        reset()
        let expectedGeneration = generation
        let keystrokeAt = lastKeystrokeAt
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !self.isKoreanInputSourceActive,
                  self.isUnchanged(
                    generation: expectedGeneration, keystrokeAt: keystrokeAt, pid: applicationPID, element: element
                  ) else { return }
            self.convertMixed(
                word: word, split: split, delimiter: delimiter, in: element,
                applicationPID: applicationPID, sourceID: sourceID
            )
        }
        return true
    }

    // 커서 앞에 단어+구분자가 정확히 있고 단어 앞이 경계일 때만 어미 범위를 한글로 교체한다.
    private func convertMixed(
        word: String, split: (stem: String, suffix: String, hangulSuffix: String), delimiter: Character,
        in element: AXUIElement, applicationPID: pid_t, sourceID: String
    ) {
        let delimiterText = String(delimiter)
        let fullLength = word.utf16.count + 1
        let suffixLength = split.suffix.utf16.count
        guard let caret = collapsedCaret(of: element), caret >= fullLength,
              precedingText(of: element, caret: caret, length: fullLength) == word + delimiterText else { return }
        if caret > fullLength {
            guard let before = precedingText(of: element, caret: caret - fullLength, length: 1)?.first,
                  before.isWhitespace || before.isPunctuation else { return }
        }
        let outcome = replaceRange(
            CFRange(location: caret - 1 - suffixLength, length: suffixLength), expected: split.suffix,
            with: split.hangulSuffix, in: element, pid: applicationPID, sourceID: sourceID, caret: caret
        )
        guard outcome == .committed else {
            // 반영은 됐지만 확인하지 못한 경우에도 되돌리기 기록과 입력기 전환은 하지 않는다.
            logger.info("Mixed correction not confirmed: field does not support verified replacement")
            return
        }
        logger.info("Mixed correction applied: suffix=\(suffixLength, privacy: .public)")
        let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let correction = AppliedCorrection(
            element: element, applicationPID: applicationPID, displayed: split.hangulSuffix + delimiterText,
            original: split.suffix + delimiterText, wordKey: word.lowercased(),
            previousInputSource: previous, at: Date()
        )
        recordCorrectionSwitchingToKorean(correction)
    }

    // 직접 일으킨 입력기 전환이 확인된 뒤에만 되돌리기 기록을 확정한다. 전환이 필요 없으면 바로 기록한다.
    private func recordCorrectionSwitchingToKorean(_ correction: AppliedCorrection) {
        if let id = selectKoreanInputSourceIfAvailable() {
            pendingCorrection = correction
            selfSwitch = (id, Date().addingTimeInterval(1.0))
        } else {
            lastCorrection = correction
            lastCorrection?.inputSourceID = currentInputSourceID
        }
    }

    // 화면의 한글을 역변환한 키 열이 실제로 누른 키와 정확히 같을 때만 그 범위를 교체한다.
    private func restore(
        word: String, target: String, requiresLooseJamo: Bool,
        delimiter: Character, in element: AXUIElement, applicationPID: pid_t, sourceID: String
    ) {
        guard let caret = collapsedCaret(of: element) else { return }
        let delimiterText = String(delimiter)
        for length in 1...word.count {
            guard caret >= length + 1,
                  let screen = precedingText(of: element, caret: caret, length: length + 1),
                  screen.hasSuffix(delimiterText) else { continue }
            let shown = String(screen.dropLast())
            guard let keys = DubeolsikComposer.qwerty(fromHangul: shown),
                  keys.lowercased() == word.lowercased() else { continue }
            // 영어 단어는 조합할 수 없는 낱자모가 화면에 있을 때만 확정한다. 완전한 음절이면 한국어일 수 있다.
            if requiresLooseJamo,
               !shown.unicodeScalars.contains(where: { (0x3131...0x318E).contains($0.value) }) { return }
            // 앞 글자가 공백·구두점이 아니면 더 긴 단어의 일부일 수 있으므로 바꾸지 않는다.
            if caret > length + 1 {
                guard let before = precedingText(of: element, caret: caret - length - 1, length: 1)?.first,
                      before.isWhitespace || before.isPunctuation else { return }
            }
            let range = CFRange(location: caret - length - 1, length: length)
            guard replaceRange(
                range, expected: shown, with: target, in: element,
                pid: applicationPID, sourceID: sourceID, caret: caret
            ) == .committed else {
                logger.info("Restoration not confirmed: field does not support verified replacement")
                return
            }
            logger.info("Restoration applied: length=\(length, privacy: .public)")
            lastCorrection = AppliedCorrection(
                element: element, applicationPID: applicationPID, displayed: target + delimiterText,
                original: shown + delimiterText, wordKey: word.lowercased(), previousInputSource: nil, at: Date(),
                inputSourceID: sourceID
            )
            return
        }
    }

    // 내용 변경 결과. committedUnverified는 쓰기 요청은 받아들여졌지만 결과를 확인하지 못한 상태로,
    // 키를 다시 전달하면 중복될 수 있으므로 키는 소비하고 그 단어 세션은 놓는다.
    // rejected·selectionUnconfirmed는 원래 접힌 커서가 확인됐거나 포커스가 떠나 현재 키를 그대로 보내도 안전한 상태다.
    // selectionUncertain은 같은 입력창에 선택 범위가 남아 있을 수 있어 현재 키를 보내면 원문을 지울 수 있는 상태다.
    fileprivate enum ReplaceOutcome {
        case rejected              // 조건이 맞지 않아 아무것도 바꾸지 않음
        case selectionUnconfirmed  // 선택 범위가 요청대로 확인되지 않아 내용은 바꾸지 않고 커서를 되돌림
        case selectionUncertain    // 내용은 바꾸지 않았지만 커서 복원을 확인하지 못함
        case committed
        case committedUnverified
    }

    // 모든 내용 변경 직전의 보안 관문. 캐시 없이 보안 입력·앞 앱·실제 포커스·입력 소스·역할/하위 역할·편집 가능 여부를
    // 매번 다시 읽고, 조회 실패는 거부로 본다.
    private func isMutable(_ element: AXUIElement, pid: pid_t, sourceID: String) -> Bool {
        guard isFocusedAndUnchanged(element, pid: pid, sourceID: sourceID),
              isEditableTextElement(element) else { return false }
        var rangeSettable: DarwinBoolean = false
        var textSettable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success
            && rangeSettable.boolValue
            && AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success
            && textSettable.boolValue
    }

    private func isFocusedAndUnchanged(_ element: AXUIElement, pid: pid_t, sourceID: String) -> Bool {
        guard !IsSecureEventInputEnabled(), frontmostPID() == pid, currentInputSourceID == sourceID,
              let current = focusedElement(of: pid) else { return false }
        return CFEqual(current, element)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRange
        ) == .success,
              let selectedRange, CFGetTypeID(selectedRange) == AXValueGetTypeID() else { return nil }
        let rangeValue = selectedRange as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private func setSelection(_ range: CFRange, of element: AXUIElement) -> Bool {
        var selection = range
        guard let value = AXValueCreate(.cfRange, &selection) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    // 접힌 커서 caret 앞의 정확한 범위 range가 expected일 때만 text로 바꾼다. 클립보드·합성 키·전체 값 교체는 쓰지 않는다.
    // 순서: 보안 관문 → 커서·기대 원문 확인 → (범위가 있으면) 선택 지정 후 선택 범위·선택 텍스트 재확인
    // → 쓰기 직전 보안 입력·앞 앱·포커스·입력 소스 재확인 → 선택 텍스트 쓰기 → 커서·결과 확인.
    private func replaceRange(
        _ range: CFRange, expected: String, with text: String,
        in element: AXUIElement, pid: pid_t, sourceID: String, caret: Int
    ) -> ReplaceOutcome {
        // 모든 선택 지정의 단일 관문: 선택이 비동기로 반영되는 앱에서는 선택을 만들기 전에 거절한다.
        guard !selectsAsynchronously(pid: pid),
              range.length == expected.utf16.count, range.location >= 0, range.location + range.length <= caret,
              isMutable(element, pid: pid, sourceID: sourceID),
              collapsedCaret(of: element) == caret,
              range.length == 0
                || precedingText(of: element, caret: range.location + range.length, length: range.length) == expected
        else { return .rejected }

        // 선택을 옮긴 뒤 내용을 바꾸지 못했을 때: 같은 입력창이면 원래 접힌 커서로 되돌리고 읽어서 확인한다.
        // 앱·포커스가 바뀌었으면 남은 선택이 현재 키를 받지 않으므로 안전하다. 그 밖에는 확인 실패로 보고 키를 막는다.
        func restoreCaret(otherwise safe: ReplaceOutcome) -> ReplaceOutcome {
            let front = frontmostPID()
            if let front, front != pid { return safe }
            if front == pid, let current = focusedElement(of: pid) {
                if !CFEqual(current, element) { return safe }
                if collapsedCaret(of: element) == caret
                    || (setSelection(CFRange(location: caret, length: 0), of: element)
                        && collapsedCaret(of: element) == caret) { return safe }
            }
            uncertainSelection = (element, pid, caret)
            markUnverified(element, pid: pid)
            onLivePaused?()
            logger.info("Live input paused: caret restoration was not confirmed")
            return .selectionUncertain
        }

        let isInsertion = range.length == 0 && range.location == caret
        if !isInsertion {
            var selected: CFTypeRef?
            guard setSelection(range, of: element),
                  let confirmed = selectedRange(of: element),
                  confirmed.location == range.location, confirmed.length == range.length,
                  range.length == 0
                    || (AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success
                        && (selected as? String) == expected) else {
                return restoreCaret(otherwise: .selectionUnconfirmed)
            }
        }
        // 쓰기 직전에 보안 입력·앞 앱·포커스·입력 소스와 함께 역할/하위 역할·편집 가능 여부도 다시 읽는다.
        guard isMutable(element, pid: pid, sourceID: sourceID) else {
            return isInsertion ? .rejected : restoreCaret(otherwise: .rejected)
        }
        let finalCaret = caret - range.length + text.utf16.count
        // 쓰기 직후 또는 쓰기 확인 실패 시: 앱이 나중에 반영할 수 있어 키는 재전달하지 않지만,
        // 선택 범위나 불확실한 커서가 남아 있을 수 있으므로 보호를 등록한다.
        func commitUnverified() -> ReplaceOutcome {
            // 읽어서 확인된 글자 기준으로 목표 커서를 정해 선택을 접어 본다. 확인되지 않으면 보호를 등록한다.
            if isFocusedAndUnchanged(element, pid: pid, sourceID: sourceID),
               selectedRange(of: element)?.length ?? 1 > 0 {
                let target: Int?
                if text.isEmpty || precedingText(of: element, caret: finalCaret, length: text.utf16.count) == text {
                    target = finalCaret
                } else if precedingText(of: element, caret: caret, length: range.length) == expected {
                    target = caret
                } else {
                    target = nil
                }
                if let target, setSelection(CFRange(location: target, length: 0), of: element),
                   collapsedCaret(of: element) == target {
                    return .committedUnverified
                }
            }
            uncertainSelection = (element, pid, finalCaret)
            onLivePaused?()
            return .committedUnverified
        }

        switch AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) {
        case .success:
            break
        case .cannotComplete:
            // 응답 시간 초과는 앱이 나중에 반영할 수 있으므로 반영된 것으로 보고 다시 쓰거나 키를 재전달하지 않는다.
            return commitUnverified()
        default:
            return isInsertion ? .rejected : restoreCaret(otherwise: .rejected)
        }
        if collapsedCaret(of: element) != finalCaret {
            guard isFocusedAndUnchanged(element, pid: pid, sourceID: sourceID),
                  setSelection(CFRange(location: finalCaret, length: 0), of: element),
                  collapsedCaret(of: element) == finalCaret else { return commitUnverified() }
        }
        guard text.isEmpty
                || precedingText(of: element, caret: range.location + text.utf16.count, length: text.utf16.count) == text
        else { return commitUnverified() }
        return .committed
    }

    // 선택이 비동기로 반영되는 앱(Chromium 계열)용 검증형 교체. 접근성 선택 텍스트 쓰기는 Chromium이 성공으로 답하고도
    // 실제로 바꾸지 않을 수 있어 쓰지 않는다. 선택은 읽기 값이 요청한 범위·글자로 바뀐 것이 확인된 뒤에만 쓰고,
    // 쓰기는 평소 입력과 같은 합성 유니코드 입력(postText) 한 번뿐이다. 불확실해도 두 번째 입력은 보내지 않는다.
    // 이 구간에 들어온 키는 보관했다가(blocksForAsyncSelection) 접힌 커서가 확인된 뒤 다시 전달한다.
    // 어떤 경로로 끝나도 남은 선택은 확인된 글자 기준의 목표 커서로 접고, 확인하지 못하면 uncertainSelection으로 보호를 잇는다.
    private func replaceRangeAsync(
        _ range: CFRange, expected: String, with text: String,
        in element: AXUIElement, pid: pid_t, sourceID: String, caret: Int, requestID: Int
    ) async -> ReplaceOutcome {
        lastReplayedKeyCount = 0
        lastLostKeyCount = 0
        guard range.length > 0, range.length == expected.utf16.count, range.location >= 0,
              range.location + range.length == caret, !text.isEmpty, text != expected,
              asyncSelection == nil, uncertainSelection == nil,
              isMutable(element, pid: pid, sourceID: sourceID),
              collapsedCaret(of: element) == caret,
              precedingText(of: element, caret: caret, length: range.length) == expected
        else { return .rejected }

        let state = AsyncSelectionGuard(element: element, pid: pid, caret: caret)
        asyncSelection = state
        let finalCaret = caret - range.length + text.utf16.count

        // 쓰기 직전 조건: 사용자 중단·취소·요청 교체가 없고 앱·입력창·입력 소스·보안 입력이 그대로다.
        func isLive() -> Bool {
            isEnabled && !state.aborted && !Task.isCancelled && requestID == manualRequestID && asyncSelection === state
                && isFocusedAndUnchanged(element, pid: pid, sourceID: sourceID)
        }
        // 선택을 접는 정리 작업은 취소와 무관하게 같은 앱·입력창일 때만 한다.
        func canTouch() -> Bool {
            guard !state.aborted, !IsSecureEventInputEnabled(), frontmostPID() == pid,
                  let current = focusedElement(of: pid) else { return false }
            return CFEqual(current, element)
        }
        // 취소돼도 간격을 지키도록 부모 취소를 물려받지 않는 대기를 쓴다.
        func pause(_ nanoseconds: UInt64) async {
            await Task { try? await Task.sleep(nanoseconds: nanoseconds) }.value
        }
        func selectedString() -> String? {
            var selected: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
            return selected as? String
        }
        func release() { if asyncSelection === state { asyncSelection = nil } }
        // 같은 접힌 커서가 연속으로 관찰돼야 확인된 것으로 본다(오래된 단일 읽기 값은 믿지 않는다).
        func settled(at target: Int) async -> Bool {
            var agree = 0
            for _ in 0..<14 {
                guard canTouch() else { return false }
                if collapsedCaret(of: element) == target {
                    agree += 1
                    if agree >= 3 { return true }
                } else {
                    agree = 0
                }
                await pause(40_000_000)
            }
            return false
        }
        // 접근성 요청 → 안 되면 방향키 한 번(평소 입력과 같은 합성 이벤트). 선택의 끝이 목표일 때만 오른쪽, 시작이 목표일 때만 왼쪽.
        func collapse(to target: Int) async -> Bool {
            guard canTouch() else { return false }
            if await settled(at: target) { return true }
            guard canTouch() else { return false }
            _ = setSelection(CFRange(location: target, length: 0), of: element)
            if await settled(at: target) { return true }
            guard canTouch(), let first = selectedRange(of: element), first.length > 0 else { return false }
            await pause(40_000_000)
            guard canTouch(), let second = selectedRange(of: element),
                  second.location == first.location, second.length == first.length else { return false }
            let key: CGKeyCode
            if second.location + second.length == target {
                key = 124
            } else if second.location == target {
                key = 123
            } else {
                return false
            }
            postKey(key, source: CGEventSource(stateID: .hidSystemState))
            return await settled(at: target)
        }
        // 보관한 키를 접힌 커서가 확인된 경우에만 다시 전달한다. 전달하지 못하면 개수를 남겨 안내한다.
        func deliverQueued(_ allowed: Bool) {
            if allowed, isEnabled, !state.aborted, canTouch() {
                for event in state.queued {
                    event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                    event.post(tap: .cghidEventTap)
                    if let up = event.copy() {
                        up.type = .keyUp
                        up.post(tap: .cghidEventTap)
                    }
                }
                lastReplayedKeyCount = state.queued.count
                lastLostKeyCount = state.dropped
            } else {
                lastLostKeyCount = state.queued.count + state.dropped
            }
            state.queued.removeAll()
            state.dropped = 0
        }
        func protect(_ caretToKeep: Int) {
            uncertainSelection = (element, pid, caretToKeep)
            markUnverified(element, pid: pid)
            onLivePaused?()
            logger.info("Live input paused: caret restoration was not confirmed")
        }
        // 내용을 바꾸지 못했고 원래 접힌 커서 복원을 확인한 경우의 마무리
        func finishUnchanged(_ outcome: ReplaceOutcome) async -> ReplaceOutcome {
            if !canTouch() {
                // 앱·입력창이 바뀌었거나 사용자가 직접 정했다. 남은 선택은 현재 키를 받지 않으므로 건드리지 않는다.
                deliverQueued(false)
                release()
                return outcome
            }
            if await collapse(to: caret) {
                deliverQueued(true)
                release()
                return outcome
            }
            deliverQueued(false)
            protect(caret)
            release()
            return .selectionUncertain
        }

        // 선택을 만들기 전/후 실패 경로
        func abandon(_ safe: ReplaceOutcome) async -> ReplaceOutcome {
            await finishUnchanged(safe)
        }

        guard setSelection(range, of: element) else { return await abandon(.selectionUnconfirmed) }
        var confirmed = false
        for _ in 0..<16 {
            guard isLive() else { return await abandon(.selectionUnconfirmed) }
            if let current = selectedRange(of: element),
               current.location == range.location, current.length == range.length,
               selectedString() == expected {
                confirmed = true
                break
            }
            await pause(25_000_000)
        }
        // 쓰기 직전 마지막 확인: 같은 선택·같은 글자·같은 입력창이어야만 한 번 입력한다.
        guard confirmed, isLive(), isMutable(element, pid: pid, sourceID: sourceID),
              let latest = selectedRange(of: element), latest.location == range.location, latest.length == range.length,
              selectedString() == expected, !focusedElementIsSecureTextField else {
            return await abandon(.selectionUnconfirmed)
        }

        // 단 한 번의 입력. 이후 어떤 결과여도 다시 입력하지 않는다.
        postText(text, source: CGEventSource(stateID: .hidSystemState))

        func replacedAndCollapsed() -> Bool {
            collapsedCaret(of: element) == finalCaret
                && precedingText(of: element, caret: finalCaret, length: text.utf16.count) == text
        }
        var applied = false
        for _ in 0..<20 {
            if replacedAndCollapsed() { applied = true; break }
            await pause(25_000_000)
        }
        if applied {
            // 연속으로 같은 결과가 보여야 확정한다.
            await pause(60_000_000)
            if replacedAndCollapsed(), canTouch() {
                deliverQueued(true)
                release()
                return .committed
            }
        }
        guard canTouch() else {
            // 사용자가 직접 선택을 바꿨거나 앱·입력창이 바뀌었다. 결과는 확인하지 못했고 더 건드리지 않는다.
            deliverQueued(false)
            release()
            return .committedUnverified
        }
        // 확인된 글자로 상태를 판단한다: 교체됐으면 finalCaret, 원문 그대로면 원래 커서가 접을 목표다.
        let replacedText = precedingText(of: element, caret: finalCaret, length: text.utf16.count) == text
        let unchangedText = precedingText(of: element, caret: caret, length: range.length) == expected
        if replacedText && !unchangedText {
            if await collapse(to: finalCaret), replacedAndCollapsed() {
                deliverQueued(true)
                release()
                return .committed
            }
            deliverQueued(false)
            protect(finalCaret)
            release()
            return .committedUnverified
        }
        if unchangedText && !replacedText {
            // 입력이 반영되지 않았다. 선택만 접고, 늦게 반영될 수 있으므로 같은 입력은 다시 보내지 않는다.
            let outcome = await finishUnchanged(.selectionUnconfirmed)
            markUnverified(element, pid: pid)
            return outcome
        }
        // 어느 쪽인지 확인하지 못함: 선택의 끝(없으면 예상 커서)으로 보호하고 키를 막는다.
        let observed = selectedRange(of: element)
        deliverQueued(false)
        protect(observed.map { $0.location + $0.length } ?? finalCaret)
        release()
        return .committedUnverified
    }

    // Delete는 소비하고, 검증된 되돌리기가 끝났을 때만 학습 취소와 입력기 복원을 한다.
    private func startAsyncUndo(_ correction: AppliedCorrection, pid: pid_t, sourceID: String, caret: Int) {
        asyncUndoStarted = true
        let length = correction.displayed.utf16.count
        manualTask?.cancel()
        manualRequestID &+= 1
        let requestID = manualRequestID
        manualTask = Task { @MainActor [weak self] in
            guard let self, self.isEnabled else { return }
            let outcome = await self.replaceRangeAsync(
                CFRange(location: caret - length, length: length), expected: correction.displayed,
                with: correction.original, in: correction.element, pid: pid, sourceID: sourceID,
                caret: caret, requestID: requestID
            )
            let lostNote = self.lastLostKeyCount > 0
                ? " 되돌리는 중 입력한 키 \(self.lastLostKeyCount)개는 전달하지 못했으니 다시 입력해 주세요." : ""
            switch outcome {
            case .committed:
                self.manualTask = nil
                if let source = correction.learnedSource, let learned = correction.learnedReplacement {
                    PersonalDictionaryStore.shared.removeIfMatching(source: source, replacement: learned)
                }
                self.undoCounts[correction.wordKey, default: 0] += 1
                if let previous = correction.previousInputSource { TISSelectInputSource(previous) }
                self.logger.info("Correction undone")
                if !lostNote.isEmpty { self.onManualConversionMessage?("되돌렸습니다." + lostNote) }
            case .committedUnverified, .selectionUncertain:
                self.logger.info("Correction undo not confirmed")
                self.onManualConversionMessage?("되돌리기를 입력창에서 확인하지 못했습니다. 글자가 선택된 채로 남았다면 방향키를 눌러 선택을 해제한 뒤 확인해 주세요." + lostNote)
            case .selectionUnconfirmed:
                self.onManualConversionMessage?("입력창이 되돌리기를 받아들이지 않아 그대로 두었습니다." + lostNote)
            case .rejected:
                break
            }
        }
    }

    // 교정 직후 Delete: 화면의 교정 결과가 그대로이고 같은 입력창·입력 소스일 때만 원문으로 되돌린다.
    // 되돌리기 쓰기가 반영됐으면(확인 실패 포함) Delete를 소비한다.
    private func undo(_ correction: AppliedCorrection) -> Bool {
        guard correction.isManualConversion || correctsMixedAndEnglish || continuousSwitching,
              Date().timeIntervalSince(correction.at) < 30,
              let pid = correction.applicationPID, let sourceID = correction.inputSourceID,
              let caret = collapsedCaret(of: correction.element) else { return false }
        let length = correction.displayed.utf16.count
        guard caret >= length else { return false }
        // 수동 변환을 되돌릴 때는 변환과 같은 검증형 비동기 교체를 쓴다.
        if correction.isManualConversion {
            guard asyncSelection == nil, uncertainSelection == nil, length > 0,
                  isMutable(correction.element, pid: pid, sourceID: sourceID),
                  precedingText(of: correction.element, caret: caret, length: length) == correction.displayed
            else { return false }
            startAsyncUndo(correction, pid: pid, sourceID: sourceID, caret: caret)
            return true
        }
        switch replaceRange(
            CFRange(location: caret - length, length: length), expected: correction.displayed,
            with: correction.original, in: correction.element, pid: pid, sourceID: sourceID, caret: caret
        ) {
        case .committed:
            break
        case .committedUnverified, .selectionUncertain:
            // 반영됐거나 선택이 남아 있을 수 있으면 Delete를 보내지 않는다.
            logger.info("Correction undo not confirmed")
            return true
        case .rejected, .selectionUnconfirmed:
            return false
        }
        // 방금 학습한 항목만 취소한다. 이미 있던 사전 항목은 건드리지 않는다.
        if let source = correction.learnedSource, let learned = correction.learnedReplacement {
            PersonalDictionaryStore.shared.removeIfMatching(source: source, replacement: learned)
        }
        undoCounts[correction.wordKey, default: 0] += 1
        if let previous = correction.previousInputSource { TISSelectInputSource(previous) }
        logger.info("Correction undone")
        return true
    }

    // MARK: - 입력기 전환

    private var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return inputSourceID(of: source)
    }

    private var isKoreanInputSourceActive: Bool {
        guard let id = currentInputSourceID else { return false }
        return id.hasPrefix("com.apple.inputmethod.Korean.") && !id.hasSuffix(".Roman")
    }

    // 실제로 전환을 요청했을 때만 대상 입력기 ID를 돌려준다.
    @discardableResult
    private func selectKoreanInputSourceIfAvailable() -> String? {
        guard let listRef = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
        var koreanSources: [TISInputSource] = []
        for item in listRef as NSArray {
            let source = item as! TISInputSource
            guard let id = inputSourceID(of: source),
                  id.hasPrefix("com.apple.inputmethod.Korean"), !id.hasSuffix(".Roman"),
                  boolProperty(of: source, key: kTISPropertyInputSourceIsSelectCapable) else { continue }
            koreanSources.append(source)
        }
        let preferred = koreanSources.first { inputSourceID(of: $0) == "com.apple.inputmethod.Korean.2SetKorean" }
        guard let target = preferred ?? koreanSources.first, let id = inputSourceID(of: target),
              id != currentInputSourceID, TISSelectInputSource(target) == noErr else { return nil }
        return id
    }

    private func inputSourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func boolProperty(of source: TISInputSource, key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    // MARK: - 입력 문자 추출

    private func typedCharacter(of event: CGEvent) -> Character? {
        var codeUnits = [UniChar](repeating: 0, count: 4)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &codeUnits)
        let string = String(utf16CodeUnits: codeUnits, count: length)
        guard string.count == 1 else { return nil }
        return string.first
    }

    // MARK: - 영어 판별 자료

    static let commonEnglishWords: Set<String> = [
        "the", "be", "to", "of", "and", "in", "that", "have", "it", "for", "not", "on", "with", "he",
        "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what", "so", "up", "out",
        "if", "about", "who", "get", "which", "go", "me", "when", "make", "can", "like", "time", "no",
        "just", "him", "know", "take", "people", "into", "year", "your", "good", "some", "could",
        "them", "see", "other", "than", "then", "now", "look", "only", "come", "its", "over", "think",
        "also", "back", "after", "use", "two", "how", "our", "work", "first", "well", "way", "even",
        "new", "want", "because", "any", "these", "give", "day", "most", "us", "is", "was", "are",
        "were", "been", "has", "had", "did", "said", "made", "went", "got", "very", "much", "many",
        "more", "such", "here", "where", "why", "before", "again", "still", "should", "must", "may",
        "might", "shall", "does", "done", "each", "own", "same", "too", "old", "great", "little",
        "world", "life", "hand", "part", "child", "eye", "woman", "man", "place", "case", "week",
        "point", "home", "water", "room", "mother", "area", "money", "story", "fact", "month", "lot",
        "right", "study", "book", "word", "side", "kind", "head", "house", "friend", "father",
        "power", "hour", "game", "line", "end", "member", "law", "car", "city", "name", "team",
        "minute", "idea", "kid", "body", "face", "level", "door", "art", "war", "history",
        "result", "change", "morning", "reason", "girl", "boy", "guy", "moment", "air", "force",
        "state", "never", "always", "really", "thing", "long", "down", "off", "yes", "yet", "let",
        "run", "read", "need", "feel", "seem", "leave", "call", "keep", "help", "talk", "turn",
        "start", "show", "hear", "play", "move", "live", "believe", "bring", "happen", "write",
        "sit", "stand", "lose", "pay", "meet", "include", "continue", "set", "learn", "lead",
        "understand", "watch", "follow", "stop", "create", "speak", "spend", "grow", "open", "walk",
        "win", "offer", "remember", "love", "consider", "appear", "buy", "wait", "serve", "die",
        "send", "expect", "build", "stay", "fall", "cut", "reach", "kill", "remain", "hello", "ok",
        "okay", "please", "thanks", "thank", "sorry", "hi", "bye", "test", "file", "code", "data",
        "user", "app", "mac", "email", "web", "link", "type", "text", "list", "note", "next", "last",
        "git", "github", "http", "https", "www", "com", "html", "css", "js", "json", "api", "url", "sql",
        "npm", "ssh", "pdf", "usb", "dev", "ios", "macos"
    ]

    static let commonEnglishBigrams: Set<String> = [
        "ab", "ac", "ad", "af", "ag", "ah", "ai", "ak", "al", "am", "an", "ap", "ar", "as", "at",
        "au", "av", "aw", "ax", "ay", "az",
        "ba", "bb", "be", "bi", "bj", "bl", "bm", "bo", "br", "bs", "bt", "bu", "by",
        "ca", "cc", "ce", "ch", "ci", "ck", "cl", "co", "cq", "cr", "cs", "ct", "cu", "cy",
        "da", "dd", "de", "dg", "di", "dj", "dl", "dm", "dn", "do", "dr", "ds", "du", "dv", "dy",
        "ea", "eb", "ec", "ed", "ee", "ef", "eg", "eh", "ei", "ek", "el", "em", "en", "eo", "ep",
        "eq", "er", "es", "et", "eu", "ev", "ew", "ex", "ey",
        "fa", "fe", "ff", "fi", "fl", "fo", "fr", "ft", "fu", "fy",
        "ga", "ge", "gg", "gh", "gi", "gl", "gn", "go", "gr", "gs", "gt", "gu",
        "ha", "hb", "he", "hi", "hn", "ho", "hr", "hs", "ht", "hu", "hy",
        "ia", "ib", "ic", "id", "ie", "if", "ig", "ik", "il", "im", "in", "io", "ip", "ir", "is",
        "it", "iv", "ix", "iz",
        "ja", "je", "ji", "jo", "ju",
        "ka", "ke", "ki", "kn", "ko", "ks", "ku", "ky",
        "la", "lc", "ld", "le", "lf", "li", "lk", "ll", "lm", "lo", "lp", "lr", "ls", "lt", "lu",
        "lv", "lw", "ly",
        "ma", "mb", "me", "mf", "mi", "ml", "mm", "mn", "mo", "mp", "ms", "mu", "my",
        "na", "nb", "nc", "nd", "ne", "nf", "ng", "nh", "ni", "nj", "nk", "nl", "nm", "nn", "no",
        "np", "nr", "ns", "nt", "nu", "nv", "nw", "ny",
        "oa", "ob", "oc", "od", "oe", "of", "og", "oh", "oi", "ok", "ol", "om", "on", "oo", "op",
        "or", "os", "ot", "ou", "ov", "ow", "ox", "oy",
        "pa", "pe", "ph", "pi", "pl", "po", "pp", "pr", "ps", "pt", "pu", "py",
        "qu",
        "ra", "rb", "rc", "rd", "re", "rf", "rg", "rh", "ri", "rk", "rl", "rm", "rn", "ro", "rp",
        "rr", "rs", "rt", "ru", "rv", "rw", "ry",
        "sa", "sb", "sc", "sd", "se", "sf", "sh", "si", "sk", "sl", "sm", "sn", "so", "sp", "sq",
        "ss", "st", "su", "sw", "sy",
        "ta", "tb", "tc", "te", "tf", "th", "ti", "tl", "tm", "tn", "to", "tr", "ts", "tt", "tu",
        "tw", "ty",
        "ua", "ub", "uc", "ud", "ue", "uf", "ug", "uh", "ui", "ul", "um", "un", "up", "ur", "us",
        "ut", "uy",
        "va", "ve", "vi", "vo", "vy",
        "wa", "wd", "we", "wh", "wi", "wl", "wn", "wo", "wr", "ws",
        "xc", "xi", "xp", "xt",
        "ya", "yb", "yc", "ye", "yi", "yl", "ym", "yn", "yo", "yp", "ys", "yt", "yu", "yw", "yz",
        "za", "ze", "zi", "zo", "zy"
    ]
}

// MARK: - 실시간 한영 전환

// 한 단어 동안 누른 키 열과 언어 구간을 직접 관리한다. 한글 입력 소스에서는 시스템 조합을 유지하고
// 구분자 기반 교정에 맡겨, 직접 삽입한 첫 자음과 입력기의 조합이 겹치지 않도록 한다.
// 화면을 바꾸기 전에는 매번 앱·포커스·접힌 커서·기대 원문·보안 입력을 확인하고, 하나라도 다르면 손을 뗀다.
extension KoreanTypoCorrector {
    fileprivate enum LiveMode {
        case idle
        case tracking
        // 이 단어는 입력창·자판 미지원으로 구분자 기반 엔진이 처리한다.
        case legacy
        // 이 단어는 코드·경로처럼 보이거나 확인에 실패해 다음 공백까지 그대로 통과시킨다.
        case ignoring
    }

    fileprivate struct LiveWord {
        let element: AXUIElement
        let applicationPID: pid_t
        // 단어를 시작할 때의 입력 소스. 매 쓰기 직전에 현재 소스와 다시 대조한다.
        let sourceID: String
        let koreanSource: Bool
        var keys: [Character] = []
        var segments: [LanguageIntent.Segment]
        // 사용자가 자동 전환을 되돌린 단어는 끝날 때까지 더 바꾸지 않는다.
        var pinned = false
        var lastFlip: (segments: [LanguageIntent.Segment], keyCount: Int, wordKey: String)?
        // true이면 이 단어의 화면 표시를 접근성 API로 직접 쓰고 있다. wordStart는 UTF-16 위치다.
        var owned = false
        var wordStart = 0
        var displayed = ""
    }

    private enum TakeOverResult { case done, retryLater, handOff, abandon, releasedAfterWrite, paused }

    private static let liveAXTimeout: Float = 0.05
    private static let maxLiveKeys = 64
    private static let korean2SetID = "com.apple.inputmethod.Korean.2SetKorean"
    private static let qwertyLayoutIDs: Set<String> = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
    private static let openingBoundaries: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "「", "『", "<", "«"]

    // nil이면 이 이벤트는 구분자 기반 엔진이 처리한다. 한 이벤트를 두 엔진이 함께 처리하지 않는다.
    fileprivate func handleLiveKeyDown(_ event: CGEvent) -> Bool? {
        // 어포스트로피 직후의 키만 이 기록을 쓸 수 있으므로 어떤 경로로든 한 번 읽으면 비운다.
        let quote = liveQuote
        liveQuote = nil
        guard !IsSecureEventInputEnabled() else {
            reset()
            return false
        }
        if liveMode == .tracking, let word = liveWord, currentInputSourceID != word.sourceID {
            // 수동 전환·자판 변경: 알림을 기다리지 않고 이전 세션을 바로 놓는다. 새 자판 입력은 그대로 전달한다.
            liveWord = nil
            liveMode = .ignoring
            lastCorrection = nil
            logger.info("Live input released: input source changed")
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            || (Self.resetKeyCodes.contains(keyCode) && keyCode != 51 && keyCode != 48) {
            // 단축키·방향키·Esc 등: 기존 엔진이 모든 상태를 초기화하고 그대로 통과시킨다.
            return nil
        }
        if keyCode == 51 {
            return liveMode == .tracking ? handleLiveDelete() : nil
        }
        guard let character = typedCharacter(of: event) else { return nil }

        if Self.isASCIIQwertyLetter(character) {
            switch liveMode {
            case .tracking: return handleLiveLetter(character)
            case .ignoring: return false
            case .legacy: return nil
            case .idle: return startLiveWord(with: character)
            }
        }

        // 글자가 아닌 입력은 단어의 끝이다. 단어 안의 기호(경로·주소·식별자) 뒤 글자는 경계 확인에서 걸러진다.
        switch liveMode {
        case .tracking:
            return finishLiveWord(delimiter: character)
        case .legacy:
            if character.isWhitespace || Self.punctuationDelimiters.contains(character) { liveMode = .idle }
            return nil
        case .ignoring:
            if character.isWhitespace { liveMode = .idle }
            return false
        case .idle:
            if let quote = quote, Self.isApostropheLike(character) { return forceConvertQuotedWord(quote) }
            return buffer.isEmpty && !pendingApostrophe ? false : nil
        }
    }

    // 직접 표시한 단어 뒤의 두 번째 어포스트로피: 화면에 실제로 있는 단어+어포스트로피를 한글 변환 결과로 한 번에 바꾼다.
    // 변환할 수 없거나 확인에 실패하면 false로 두 번째 키를 그대로 전달한다(글자를 지우지 않음).
    private func forceConvertQuotedWord(_ quote: LiveQuote) -> Bool {
        let pid = quote.applicationPID
        let fullLength = quote.displayed.utf16.count + 1
        guard isFocusedAndUnchanged(quote.element, pid: pid, sourceID: quote.sourceID),
              !focusedElementIsSecureTextField,
              let target = DubeolsikComposer.compose(fromQwerty: quote.keys),
              let caret = collapsedCaret(of: quote.element), caret == quote.wordStart + fullLength,
              let shown = precedingText(of: quote.element, caret: caret, length: fullLength),
              let quoteMark = shown.last, Self.isApostropheLike(quoteMark),
              String(shown.dropLast()) == quote.displayed else { return false }
        let outcome = replaceRange(
            CFRange(location: quote.wordStart, length: fullLength), expected: shown, with: target,
            in: quote.element, pid: pid, sourceID: quote.sourceID, caret: caret
        )
        switch outcome {
        case .committed:
            guard isFocusedAndUnchanged(quote.element, pid: pid, sourceID: quote.sourceID) else { return true }
            let correction = AppliedCorrection(
                element: quote.element, applicationPID: pid, displayed: target, original: quote.displayed,
                wordKey: quote.keys.lowercased(),
                previousInputSource: TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), at: Date(),
                inputSourceID: quote.sourceID
            )
            recordCorrectionSwitchingToKorean(correction)
            return true
        case .committedUnverified:
            // 쓰기는 받아들여졌지만 결과를 확인하지 못했다. 키는 소비해 중복을 막고 입력기 전환·되돌리기 기록은 하지 않는다.
            markUnverified(quote.element, pid: pid)
            liveMode = .ignoring
            return true
        case .selectionUncertain:
            liveMode = .ignoring
            return true
        case .rejected, .selectionUnconfirmed:
            return false
        }
    }

    // 시스템 텍스트 대치 목록. 메모리에만 두고 값은 기록하지 않으며, 생명주기 알림 시점에 캐시를 갱신한다.
    private func refreshReplacements() {
        let shortcuts = NSSpellChecker.shared.userReplacementsDictionary
        let sequences = shortcuts.keys.compactMap { key -> (sequence: String, shortcut: String)? in
            let sequence = key.allSatisfy(\.isASCII) ? key : DubeolsikComposer.qwerty(fromHangul: key)
            return sequence.map { (sequence: $0, shortcut: key) }
        }
        cachedReplacementShortcuts = shortcuts
        cachedReplacementSequences = sequences
        if liveMode == .idle && buffer.isEmpty {
            replacementShortcuts = shortcuts
            replacementSequences = sequences
        }
    }

    // 지금까지의 물리 키 열이 어떤 단축어 키 열의 앞부분이면 언어 판단으로 바꾸지 않는다.
    private func protectsShortcut(_ keys: [Character]) -> Bool {
        let typed = String(keys)
        return replacementSequences.contains { $0.sequence.hasPrefix(typed) }
    }

    private func replacement(forDisplay display: String) -> String? {
        guard let value = replacementShortcuts[display], !value.isEmpty else { return nil }
        return value
    }

    private func startLiveWord(with character: Character) -> Bool? {
        replacementShortcuts = cachedReplacementShortcuts
        replacementSequences = cachedReplacementSequences
        guard let sourceID = currentInputSourceID else { return nil }
        let koreanSource = sourceID == Self.korean2SetID
        // 조합 중인 한글을 AX로 쓰면 호스트 입력기의 상태와 어긋나 첫 자음이 남을 수 있다.
        // 첫 키부터 시스템 입력기로 보내고, 공백 등으로 조합이 확정된 뒤 기존 엔진이 교정한다.
        if koreanSource {
            liveMode = .legacy
            return nil
        }
        guard Self.qwertyLayoutIDs.contains(sourceID),
              let pid = frontmostPID(), !liveDisabledPIDs.contains(pid), !selectsAsynchronously(pid: pid),
              let element = focusedElement(of: pid),
              !unverifiedElements.contains(where: { CFEqual($0, element) }),
              isMutable(element, pid: pid, sourceID: sourceID) else {
            liveMode = .legacy
            return nil
        }
        let word = LiveWord(
            element: element, applicationPID: pid, sourceID: sourceID, koreanSource: koreanSource,
            segments: [LanguageIntent.Segment(start: 0, korean: koreanSource)]
        )
        resetLegacy()
        liveWord = word
        liveMode = .tracking
        return handleLiveLetter(character)
    }

    private func handleLiveLetter(_ character: Character) -> Bool? {
        guard var word = liveWord else { return false }
        guard word.keys.count < Self.maxLiveKeys else {
            liveWord = nil
            liveMode = .ignoring
            return false
        }
        let previous = word.segments
        word.keys.append(character)
        word.lastFlip = nil
        if !protectsShortcut(word.keys) { decide(&word, atEnd: false) }

        if word.owned {
            liveWord = word
            return consumes(writeLive(LanguageIntent.display(of: word.keys, segments: word.segments)))
        }
        guard word.segments != previous else {
            liveWord = word
            return false
        }
        // 영문 그대로 통과시킨 키를 넘겨받아 현재 키까지 포함한 표시로 바꾼다.
        switch takeOver(&word, typed: String(word.keys.dropLast())) {
        case .done:
            liveWord = word
            return true
        case .retryLater:
            // 앞서 통과시킨 키가 아직 입력창에 반영되지 않았다. 이번 키는 그대로 보내고 다음 키에서 다시 판단한다.
            word.segments = previous
            word.lastFlip = nil
            liveWord = word
            return false
        case .handOff:
            // 접근성 쓰기가 즉시 반영되지 않는 앱이다. 이 단어는 지금까지의 키와 함께 기존 엔진에 넘긴다.
            liveWord = nil
            liveMode = .legacy
            buffer = String(word.keys.dropLast())
            lastKeystrokeAt = Date()
            return nil
        case .abandon:
            liveWord = nil
            liveMode = .ignoring
            return false
        case .releasedAfterWrite:
            // 현재 키까지 포함한 표시를 이미 썼으므로 키를 소비해 중복을 막는다.
            return true
        case .paused:
            // 선택이 남아 있을 수 있어 현재 키를 보내지 않는다. 기존 엔진에도 넘기지 않는다.
            liveWord = nil
            liveMode = .ignoring
            return true
        }
    }

    private func handleLiveDelete() -> Bool {
        guard var word = liveWord else {
            liveMode = .idle
            return false
        }
        guard word.owned else {
            // 통과 중인 영문 단어는 입력창이 한 글자를 지우므로 키 열에서도 하나만 뺀다.
            if !word.keys.isEmpty { word.keys.removeLast() }
            trimSegments(&word)
            word.lastFlip = nil
            liveWord = word
            return false
        }
        if let flip = word.lastFlip, flip.keyCount == word.keys.count {
            // 자동 전환 직후의 Delete는 전환을 되돌리고, 이 단어는 사용자의 선택대로 고정한다.
            word.segments = flip.segments
            word.pinned = true
            undoCounts[flip.wordKey, default: 0] += 1
            logger.info("Live switch undone")
        } else {
            guard !word.keys.isEmpty else {
                liveWord = nil
                liveMode = .idle
                return false
            }
            // 한글 구간에서는 입력기처럼 마지막 자모 하나를 지우고 다시 조합한다.
            word.keys.removeLast()
            trimSegments(&word)
        }
        word.lastFlip = nil
        liveWord = word
        let outcome = writeLive(LanguageIntent.display(of: word.keys, segments: word.segments))
        guard outcome == .committed else { return consumes(outcome) }
        if word.keys.isEmpty {
            liveWord = nil
            liveMode = .idle
        } else if !word.koreanSource, word.segments.allSatisfy({ !$0.korean }) {
            // ABC 자판에서 전부 영어로 돌아오면 화면과 키 열이 같으므로 다시 그대로 통과시킨다.
            liveWord?.owned = false
        }
        return true
    }

    // true이면 구분자 키를 보내지 않는다(선택이 남아 있을 수 있는 경우뿐).
    private func finishLiveWord(delimiter: Character) -> Bool {
        var blocksDelimiter = false
        defer {
            liveWord = nil
            liveMode = blocksDelimiter ? .ignoring : .idle
        }
        guard var word = liveWord, !word.keys.isEmpty else {
            liveKoreanContext = false
            return false
        }
        let previous = word.segments
        let previousDisplay = word.owned ? word.displayed : String(word.keys)
        let shownWord = word.owned ? word.displayed : String(word.keys)
        if let value = replacement(forDisplay: shownWord) {
            guard word.owned else {
                // 입력기·호스트의 시스템 텍스트 대치에 맡기고 언어 교정은 하지 않는다.
                liveKoreanContext = false
                return false
            }
            liveWord = word
            let outcome = writeLive(value)
            if outcome != .committed { _ = consumes(outcome) }
            blocksDelimiter = outcome == .selectionUncertain
            if outcome == .committed, delimiter == " " || Self.punctuationDelimiters.contains(delimiter) {
                lastCorrection = AppliedCorrection(
                    element: word.element, applicationPID: word.applicationPID,
                    displayed: value + String(delimiter), original: previousDisplay + String(delimiter),
                    wordKey: String(word.keys).lowercased(), previousInputSource: nil, at: Date(),
                    inputSourceID: word.sourceID
                )
            }
            liveKoreanContext = false
            return blocksDelimiter
        }
        // 끝 글자가 받침 없는 초성으로 남은 영어 단어(the 등)나 짧은 한글 단어는 구분자 시점에 한 번 더 판단한다.
        decide(&word, atEnd: true)
        var changed = false
        // 화면에 실제로 있다고 확인된 직접 표시 문자열. nil이면 입력기 전환·두 번째 어포스트로피 처리를 하지 않는다.
        var verifiedDisplay: String? = word.owned ? word.displayed : nil
        if word.segments != previous {
            let display = LanguageIntent.display(of: word.keys, segments: word.segments)
            // 구분자 키는 선택이 남아 있을 수 있는 경우 말고는 그대로 전달되므로, 확인된 쓰기만 되돌리기 대상으로 기록한다.
            let confirmed: Bool
            if word.owned {
                liveWord = word
                let outcome = writeLive(display)
                if outcome != .committed { _ = consumes(outcome) }
                confirmed = outcome == .committed
                changed = outcome == .committed || outcome == .committedUnverified
                blocksDelimiter = outcome == .selectionUncertain
            } else {
                let result = takeOver(&word, typed: String(word.keys))
                confirmed = result == .done
                changed = confirmed || result == .releasedAfterWrite
                blocksDelimiter = result == .paused
            }
            if blocksDelimiter {
                liveKoreanContext = false
                return true
            }
            verifiedDisplay = confirmed ? display : nil
            if confirmed, delimiter == " " || Self.punctuationDelimiters.contains(delimiter) {
                // 구분자는 이 이벤트 뒤에 입력창에 들어가므로, 되돌리기는 구분자까지 포함해 확인한다.
                lastCorrection = AppliedCorrection(
                    element: word.element, applicationPID: word.applicationPID,
                    displayed: display + String(delimiter), original: previousDisplay + String(delimiter),
                    wordKey: String(word.keys).lowercased(), previousInputSource: nil, at: Date(),
                    inputSourceID: word.sourceID
                )
            }
            if !changed { word.segments = previous }
        }
        liveKoreanContext = delimiter == " " && word.segments.last?.korean == true && (word.owned || changed)
        if Self.isApostropheLike(delimiter), !word.owned, !changed {
            // 영문 그대로 남은 단어 뒤의 첫 어포스트로피: 두 번째가 오면 구분자 기반 엔진이 이 단어만 강제 변환한다.
            buffer = String(word.keys)
            pendingApostrophe = true
        } else if Self.isApostropheLike(delimiter), let shown = verifiedDisplay, word.owned {
            // 직접 표시 중인 단어(부분 변환 포함) 뒤의 첫 어포스트로피. 두 번째가 오면 화면의 실제 길이로 한 번에 바꾼다.
            liveQuote = LiveQuote(
                element: word.element, applicationPID: word.applicationPID, sourceID: word.sourceID,
                keys: String(word.keys), displayed: shown, wordStart: word.wordStart
            )
        } else if liveKoreanContext, verifiedDisplay != nil,
                  isFocusedAndUnchanged(word.element, pid: word.applicationPID, sourceID: word.sourceID) {
            // 확인된 화면 결과가 있고 같은 앱·입력창·입력 소스일 때만, 단어 경계에서 시스템 한글 입력기로 넘긴다.
            let previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            if let correction = lastCorrection {
                lastCorrection = nil
                recordCorrectionSwitchingToKorean(AppliedCorrection(
                    element: correction.element, applicationPID: correction.applicationPID,
                    displayed: correction.displayed, original: correction.original, wordKey: correction.wordKey,
                    previousInputSource: previousSource, at: correction.at, inputSourceID: correction.inputSourceID
                ))
            } else {
                selectKoreanInputSourceIfAvailable()
            }
        }
        return false
    }

    private func decide(_ word: inout LiveWord, atEnd: Bool) {
        guard !word.pinned, let active = word.segments.last else { return }
        let wordKey = String(word.keys).lowercased()
        guard !isExcluded(wordKey) else { return }
        let split: Int?
        if active.korean {
            split = correctsMixedAndEnglish
                ? LanguageIntent.englishStart(in: word.keys, from: active.start, atEnd: atEnd) : nil
        } else {
            split = LanguageIntent.koreanStart(
                in: word.keys, from: active.start, lenient: prefersKorean || liveKoreanContext,
                allowMixed: correctsMixedAndEnglish, atEnd: atEnd
            )
        }
        guard let split else { return }
        let before = word.segments
        if split == active.start {
            // 구간 전체를 바꾸면 앞 구간(반대 언어)과 합쳐진다.
            if word.segments.count == 1 {
                word.segments[0].korean.toggle()
            } else {
                word.segments.removeLast()
            }
        } else {
            word.segments.append(LanguageIntent.Segment(start: split, korean: !active.korean))
        }
        let keyCount = word.keys.count
        let toKorean = !active.korean
        word.lastFlip = (before, keyCount, wordKey)
        logger.info("Live switch: korean=\(toKorean, privacy: .public), keys=\(keyCount, privacy: .public)")
    }

    private func trimSegments(_ word: inout LiveWord) {
        while word.segments.count > 1, let last = word.segments.last, last.start >= word.keys.count {
            word.segments.removeLast()
        }
    }

    // ABC 자판에서 이미 통과시킨 영문 키 열이 커서 바로 앞에 그대로 있을 때만 그 범위를 넘겨받는다.
    private func takeOver(_ word: inout LiveWord, typed: String) -> TakeOverResult {
        let pid = word.applicationPID
        let length = typed.utf16.count
        guard length > 0, isMutable(word.element, pid: pid, sourceID: word.sourceID),
              let caret = collapsedCaret(of: word.element), caret >= length else { return .abandon }
        let wordStart = caret - length
        guard let text = precedingText(of: word.element, caret: caret, length: length + (wordStart > 0 ? 1 : 0)) else {
            return .abandon
        }
        if wordStart > 0 {
            guard let boundary = text.first, Self.isWordBoundary(boundary) else {
                // 단어 앞이 글자·숫자·기호이면 식별자·경로·주소의 일부일 수 있다.
                return String(text.dropFirst()) == typed ? .abandon : .retryLater
            }
            guard String(text.dropFirst()) == typed else { return .retryLater }
        } else if text != typed {
            return .retryLater
        }
        // 별도의 커서 시험 없이, 교체 함수가 선택 범위·선택 텍스트를 매번 정확히 확인한 뒤에만 쓴다.
        let display = LanguageIntent.display(of: word.keys, segments: word.segments)
        switch replaceRange(
            CFRange(location: wordStart, length: length), expected: typed, with: display,
            in: word.element, pid: pid, sourceID: word.sourceID, caret: caret
        ) {
        case .committed:
            word.owned = true
            word.wordStart = wordStart
            word.displayed = display
            return .done
        case .selectionUnconfirmed:
            // 선택 지정이 즉시 반영되지 않는 입력창이다. 이 입력창은 구분자 기반 엔진에 맡긴다.
            markUnverified(word.element, pid: pid)
            return .handOff
        case .committedUnverified:
            releaseAfterUnverifiedWrite()
            return .releasedAfterWrite
        case .selectionUncertain:
            return .paused
        case .rejected:
            recordLiveFailure(for: pid)
            return .abandon
        }
    }

    // 직접 표시 중인 단어 범위만 바꾼다. 같은 앱·같은 입력창·입력 소스·기대한 커서와 원문일 때만 쓴다.
    private func writeLive(_ display: String) -> ReplaceOutcome {
        guard var word = liveWord, word.owned else { return .rejected }
        if display == word.displayed { return .committed }
        let length = word.displayed.utf16.count
        let outcome = replaceRange(
            CFRange(location: word.wordStart, length: length), expected: word.displayed, with: display,
            in: word.element, pid: word.applicationPID, sourceID: word.sourceID, caret: word.wordStart + length
        )
        if outcome == .committed {
            word.displayed = display
            liveWord = word
        }
        return outcome
    }

    // 쓰기 결과에 따른 키 처리. 내용이 반영됐으면(확인 실패 포함) 키를 소비해 중복을 막고,
    // 반영되지 않았으면 키를 입력창에 그대로 전달한다.
    private func consumes(_ outcome: ReplaceOutcome) -> Bool {
        switch outcome {
        case .committed:
            return true
        case .committedUnverified:
            releaseAfterUnverifiedWrite()
            return true
        case .selectionUnconfirmed:
            if let word = liveWord { markUnverified(word.element, pid: word.applicationPID) }
            return abandonLiveWord()
        case .selectionUncertain:
            // 선택이 남아 있을 수 있으므로 키를 보내지 않는다(replaceRange가 알림과 입력창 제외를 처리함).
            liveWord = nil
            liveMode = .ignoring
            lastCorrection = nil
            return true
        case .rejected:
            return abandonLiveWord()
        }
    }

    // 확인에 실패하면 지금까지 표시한 글자는 그대로 두고 이 키부터 입력창에 그대로 전달한다.
    private func abandonLiveWord() -> Bool {
        if let pid = liveWord?.applicationPID { recordLiveFailure(for: pid) }
        liveWord = nil
        liveMode = .ignoring
        logger.info("Live input released: field did not confirm the expected text")
        return false
    }

    // 쓰기 요청은 받아들여졌지만 결과를 확인하지 못했다. 다시 쓰거나 키를 재전달하지 않고 세션만 놓는다.
    private func releaseAfterUnverifiedWrite() {
        if let word = liveWord { markUnverified(word.element, pid: word.applicationPID) }
        liveWord = nil
        liveMode = .ignoring
        lastCorrection = nil
        logger.info("Live input released: write was not confirmed")
    }

    // 확인에 실패한 입력창은 이번 실행 동안 실시간 전환에서 뺀다(허용 근거가 아닌 제외 목록).
    private func markUnverified(_ element: AXUIElement, pid: pid_t) {
        if unverifiedElements.count >= 16 { unverifiedElements.removeFirst() }
        unverifiedElements.append(element)
        recordLiveFailure(for: pid)
    }

    private func recordLiveFailure(for pid: pid_t) {
        let failures = (liveFailuresByPID[pid] ?? 0) + 1
        if liveFailuresByPID.count > 32 { liveFailuresByPID.removeAll() }
        liveFailuresByPID[pid] = failures
        // 같은 앱에서 두 번 실패하면 이번 실행 동안 그 앱은 구분자 기반 엔진에 맡긴다.
        if failures >= 2 {
            if liveDisabledPIDs.count >= 32 { liveDisabledPIDs.removeAll() }
            liveDisabledPIDs.insert(pid)
        }
    }

    // 앱 요소에서 포커스를 묻고 응답 대기 시간을 제한해 이벤트 탭이 오래 멈추지 않게 한다.
    private func focusedElement(of pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.liveAXTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.liveAXTimeout)
        return belongs(element, to: pid) ? element : nil
    }

    private static func isWordBoundary(_ character: Character) -> Bool {
        character.isWhitespace || openingBoundaries.contains(character)
    }
}

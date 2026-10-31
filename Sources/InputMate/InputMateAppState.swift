import AppKit
import ApplicationServices
import Combine
import OSLog
import ServiceManagement

@MainActor
final class InputMateAppState: ObservableObject {
    enum ServiceStatus: Equatable {
        case off
        case needsAccessibility
        case ready
        case unavailable(String)
    }

    @Published private(set) var isLocked = false
    @Published private(set) var serviceStatus: ServiceStatus = .off
    @Published var transientMessage: String?
    @Published private(set) var isLegacyInputMateRunning = false

    let settings: SettingsStore

    private(set) var isStarted = false

    private let eventTap = EventTapController()
    private let typoCorrector = KoreanTypoCorrector()
    private let firstWordRecovery = FirstWordRecovery()
    private let multitouchMonitor = MultitouchMonitor()
    private let healthMonitor = ProcessHealthMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var accessibilityPollingCancellable: AnyCancellable?
    private var automaticUnlockTask: Task<Void, Never>?
    private var lastAutomaticServiceRecoveryAt: Date?

    // 권한 요청 창을 이미 한 번 띄웠는지만 기억한다. 권한이 있다는 근거로는 쓰지 않고 자동 재요청을 막는 데만 쓴다.
    private let accessibilityPromptedKey = "TrackpadGuard.didPromptForAccessibility"
    private let healthLogger = Logger(subsystem: "com.local.screentranslator", category: "Health")

    init(settings: SettingsStore) {
        self.settings = settings

        eventTap.beforeEvent = { [weak self] type, event, proxy in
            guard let self, self.isStarted else { return false }
            let consumed = self.firstWordRecovery.handleEvent(type: type, event: event, proxy: proxy)
            if consumed && type == .keyDown && self.settings.preferences.trackpadProtectionEnabled {
                self.lockForTyping()
            }
            return consumed
        }
        eventTap.onKeyDown = { [weak self] event in
            guard let self, self.isStarted else { return false }
            if self.settings.preferences.trackpadProtectionEnabled {
                self.lockForTyping()
            }
            return self.typoCorrector.handleKeyDown(event)
        }
        firstWordRecovery.replacementProvider = { [weak typoCorrector] in
            typoCorrector?.cachedReplacements ?? [:]
        }
        firstWordRecovery.textFormatter = { [weak typoCorrector] keys in
            typoCorrector?.firstWordText(forKeys: keys)
        }
        firstWordRecovery.onWarning = { [weak self] message in
            if self?.transientMessage != message {
                self?.transientMessage = message
            }
        }
        typoCorrector.onLivePaused = { [weak self] in
            let message = "실시간 한영 전환을 멈췄습니다. 입력창의 선택 영역을 클릭이나 방향키로 해제한 뒤 방금 누른 키를 다시 입력해 주세요."
            if self?.transientMessage != message { self?.transientMessage = message }
        }
        typoCorrector.onManualConversionMessage = { [weak self] message in
            if self?.transientMessage != message { self?.transientMessage = message }
        }
        eventTap.onEmergencyUnlock = { [weak self] in
            self?.unlock(reason: "긴급 해제 단축키로 트랙패드를 다시 켰습니다.")
        }
        eventTap.shouldBlock = { [weak self] type in
            self?.shouldBlock(type) ?? false
        }
        multitouchMonitor.onActivationTouch = { [weak self] in
            self?.unlock(reason: nil)
        }
        healthMonitor.onIssue = { [weak self] issue, snapshot in
            self?.recoverFromHealthIssue(issue, snapshot: snapshot)
        }

        settings.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                guard let self, self.isStarted else { return }
                self.apply(preferences)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self,
                      self.isStarted,
                      case .needsAccessibility = self.serviceStatus,
                      self.accessibilityGranted else { return }
                self.retry()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      self.isStarted,
                      self.settings.preferences.isEnabled,
                      self.settings.preferences.restartProtectionAfterWake else { return }
                self.retry()
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        apply(settings.preferences)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        stopServices()
        accessibilityPollingCancellable?.cancel()
        accessibilityPollingCancellable = nil
        serviceStatus = .off
    }

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var statusText: String {
        if isLegacyInputMateRunning {
            return "InputMate 중복 실행으로 일시중지됨"
        }
        switch serviceStatus {
        case .off: return "입력 기능 꺼짐"
        case .needsAccessibility: return "손쉬운 사용 권한 필요"
        case .ready: return isLocked ? "입력 중 · 트랙패드 잠김" : "입력 기능 준비됨"
        case let .unavailable(message): return message
        }
    }

    func setLegacyInputMateRunning(_ running: Bool) {
        guard isLegacyInputMateRunning != running else { return }
        isLegacyInputMateRunning = running
        if isStarted {
            apply(settings.preferences)
        }
    }

    // 실행 때는 시스템에 현재 권한 상태만 묻는다(요청 창 없음). 이미 허용돼 있으면 그대로 쓰고,
    // 허용돼 있지 않고 이 Mac에서 한 번도 안내한 적이 없을 때만 최초 1회 요청 창을 띄운다.
    // 이후 앱을 다시 실행하거나 업데이트해 권한이 맞지 않아도 자동으로 창을 띄우지 않고, 상태 표시와 설정의 버튼으로만 안내한다.
    func requestAccessibilityOnFirstLaunchIfNeeded() {
        guard settings.preferences.isEnabled else { return }
        let defaults = UserDefaults.standard
        if AXIsProcessTrusted() {
            defaults.set(true, forKey: accessibilityPromptedKey)
            return
        }
        guard !defaults.bool(forKey: accessibilityPromptedKey) else { return }
        defaults.set(true, forKey: accessibilityPromptedKey)
        requestAccessibilityAndRetry()
    }

    // 사용자가 직접 누른 경우에만 호출한다.
    func requestAccessibilityAndRetry() {
        requestAccessibilityPermission()
        openAccessibilitySettings()
    }

    func requestAccessibilityPermission() {
        guard !AXIsProcessTrusted() else {
            retry()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startAccessibilityPolling()
    }

    func checkAccessibilityStatus() {
        refreshAccessibilityStatus()
    }

    func prepareForSettings() {
        refreshAccessibilityStatus()
        if isLocked {
            unlock(reason: nil)
        }
    }

    func retry() {
        stopServices()
        if isStarted {
            apply(settings.preferences)
        }
    }

    func unlockManually() {
        unlock(reason: "트랙패드를 수동으로 다시 켰습니다.")
    }

    // 로그인 시 자동 시작은 HTT의 기존 LoginItemManager만 담당한다.
    // 복사된 원본 prefs.launchAtLogin은 보존하되 입력 도우미가 자동 OS 로그인 등록/취소를 하지 않는다.
    func updateLaunchAtLogin(_ enabled: Bool) {
        settings.preferences.launchAtLogin = enabled
    }

    func restartApplication() {
        retry()
        transientMessage = "입력 도우미 서비스를 다시 시작했습니다."
    }

    @discardableResult
    private func relaunchApplication(failureMessage: String?) -> Bool {
        // HTT 전체(화면번역/메일/BTN)를 종료하지 않고 입력 관련 서비스만 다시 시작한다.
        retry()
        return true
    }

    private func apply(_ preferences: GuardPreferences) {
        guard isStarted else {
            stopServices()
            return
        }

        multitouchMonitor.setActivationRegion(preferences.activationRegion)
        let anyKeyboardFeature = preferences.correctKoreanTypos
            || preferences.manualWordConversionEnabled
            || preferences.sentenceTranslationEnabled
            || preferences.firstWordRecoveryEnabled
        typoCorrector.isAutomaticCorrectionEnabled = preferences.correctKoreanTypos
        typoCorrector.isManualWordConversionEnabled = preferences.manualWordConversionEnabled
        typoCorrector.isSentenceTranslationEnabled = preferences.sentenceTranslationEnabled
        typoCorrector.isPersonalDictionaryEnabled = preferences.personalDictionaryEnabled
        typoCorrector.isPersonalDictionaryAutoLearnEnabled = preferences.personalDictionaryAutoLearnEnabled
        typoCorrector.prefersKorean = preferences.preferKoreanTypoCorrection
        typoCorrector.correctsMixedAndEnglish = preferences.correctMixedAndRestoreEnglish
        typoCorrector.continuousSwitching = preferences.continuousLanguageSwitching
        typoCorrector.isEnabled = preferences.isEnabled && anyKeyboardFeature

        firstWordRecovery.isEnabled = preferences.isEnabled && preferences.firstWordRecoveryEnabled
        firstWordRecovery.targetBundleIDs = Set(preferences.firstWordRecoveryBundleIDs)

        if isLegacyInputMateRunning {
            stopServices()
            serviceStatus = .unavailable("기존 InputMate(TrackpadGuard)가 실행 중이어서 충돌을 방지하기 위해 일시중지했습니다.")
            return
        }

        let anyFeatureEnabled = preferences.isEnabled && (anyKeyboardFeature || preferences.trackpadProtectionEnabled)

        guard anyFeatureEnabled else {
            stopServices()
            accessibilityPollingCancellable?.cancel()
            accessibilityPollingCancellable = nil
            serviceStatus = .off
            return
        }

        guard AXIsProcessTrusted() else {
            stopServices()
            serviceStatus = .needsAccessibility
            // 시스템 설정에서 허용하면 요청 창 없이 상태만 다시 확인해 자동으로 이어서 시작한다.
            if accessibilityPollingCancellable == nil { startAccessibilityPolling() }
            return
        }

        if preferences.trackpadProtectionEnabled {
            do {
                try multitouchMonitor.start()
            } catch {
                multitouchMonitor.stop()
                // 트랙패드가 없는 Mac에서도 키보드 기능은 정상 작동
            }
        } else {
            multitouchMonitor.stop()
        }

        guard eventTap.start() else {
            stopServices()
            serviceStatus = .unavailable("시스템 입력 필터를 시작하지 못했습니다.")
            return
        }

        serviceStatus = .ready
        if preferences.automaticallyRecoverFromHighLoad {
            healthMonitor.start()
        } else {
            healthMonitor.stop()
        }
    }

    private func refreshAccessibilityStatus() {
        guard isStarted, settings.preferences.isEnabled else { return }

        switch (serviceStatus, AXIsProcessTrusted()) {
        case (.needsAccessibility, true):
            accessibilityPollingCancellable?.cancel()
            accessibilityPollingCancellable = nil
            retry()
        case (.ready, false):
            apply(settings.preferences)
        default:
            break
        }
    }

    // 요청 창 없이 AXIsProcessTrusted()로 현재 상태만 확인한다. 허용되거나 보호가 꺼지면 멈춘다.
    private func startAccessibilityPolling() {
        accessibilityPollingCancellable?.cancel()

        accessibilityPollingCancellable = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshAccessibilityStatus()

                if self.accessibilityGranted || !self.settings.preferences.isEnabled || !self.isStarted {
                    self.accessibilityPollingCancellable?.cancel()
                    self.accessibilityPollingCancellable = nil
                }
            }
    }

    private func stopServices() {
        firstWordRecovery.reset()
        firstWordRecovery.isEnabled = false
        typoCorrector.cancelPendingReplacements()
        typoCorrector.reset()
        typoCorrector.isEnabled = false
        healthMonitor.stop()
        automaticUnlockTask?.cancel()
        automaticUnlockTask = nil
        setLocked(false)
        eventTap.stop()
        multitouchMonitor.stop()
    }

    private func recoverFromHealthIssue(_ issue: ProcessHealthIssue, snapshot: ProcessHealthSnapshot) {
        guard isStarted,
              settings.preferences.isEnabled,
              settings.preferences.automaticallyRecoverFromHighLoad else {
            healthMonitor.stop()
            return
        }

        let now = Date()
        let memoryMB = Double(snapshot.residentBytes) / 1_024 / 1_024
        healthLogger.warning(
            "Automatic recovery requested: \(issue.recoveryDescription, privacy: .public), CPU \(snapshot.cpuPercent, format: .fixed(precision: 1))%, memory \(memoryMB, format: .fixed(precision: 1)) MB, main delay \(snapshot.mainThreadDelay, format: .fixed(precision: 1)) seconds"
        )
        // HTT 전체를 종료(NSApp.terminate)하지 않고 입력 관련 서비스만 중지 후 재시작한다.
        lastAutomaticServiceRecoveryAt = now
        retry()
        transientMessage = "\(issue.recoveryDescription)을 감지해 입력 도우미 서비스를 자동으로 복구했습니다."
    }

    // @Published는 같은 값을 다시 대입해도 알림을 보내므로 실제 전환만 발행한다.
    private func lockForTyping() {
        guard isStarted, settings.preferences.isEnabled, settings.preferences.trackpadProtectionEnabled, serviceStatus == .ready else { return }
        setLocked(true)
        multitouchMonitor.arm()
        scheduleAutomaticUnlock()
    }

    private func unlock(reason: String?) {
        automaticUnlockTask?.cancel()
        automaticUnlockTask = nil
        setLocked(false)
        multitouchMonitor.disarm()
        // 사유가 없는 자동 해제가 표시 중인 경고를 지우지 않도록, 새 사유가 있을 때만 갱신한다. 경고는 사용자가 확인을 눌러 닫는다.
        if let reason, transientMessage != reason {
            transientMessage = reason
        }
    }

    private func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
    }

    private func scheduleAutomaticUnlock() {
        automaticUnlockTask?.cancel()
        automaticUnlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unlock(reason: nil)
        }
    }

    private func shouldBlock(_ type: CGEventType) -> Bool {
        // 클릭으로 커서 위치가 바뀌면 교정 후보 구절이 무효가 되므로 비운다.
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            firstWordRecovery.pointerPressed()
            typoCorrector.pointerPressed()
        default:
            break
        }

        guard isStarted, settings.preferences.trackpadProtectionEnabled, isLocked else { return false }

        if isPointerInput(type), !multitouchMonitor.hasActiveTouches {
            unlock(reason: nil)
            return false
        }

        let preferences = settings.preferences

        return switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            preferences.blockPointerMovement
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            preferences.blockClicks
        case .scrollWheel:
            preferences.blockScrolling
        default:
            false
        }
    }

    private func isPointerInput(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel, .tabletPointer, .tabletProximity:
            true
        default:
            false
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

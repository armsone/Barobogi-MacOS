import AppKit
import Combine
import OSLog

/// HTT 내에서 InputMate(앱별 입력 언어, 한글 교정, 첫 단어 복구, 트랙패드 보호)의 수명주기,
/// 설정 이전, 기존 com.armsone.TrackpadGuard와의 충돌 감지 및 UI 연결을 총괄한다.
@MainActor
final class InputMateCoordinator: ObservableObject {
    static let shared = InputMateCoordinator()

    let settings: SettingsStore
    let appState: InputMateAppState
    let appInputLanguageStore: AppInputLanguageStore
    let appInputLanguageController: AppInputLanguageController

    @Published private(set) var isLegacyInputMateRunning: Bool = false
    @Published private(set) var migrationFailed: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private static let legacyBundleID = "com.armsone.TrackpadGuard"
    private let logger = Logger(subsystem: "com.local.screentranslator", category: "InputMateCoordinator")
    private var isStarted = false

    private init() {
        // 1. 초기화보다 먼저 기존 TrackpadGuard 설정 및 개인 사전 일회성 이전 (단독 소유)
        let migrationSuccess = InputMateMigration.migrateIfNeeded()
        self.migrationFailed = !migrationSuccess

        // 2. 저장소 및 상태 객체 생성
        let settingsStore = SettingsStore()
        let appState = InputMateAppState(settings: settingsStore)
        let languageStore = AppInputLanguageStore()
        let languageController = AppInputLanguageController(store: languageStore)

        self.settings = settingsStore
        self.appState = appState
        self.appInputLanguageStore = languageStore
        self.appInputLanguageController = languageController

        if !migrationSuccess {
            logger.error("InputMate migration failed due to unreadable or corrupted data. Input services will be withheld.")
        }

        // 3. 전체 설정 변경 감지 (isEnabled 변경 시 appInputLanguageController 일시중지/재개 동기화)
        settingsStore.$preferences
            .map { $0.isEnabled }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateLanguageControllerSuspension()
            }
            .store(in: &cancellables)

        updateLanguageControllerSuspension()
    }

    func start() {
        guard !isStarted else { return }
        guard !migrationFailed else {
            logger.warning("InputMate migration failed; input services will not start.")
            updateLanguageControllerSuspension()
            return
        }
        isStarted = true

        // 1. 기존 InputMate(TrackpadGuard) 중복 실행 여부 확인
        checkLegacyInputMate()

        // 2. 기존 InputMate 실행/종료 감지 옵저버 등록
        let center = NSWorkspace.shared.notificationCenter
        let launchObs = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.legacyBundleID else { return }
            self?.handleLegacyAppStatusChanged(isRunning: true)
        }

        let termObs = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.legacyBundleID else { return }
            self?.checkLegacyInputMate()
        }

        workspaceObservers = [launchObs, termObs]

        // 3. AppState 및 LanguageController 시작
        appState.start()
        appInputLanguageController.start()
        updateLanguageControllerSuspension()

        logger.info("InputMate coordinator started in HTT.")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        appState.stop()
        updateLanguageControllerSuspension()
        appInputLanguageController.stop()
        logger.info("InputMate coordinator stopped in HTT.")
    }

    /// 전체 입력 기능 일시정지 / 재개 토글
    func toggleEnabled() {
        guard !migrationFailed else { return }
        settings.preferences.isEnabled.toggle()
        updateLanguageControllerSuspension()
    }

    private func checkLegacyInputMate() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleID)
        let isRunning = !apps.isEmpty
        handleLegacyAppStatusChanged(isRunning: isRunning)
    }

    private func handleLegacyAppStatusChanged(isRunning: Bool) {
        guard isLegacyInputMateRunning != isRunning else { return }
        isLegacyInputMateRunning = isRunning
        appState.setLegacyInputMateRunning(isRunning)
        updateLanguageControllerSuspension()
        if isRunning {
            logger.warning("Legacy InputMate (\(Self.legacyBundleID)) detected running. HTT input features paused.")
        } else {
            logger.info("Legacy InputMate terminated. HTT input features resumed.")
        }
    }

    private func updateLanguageControllerSuspension() {
        let shouldSuspend = !isStarted || !settings.preferences.isEnabled || isLegacyInputMateRunning || migrationFailed
        appInputLanguageController.setSuspended(shouldSuspend)
    }
}

import AppKit
import Combine
import Foundation
import SwiftUI

/// HTT 내부 BTN 모듈의 설정 키·기본값 및 UserDefaults 도메인 해석.
public enum BTNPreferences {
    public static let httBundleIdentifier = "com.local.screentranslator"
    public static let legacyBTNBundleIdentifier = "com.nasfinder.BackToNormal"

    public static let managementEnabledKey = "HTT.BTN.managementEnabled"
    public static let autoRefreshEnabledKey = "HTT.BTN.autoRefreshEnabled"
    public static let cleanupEnabledKey = "HTT.BTN.cleanupEnabled"
    public static let migrationCompletedKey = "HTT.BTN.migrationCompleted"

    /// 신규 사용자 기본값: Mac 관리와 정리 기능은 꺼짐, 자동 새로고침은 켜짐(관리가 켜졌을 때만 동작).
    public static let defaultManagementEnabled = false
    public static let defaultAutoRefreshEnabled = true
    public static let defaultCleanupEnabled = false

    /// HTT 도메인(`com.local.screentranslator`) UserDefaults를 반환한다.
    /// 현재 실행 번들이 HTT 자체일 때는 `UserDefaults(suiteName:)`이 nil을 반환하므로 `.standard`를 사용한다.
    public static func resolveHTTDefaults(
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults? {
        if mainBundleIdentifier == httBundleIdentifier {
            return .standard
        }
        return UserDefaults(suiteName: httBundleIdentifier)
    }

    /// 기존 독립 BTN 도메인(`com.nasfinder.BackToNormal`) 읽기 전용 조회용 UserDefaults를 반환한다.
    public static func resolveLegacyBTNDefaults(
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults? {
        if mainBundleIdentifier == legacyBTNBundleIdentifier {
            return .standard
        }
        return UserDefaults(suiteName: legacyBTNBundleIdentifier)
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func defaultLegacyPreferencesPlistURL() -> URL {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
        return libraryDirectory
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(legacyBTNBundleIdentifier).plist")
    }

    public static func boolValue(
        forKey key: String,
        default defaultValue: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    public static func isManagementEnabled(in defaults: UserDefaults) -> Bool {
        boolValue(forKey: managementEnabledKey, default: defaultManagementEnabled, in: defaults)
    }

    public static func isAutoRefreshEnabled(in defaults: UserDefaults) -> Bool {
        boolValue(forKey: autoRefreshEnabledKey, default: defaultAutoRefreshEnabled, in: defaults)
    }

    public static func isCleanupEnabled(in defaults: UserDefaults) -> Bool {
        boolValue(forKey: cleanupEnabledKey, default: defaultCleanupEnabled, in: defaults)
    }
}

/// 일회성 데이터 이전 실패 사유. 개인 경로·사용자명·이력 원문을 절대 포함하지 않는다.
public enum BTNMigrationFailureReason: String, Equatable, Sendable {
    case protectionReadFailed
    case protectionParseFailed
    case protectionCopyFailed
    case historyReadFailed
    case historyParseFailed
    case historyCopyFailed
    case completionMarkerWriteFailed

    public var userFacingMessage: String {
        switch self {
        case .protectionReadFailed:
            return "기존 BTN 보호 목록을 읽지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        case .protectionParseFailed:
            return "기존 BTN 보호 목록 형식을 확인하지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        case .protectionCopyFailed:
            return "보호 목록을 HTT 설정으로 이전하지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        case .historyReadFailed:
            return "기존 BTN 정리 이력을 읽지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        case .historyParseFailed:
            return "기존 BTN 정리 이력 형식을 확인하지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        case .historyCopyFailed:
            return "정리 이력을 HTT 저장소로 이전하지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        case .completionMarkerWriteFailed:
            return "이전 완료 상태를 저장하지 못해 안전을 위해 Mac 관리 및 정리 기능을 중지했습니다."
        }
    }
}

public enum BTNMigrationOutcome: Equatable, Sendable {
    case alreadyCompleted
    case migrated
    case failed(BTNMigrationFailureReason)
}

/// 일회성 데이터 이전 경로·저장소 구성. 운영 기본값과 격리 테스트 구성을 모두 지원한다.
public struct BTNMigrationConfiguration {
    public let httDefaults: UserDefaults
    public let legacyDefaults: UserDefaults?
    public let legacyPreferencesPlistURL: URL?
    public let legacyPrimaryHistoryFileURL: URL
    public let legacyFallbackHistoryFileURL: URL
    public let httHistoryFileURL: URL

    public init(
        httDefaults: UserDefaults,
        legacyDefaults: UserDefaults?,
        legacyPreferencesPlistURL: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        legacyPrimaryHistoryFileURL: URL? = nil,
        legacyFallbackHistoryFileURL: URL? = nil,
        httHistoryFileURL: URL? = nil
    ) {
        let baseAppSupport = applicationSupportDirectory ?? BTNPreferences.defaultApplicationSupportDirectory()
        self.httDefaults = httDefaults
        self.legacyDefaults = legacyDefaults
        self.legacyPreferencesPlistURL = legacyPreferencesPlistURL
        self.legacyPrimaryHistoryFileURL = legacyPrimaryHistoryFileURL
            ?? baseAppSupport
                .appendingPathComponent("BTN", isDirectory: true)
                .appendingPathComponent(CleanupAuditStore.historyFileName)
        self.legacyFallbackHistoryFileURL = legacyFallbackHistoryFileURL
            ?? baseAppSupport
                .appendingPathComponent("BackToNormal", isDirectory: true)
                .appendingPathComponent(CleanupAuditStore.historyFileName)
        self.httHistoryFileURL = httHistoryFileURL
            ?? CleanupAuditStore.httHistoryFileURL(applicationSupportDirectory: baseAppSupport)
    }

    public static func production() -> BTNMigrationConfiguration {
        let appSupport = BTNPreferences.defaultApplicationSupportDirectory()
        return BTNMigrationConfiguration(
            httDefaults: BTNPreferences.resolveHTTDefaults() ?? .standard,
            legacyDefaults: BTNPreferences.resolveLegacyBTNDefaults(),
            legacyPreferencesPlistURL: BTNPreferences.defaultLegacyPreferencesPlistURL(),
            applicationSupportDirectory: appSupport,
            httHistoryFileURL: CleanupAuditStore.httHistoryFileURL(applicationSupportDirectory: appSupport)
        )
    }
}

/// 기존 독립 BTN의 보호 목록과 정리 이력을 HTT로 단 한 번 안전하게 이전한다.
/// - 기존 HTT 값이 있으면 항상 우선 보존한다.
/// - 원본(`com.nasfinder.BackToNormal`, `Application Support/BTN`, `BackToNormal`)은 읽기만 하며 수정·삭제하지 않는다.
/// - 읽기/파싱/복사 오류가 하나라도 있으면 완료 마커를 기록하지 않고 실패를 반환한다.
public enum BTNDataMigrator {
    private enum PreparedProtectionMigration {
        case keepExistingHTT
        case noLegacyData
        case writeNormalized([String])
    }

    private enum PreparedHistoryMigration {
        case keepExistingHTT
        case noLegacyData
        case writeValidatedData(Data)
    }

    public static func migrateIfNeeded(configuration: BTNMigrationConfiguration) -> BTNMigrationOutcome {
        let httDefaults = configuration.httDefaults

        if let markerObject = httDefaults.object(forKey: BTNPreferences.migrationCompletedKey) {
            if let isCompleted = markerObject as? Bool, isCompleted {
                return .alreadyCompleted
            }
            if httDefaults.bool(forKey: BTNPreferences.migrationCompletedKey) {
                return .alreadyCompleted
            }
        }

        // 부분 이전을 방지하기 위해 보호 목록과 정리 이력을 모두 먼저 읽고 검증한 뒤 반영한다.
        let preparedProtection: PreparedProtectionMigration
        switch prepareProtectionListMigration(configuration: configuration) {
        case .success(let plan):
            preparedProtection = plan
        case .failure(let reason):
            return .failed(reason)
        }

        let preparedHistory: PreparedHistoryMigration
        switch prepareCleanupHistoryMigration(configuration: configuration) {
        case .success(let plan):
            preparedHistory = plan
        case .failure(let reason):
            return .failed(reason)
        }

        if let protectionCommitFailure = commitProtectionListMigration(
            preparedProtection,
            httDefaults: httDefaults
        ) {
            return .failed(protectionCommitFailure)
        }

        if let historyCommitFailure = commitCleanupHistoryMigration(
            preparedHistory,
            targetURL: configuration.httHistoryFileURL
        ) {
            return .failed(historyCommitFailure)
        }

        httDefaults.set(true, forKey: BTNPreferences.migrationCompletedKey)
        guard httDefaults.bool(forKey: BTNPreferences.migrationCompletedKey) else {
            return .failed(.completionMarkerWriteFailed)
        }

        return .migrated
    }

    private enum PreparationResult<Plan> {
        case success(Plan)
        case failure(BTNMigrationFailureReason)
    }

    private static func prepareProtectionListMigration(
        configuration: BTNMigrationConfiguration
    ) -> PreparationResult<PreparedProtectionMigration> {
        let key = CleanupProtectionStore.protectionKey
        let httDefaults = configuration.httDefaults

        // 기존 HTT 값이 이미 있으면 형식을 검증한 뒤 그대로 우선 유지한다.
        if let existingHTTObject = httDefaults.object(forKey: key) {
            guard decodeStringArray(from: existingHTTObject) != nil else {
                return .failure(.protectionParseFailed)
            }
            return .success(.keepExistingHTT)
        }

        var plistIdentifiers: [String]?
        if let plistURL = configuration.legacyPreferencesPlistURL {
            switch readFileDataIfPresent(at: plistURL) {
            case .missing:
                break
            case .readFailed:
                return .failure(.protectionReadFailed)
            case .data(let plistData):
                guard let plistObject = try? PropertyListSerialization.propertyList(
                    from: plistData,
                    options: [],
                    format: nil
                ),
                let plistDictionary = plistObject as? [String: Any]
                else {
                    return .failure(.protectionParseFailed)
                }

                if let rawProtectionValue = plistDictionary[key] {
                    guard let parsed = decodeStringArray(from: rawProtectionValue) else {
                        return .failure(.protectionParseFailed)
                    }
                    plistIdentifiers = parsed
                }
            }
        }

        var defaultsIdentifiers: [String]?
        if let legacyDefaults = configuration.legacyDefaults,
           let rawLegacyObject = legacyDefaults.object(forKey: key) {
            guard let parsed = decodeStringArray(from: rawLegacyObject) else {
                return .failure(.protectionParseFailed)
            }
            defaultsIdentifiers = parsed
        }

        guard let migratedIdentifiers = defaultsIdentifiers ?? plistIdentifiers else {
            return .success(.noLegacyData)
        }

        let normalized = Array(Set(migratedIdentifiers)).sorted()
        return .success(.writeNormalized(normalized))
    }

    private static func commitProtectionListMigration(
        _ plan: PreparedProtectionMigration,
        httDefaults: UserDefaults
    ) -> BTNMigrationFailureReason? {
        switch plan {
        case .keepExistingHTT, .noLegacyData:
            return nil
        case .writeNormalized(let normalized):
            let key = CleanupProtectionStore.protectionKey
            httDefaults.set(normalized, forKey: key)
            guard let writtenObject = httDefaults.object(forKey: key),
                  let writtenArray = decodeStringArray(from: writtenObject),
                  Set(writtenArray) == Set(normalized)
            else {
                return .protectionCopyFailed
            }
            return nil
        }
    }

    private static func prepareCleanupHistoryMigration(
        configuration: BTNMigrationConfiguration
    ) -> PreparationResult<PreparedHistoryMigration> {
        let targetURL = configuration.httHistoryFileURL

        // 기존 HTT 이력 파일이 이미 존재하면 형식을 확인하고 우선 보존한다.
        switch readFileDataIfPresent(at: targetURL) {
        case .data(let existingData):
            guard (try? JSONDecoder().decode([CleanupAuditEntry].self, from: existingData)) != nil else {
                return .failure(.historyParseFailed)
            }
            return .success(.keepExistingHTT)
        case .readFailed:
            return .failure(.historyReadFailed)
        case .missing:
            break
        }

        // Application Support/BTN/cleanup-history.json 우선, 없을 때만 BackToNormal fallback.
        let legacyData: Data?
        switch readFileDataIfPresent(at: configuration.legacyPrimaryHistoryFileURL) {
        case .data(let primaryData):
            legacyData = primaryData
        case .readFailed:
            return .failure(.historyReadFailed)
        case .missing:
            switch readFileDataIfPresent(at: configuration.legacyFallbackHistoryFileURL) {
            case .data(let fallbackData):
                legacyData = fallbackData
            case .readFailed:
                return .failure(.historyReadFailed)
            case .missing:
                legacyData = nil
            }
        }

        guard let sourceData = legacyData else {
            return .success(.noLegacyData)
        }

        guard (try? JSONDecoder().decode([CleanupAuditEntry].self, from: sourceData)) != nil else {
            return .failure(.historyParseFailed)
        }

        return .success(.writeValidatedData(sourceData))
    }

    private static func commitCleanupHistoryMigration(
        _ plan: PreparedHistoryMigration,
        targetURL: URL
    ) -> BTNMigrationFailureReason? {
        switch plan {
        case .keepExistingHTT, .noLegacyData:
            return nil
        case .writeValidatedData(let sourceData):
            do {
                try FileManager.default.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try sourceData.write(to: targetURL, options: .atomic)
                let verifiedData = try Data(contentsOf: targetURL)
                _ = try JSONDecoder().decode([CleanupAuditEntry].self, from: verifiedData)
                return nil
            } catch {
                return .historyCopyFailed
            }
        }
    }

    private enum OptionalFileReadResult {
        case missing
        case data(Data)
        case readFailed
    }

    private static func readFileDataIfPresent(at url: URL) -> OptionalFileReadResult {
        do {
            let data = try Data(contentsOf: url)
            return .data(data)
        } catch {
            if isNoSuchFileError(error) {
                return .missing
            }
            return .readFailed
        }
    }

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoSuchFile.rawValue {
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return underlying.code == Int(ENOENT)
            }
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        return false
    }

    private static func decodeStringArray(from rawValue: Any) -> [String]? {
        if let strings = rawValue as? [String] {
            return strings
        }
        guard let rawArray = rawValue as? [Any] else {
            return nil
        }
        var strings: [String] = []
        strings.reserveCapacity(rawArray.count)
        for element in rawArray {
            guard let string = element as? String else {
                return nil
            }
            strings.append(string)
        }
        return strings
    }
}

private final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens.isEmpty
    }

    func store(_ newTokens: [NSObjectProtocol]) {
        lock.lock()
        let previous = tokens
        tokens = newTokens
        lock.unlock()
        for token in previous {
            center.removeObserver(token)
        }
    }

    func removeAll() {
        lock.lock()
        let previous = tokens
        tokens.removeAll()
        lock.unlock()
        for token in previous {
            center.removeObserver(token)
        }
    }

    deinit {
        removeAll()
    }
}

/// HTT 호스트 앱과 BTN 진단·정리 모듈을 연결하는 단일 진입점.
@MainActor
public final class BTNIntegration: ObservableObject {
    public static let shared = BTNIntegration()
    public static let detailWindowTitle = "HTT — Mac 관리"

    @Published public var isManagementEnabled: Bool {
        didSet {
            guard !isApplyingInternalState, isManagementEnabled != oldValue else { return }
            httDefaults.set(isManagementEnabled, forKey: BTNPreferences.managementEnabledKey)
            if isManagementEnabled {
                isRuntimeActive = true
                startWorkspaceObservationIfNeeded()
                retryMigrationIfIncomplete()
            }
            _ = refreshStandaloneConflictState(forceSync: true)
        }
    }

    @Published public var isAutoRefreshEnabled: Bool {
        didSet {
            guard !isApplyingInternalState, isAutoRefreshEnabled != oldValue else { return }
            httDefaults.set(isAutoRefreshEnabled, forKey: BTNPreferences.autoRefreshEnabledKey)
            syncModelConfiguration()
        }
    }

    @Published public var isCleanupEnabled: Bool {
        didSet {
            guard !isApplyingInternalState, isCleanupEnabled != oldValue else { return }
            if hasMigrationError && isCleanupEnabled {
                isApplyingInternalState = true
                isCleanupEnabled = false
                isApplyingInternalState = false
                syncModelConfiguration()
                return
            }
            httDefaults.set(isCleanupEnabled, forKey: BTNPreferences.cleanupEnabledKey)
            _ = refreshStandaloneConflictState(forceSync: true)
        }
    }

    @Published public private(set) var isStandaloneConflictActive: Bool
    @Published public private(set) var migrationFailureMessage: String?
    @Published public private(set) var isRuntimeActive = false

    let model: MonitorViewModel
    private(set) var detailWindow: NSWindow?

    private let migrationConfiguration: BTNMigrationConfiguration
    private let httDefaults: UserDefaults
    private let workspaceNotificationCenter: NotificationCenter
    private let standaloneConflictDetector: (pid_t?) -> Bool
    private let observerBag: NotificationObserverBag
    private var modelChangeCancellable: AnyCancellable?
    private var isApplyingInternalState = false

    public convenience init(
        migrationConfiguration: BTNMigrationConfiguration = .production(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        standaloneConflictDetector: @escaping () -> Bool
    ) {
        self.init(
            migrationConfiguration: migrationConfiguration,
            workspaceNotificationCenter: workspaceNotificationCenter,
            conflictDetectorWithExcludedPID: { _ in standaloneConflictDetector() }
        )
    }

    public init(
        migrationConfiguration: BTNMigrationConfiguration = .production(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        conflictDetectorWithExcludedPID: @escaping (pid_t?) -> Bool = BTNIntegration.isStandaloneBTNRunning
    ) {
        let defaults = migrationConfiguration.httDefaults

        // 정상 저장소 초기화·읽기보다 일회성 데이터 이전을 반드시 먼저 수행한다.
        let migrationOutcome = BTNDataMigrator.migrateIfNeeded(configuration: migrationConfiguration)
        let initialMigrationError: String?
        switch migrationOutcome {
        case .alreadyCompleted, .migrated:
            initialMigrationError = nil
        case .failed(let reason):
            initialMigrationError = reason.userFacingMessage
        }

        let storedManagementEnabled = BTNPreferences.isManagementEnabled(in: defaults)
        let storedAutoRefreshEnabled = BTNPreferences.isAutoRefreshEnabled(in: defaults)
        let storedCleanupEnabled = BTNPreferences.isCleanupEnabled(in: defaults)

        let auditStore = CleanupAuditStore(fileURL: migrationConfiguration.httHistoryFileURL)
        let protectionStore = CleanupProtectionStore(defaults: defaults)
        let viewModel = MonitorViewModel(
            auditStore: auditStore,
            protectionStore: protectionStore,
            loadStoresOnInit: false,
            startsImmediately: false
        )

        self.migrationConfiguration = migrationConfiguration
        self.httDefaults = defaults
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.standaloneConflictDetector = conflictDetectorWithExcludedPID
        self.observerBag = NotificationObserverBag(center: workspaceNotificationCenter)
        self.model = viewModel

        self.isManagementEnabled = storedManagementEnabled
        self.isAutoRefreshEnabled = storedAutoRefreshEnabled
        // 이전 실패 시에는 저장된 사용자 선호값을 덮어쓰지 않되 메모리상 정리 활성화를 즉시 차단한다.
        self.isCleanupEnabled = (initialMigrationError == nil) ? storedCleanupEnabled : false
        self.isStandaloneConflictActive = conflictDetectorWithExcludedPID(nil)
        self.migrationFailureMessage = initialMigrationError

        viewModel.evaluateConflictBeforeWork = { [weak self] in
            guard let self else { return false }
            return self.refreshStandaloneConflictState()
        }

        self.modelChangeCancellable = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        startWorkspaceObservationIfNeeded()
        syncModelConfiguration()

        if initialMigrationError == nil {
            viewModel.reloadStoresAfterMigrationSuccess()
        }
    }

    public var hasMigrationError: Bool {
        migrationFailureMessage != nil
    }

    public var isActivelyMonitoring: Bool {
        model.canRunMonitoring
    }

    public var canExecuteCleanup: Bool {
        model.canExecuteCleanup
    }

    public var lastRefreshed: Date? {
        model.lastRefreshed
    }

    public var modeBadgeTitle: String {
        if hasMigrationError { return "오류로 중지됨" }
        if isStandaloneConflictActive { return "독립 BTN 실행 중" }
        if !isManagementEnabled { return "꺼짐" }
        if !isRuntimeActive { return "중지됨" }
        if !isCleanupEnabled { return "관찰 전용" }
        return "권장 모드"
    }

    public var statusSymbolName: String {
        if hasMigrationError { return "exclamationmark.triangle.fill" }
        if isStandaloneConflictActive { return "pause.circle.fill" }
        if !isManagementEnabled { return "power" }
        if !isRuntimeActive { return "stop.circle" }
        return model.statusSymbolName
    }

    public var statusColor: Color {
        if hasMigrationError { return .red }
        if isStandaloneConflictActive { return .orange }
        if !isManagementEnabled || !isRuntimeActive { return .secondary }
        return model.statusColor
    }

    public var statusSummary: String {
        if hasMigrationError {
            return "이전 미완료(데이터 확인 실패) · 정리 및 관리 차단됨"
        }
        if isStandaloneConflictActive {
            return "일시 중지됨 (독립 BTN 실행 중) · 종료 후 자동 복구"
        }
        if !isManagementEnabled {
            return "꺼짐 · Mac 관리 사용 안 함"
        }
        if !isRuntimeActive {
            return "중지됨 · 시작 대기 중"
        }
        return "\(model.effectiveStatusLabel) · \(model.modeBadgeTitle) — \(model.effectiveKeyCause)"
    }

    /// 호스트 앱 생명주기에 맞춰 모듈을 시작한다. `isManagementEnabled`가 꺼져 있으면 감시·타이머·정리를 시작하지 않는다.
    public func startIfEnabled() {
        isRuntimeActive = true
        startWorkspaceObservationIfNeeded()
        retryMigrationIfIncomplete()
        _ = refreshStandaloneConflictState(forceSync: true)
    }

    /// 활성 감시·30초 타이머·새 진단 및 정리를 중지하고 진행 중인 배치 정리는 현재 안전 단위까지만 마친다.
    public func stop() {
        isRuntimeActive = false
        syncModelConfiguration()
    }

    /// 기존 `DetailView(model:)`를 담는 단일 재사용 `NSWindow`(`HTT — Mac 관리`)를 연다.
    public func showDetailWindow() {
        _ = refreshStandaloneConflictState()
        _ = NSApplication.shared

        let window: NSWindow
        if let existingWindow = detailWindow {
            window = existingWindow
        } else {
            let hostingController = NSHostingController(rootView: DetailView(model: model))
            let createdWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            createdWindow.contentViewController = hostingController
            createdWindow.title = Self.detailWindowTitle
            createdWindow.minSize = NSSize(width: 580, height: 480)
            createdWindow.isReleasedWhenClosed = false
            createdWindow.center()
            createdWindow.setFrameAutosaveName("HTT.BTN.DetailWindow")
            self.detailWindow = createdWindow
            window = createdWindow
        }

        window.title = Self.detailWindowTitle
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)

        if NSApp != nil {
            if #available(macOS 14.0, *) {
                NSApplication.shared.activate()
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    public nonisolated static func isStandaloneBTNRunning(excludingTerminatedPID: pid_t? = nil) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: BTNPreferences.legacyBTNBundleIdentifier)
            .contains { app in
                !app.isTerminated
                    && app.processIdentifier != ownPID
                    && app.processIdentifier != excludingTerminatedPID
            }
    }

    @discardableResult
    func refreshStandaloneConflictState(
        excludingTerminatedPID: pid_t? = nil,
        forceSync: Bool = false
    ) -> Bool {
        let conflict = standaloneConflictDetector(excludingTerminatedPID)
        if conflict != isStandaloneConflictActive {
            isStandaloneConflictActive = conflict
            syncModelConfiguration()
        } else if forceSync {
            syncModelConfiguration()
        }
        return conflict
    }

    private func retryMigrationIfIncomplete() {
        guard hasMigrationError else { return }
        let outcome = BTNDataMigrator.migrateIfNeeded(configuration: migrationConfiguration)
        switch outcome {
        case .alreadyCompleted, .migrated:
            migrationFailureMessage = nil
            let storedCleanupEnabled = BTNPreferences.isCleanupEnabled(in: httDefaults)
            if isCleanupEnabled != storedCleanupEnabled {
                isApplyingInternalState = true
                isCleanupEnabled = storedCleanupEnabled
                isApplyingInternalState = false
            }
            syncModelConfiguration()
            model.reloadStoresAfterMigrationSuccess()
        case .failed(let reason):
            migrationFailureMessage = reason.userFacingMessage
            if isCleanupEnabled {
                isApplyingInternalState = true
                isCleanupEnabled = false
                isApplyingInternalState = false
            }
        }
    }

    private func syncModelConfiguration() {
        let effectiveCleanupEnabled = !hasMigrationError && isCleanupEnabled
        model.applyRuntimeConfiguration(
            isManagementEnabled: isManagementEnabled,
            isAutoRefreshEnabled: isAutoRefreshEnabled,
            isCleanupEnabled: effectiveCleanupEnabled,
            isStandaloneConflictActive: isStandaloneConflictActive,
            migrationFailureMessage: migrationFailureMessage,
            shouldActivelyMonitor: isRuntimeActive
        )
    }

    private func startWorkspaceObservationIfNeeded() {
        guard observerBag.isEmpty else { return }
        let observedNames: [Notification.Name] = [
            NSWorkspace.willLaunchApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        let tokens = observedNames.map { notificationName in
            workspaceNotificationCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                let terminatedPID: pid_t? = (notificationName == NSWorkspace.didTerminateApplicationNotification)
                    ? app?.processIdentifier
                    : nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let bundleID, bundleID != BTNPreferences.legacyBTNBundleIdentifier {
                        return
                    }
                    _ = self.refreshStandaloneConflictState(excludingTerminatedPID: terminatedPID)
                }
            }
        }
        observerBag.store(tokens)
    }
}

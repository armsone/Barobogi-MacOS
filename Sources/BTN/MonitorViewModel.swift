import Foundation
import SwiftUI

enum CleanupActivity: Equatable {
    case idle
    case scanning
    case cleaning
    case autoCleaning
}

private final class CleanupBatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowNextUnit = true

    var canStartNextUnit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowNextUnit
    }

    func stopAfterCurrentSafeUnit() {
        lock.lock()
        allowNextUnit = false
        lock.unlock()
    }
}

/// 수집 → 진단 → 화면 상태를 잇는 뷰모델. 활성 상태이고 자동 새로고침이 켜져 있을 때 30초마다 새로고침한다.
@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var diagnosis = DiagnosticEngine.evaluate(metrics: nil, processes: [])
    @Published private(set) var metrics: MetricsSnapshot?
    @Published private(set) var storage: StorageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var cleanupCandidates: [CleanupCandidate] = []
    @Published var selectedCleanupIDs: Set<String> = []
    @Published private(set) var cleanupResults: [CleanupExecutionResult] = []
    @Published private(set) var processCleanupCandidates: [ProcessCleanupCandidate] = []
    @Published var selectedProcessCleanupIDs: Set<String> = []
    @Published private(set) var processCleanupResults: [ProcessCleanupExecutionResult] = []
    @Published private(set) var cleanupActivity: CleanupActivity = .idle
    @Published var isShowingCleanupConfirmation = false
    @Published private(set) var cleanupImpact: CleanupImpactSummary?
    @Published private(set) var cleanupHistory: [CleanupAuditEntry] = []
    @Published private(set) var protectedCleanupIDs: Set<String> = []
    @Published private(set) var automaticCleanupSummary: String?
    @Published private(set) var isClearingDerivedData = false
    @Published private(set) var derivedDataClearResult: DerivedDataClearResult?

    @Published private(set) var isManagementEnabled = false
    @Published private(set) var isAutoRefreshEnabled = true
    @Published private(set) var isCleanupEnabled = false
    @Published private(set) var isStandaloneConflictActive = false
    @Published private(set) var migrationFailureMessage: String?

    /// 활성 작업 시작 직전에 독립 BTN 실행 충돌을 즉시 재확인하는 훅. 충돌이면 true를 반환한다.
    var evaluateConflictBeforeWork: (() -> Bool)?

    private var timer: Timer?
    private var lastStorageScan: Date?
    /// 새로고침 진행 중에 들어온 요청을 잃지 않고 완료 직후 한 번 더 실행하기 위한 플래그.
    private var isRefreshQueued = false
    /// 저장 공간 스캔 무효화 세대. 무효화 이전에 시작한 스캔이 lastStorageScan을 덮어쓰지 못하게 한다.
    private var storageScanGeneration = 0
    /// 관리 중지·꺼짐·충돌 전환 시 진행 중이던 늦은 새로고침 결과를 폐기하기 위한 세대.
    private var monitoringGeneration: UInt64 = 0
    /// 후보 스캔 중 관리가 중지됐을 때 늦은 스캔 결과를 폐기하기 위한 세대.
    private var scanGeneration: UInt64 = 0
    private var isActivelyMonitoring = false
    private var activeBatchGate: CleanupBatchGate?

    private let auditStore: CleanupAuditStore
    private let protectionStore: CleanupProtectionStore
    static let refreshInterval: TimeInterval = 30
    static let storageRefreshInterval: TimeInterval = 10 * 60

    var isScanningCleanup: Bool { cleanupActivity == .scanning }
    var isAutoCleaning: Bool { cleanupActivity == .autoCleaning }
    var isCleaning: Bool { cleanupActivity == .cleaning || cleanupActivity == .autoCleaning }
    var isCleanupBusy: Bool { cleanupActivity != .idle }
    var hasMigrationError: Bool { migrationFailureMessage != nil }
    var canRunMonitoring: Bool {
        isActivelyMonitoring && isManagementEnabled && !isStandaloneConflictActive && !hasMigrationError
    }
    var canModifyProtections: Bool {
        !hasMigrationError && !isStandaloneConflictActive
    }
    var canExecuteCleanup: Bool {
        canRunMonitoring && isCleanupEnabled
    }
    var hasMemoryPressure: Bool {
        canRunMonitoring && (metrics?.memoryPressure == .warning || metrics?.memoryPressure == .critical)
    }

    init(
        auditStore: CleanupAuditStore = CleanupAuditStore(),
        protectionStore: CleanupProtectionStore = CleanupProtectionStore(),
        loadStoresOnInit: Bool = true,
        startsImmediately: Bool = false
    ) {
        self.auditStore = auditStore
        self.protectionStore = protectionStore
        if loadStoresOnInit {
            cleanupHistory = auditStore.load()
            protectedCleanupIDs = protectionStore.load()
        }
        if startsImmediately {
            isManagementEnabled = true
            isActivelyMonitoring = true
            if isAutoRefreshEnabled {
                startAutoRefresh()
            }
            refresh()
        }
    }

    func reloadStoresAfterMigrationSuccess() {
        guard !hasMigrationError else { return }
        cleanupHistory = auditStore.load()
        protectedCleanupIDs = protectionStore.load()
    }

    func applyRuntimeConfiguration(
        isManagementEnabled: Bool,
        isAutoRefreshEnabled: Bool,
        isCleanupEnabled: Bool,
        isStandaloneConflictActive: Bool,
        migrationFailureMessage: String?,
        shouldActivelyMonitor: Bool
    ) {
        let wasMonitoring = canRunMonitoring

        self.isManagementEnabled = isManagementEnabled
        self.isAutoRefreshEnabled = isAutoRefreshEnabled
        self.isCleanupEnabled = isCleanupEnabled
        self.isStandaloneConflictActive = isStandaloneConflictActive
        self.migrationFailureMessage = migrationFailureMessage

        let allowMonitoring = shouldActivelyMonitor
            && isManagementEnabled
            && !isStandaloneConflictActive
            && (migrationFailureMessage == nil)
        self.isActivelyMonitoring = allowMonitoring

        let allowCleanup = allowMonitoring && isCleanupEnabled
        if !allowCleanup {
            isShowingCleanupConfirmation = false
            activeBatchGate?.stopAfterCurrentSafeUnit()
            if !isCleaning {
                selectedCleanupIDs.removeAll()
                selectedProcessCleanupIDs.removeAll()
            }
        }

        if !allowMonitoring {
            timer?.invalidate()
            timer = nil
            isRefreshQueued = false
            isRefreshing = false
            monitoringGeneration &+= 1
            storageScanGeneration += 1
            if cleanupActivity == .scanning {
                scanGeneration &+= 1
                cleanupActivity = .idle
            }
            return
        }

        if isAutoRefreshEnabled {
            if timer == nil {
                startAutoRefresh()
            }
        } else {
            timer?.invalidate()
            timer = nil
        }

        if !wasMonitoring {
            refresh()
        }
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = nil
        guard canRunMonitoring, isAutoRefreshEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if evaluateConflictBeforeWork?() == true { return }
        guard canRunMonitoring else {
            isRefreshQueued = false
            return
        }
        guard !isRefreshing else {
            isRefreshQueued = true
            return
        }
        isRefreshing = true
        let cachedStorage = storage
        let storageGeneration = storageScanGeneration
        let capturedMonitoringGeneration = monitoringGeneration
        let shouldScanStorage = lastStorageScan.map {
            Date().timeIntervalSince($0) >= Self.storageRefreshInterval
        } ?? true

        Task.detached(priority: .utility) {
            let metrics = MetricsCollector.collect()
            let processes = ProcessCollector.collect()
            let storage = shouldScanStorage ? StorageCollector.collect() : cachedStorage
            let diagnosis = DiagnosticEngine.evaluate(metrics: metrics, processes: processes, storage: storage)

            await MainActor.run { [weak self] in
                guard let self,
                      self.canRunMonitoring,
                      self.monitoringGeneration == capturedMonitoringGeneration
                else { return }
                self.metrics = metrics
                self.storage = storage
                self.diagnosis = diagnosis
                // 스캔 시작 후 정리가 무효화한 경우 lastStorageScan을 되살리지 않는다.
                if shouldScanStorage, storageGeneration == self.storageScanGeneration {
                    self.lastStorageScan = Date()
                }
                self.lastRefreshed = Date()
                self.isRefreshing = false
                if self.isRefreshQueued {
                    self.isRefreshQueued = false
                    if self.canRunMonitoring {
                        self.refresh()
                    }
                }
            }
        }
    }

    /// 정리 이후 저장 공간 캐시를 무효화한다. 진행 중인 스캔이 이 결정을 덮어쓰지 못하게 세대를 올린다.
    private func invalidateStorageScan() {
        lastStorageScan = nil
        storageScanGeneration += 1
    }

    func scanCleanupCandidates() {
        if evaluateConflictBeforeWork?() == true { return }
        guard canRunMonitoring, !isClearingDerivedData, cleanupActivity == .idle else { return }
        cleanupActivity = .scanning
        cleanupResults = []
        processCleanupResults = []
        automaticCleanupSummary = nil
        let capturedMonitoringGeneration = monitoringGeneration
        let capturedScanGeneration = scanGeneration

        Task.detached(priority: .utility) {
            let input = CleanupEvidenceCollector.collect()
            let candidates = CleanupPolicy.propose(input)
            let processCandidates = ProcessCleanupPolicy.propose(Self.processCleanupInput())
            await MainActor.run { [weak self] in
                guard let self,
                      self.canRunMonitoring,
                      self.monitoringGeneration == capturedMonitoringGeneration,
                      self.scanGeneration == capturedScanGeneration
                else { return }
                self.cleanupCandidates = candidates.filter { !self.protectedCleanupIDs.contains($0.id) }
                // 새 스캔 결과는 디스크와 프로세스 모두 안전하게 기본 미선택으로 시작한다.
                self.selectedCleanupIDs.removeAll()
                self.processCleanupCandidates = processCandidates.filter {
                    !self.protectedCleanupIDs.contains($0.protectionIdentifier)
                }
                self.selectedProcessCleanupIDs.removeAll()
                self.cleanupActivity = .idle
            }
        }
    }

    /// 신선한 근거를 수집해 저위험이면서 휴지통 복구 가능한 파일만 무확인으로 정리한다.
    /// 그 후 시뮬레이터 정리 후보(데이터 초기화·사용 불가·임시 복제)가 남아 있으면
    /// 목록에 기본 미선택으로 남긴다. 확인 없이는 어떤 시뮬레이터도 지우지 않으며,
    /// 시뮬레이터·프로세스와 그 밖의 중간 위험 후보는 자동 선택하지 않는다.
    func runAutomaticCleanup() {
        if evaluateConflictBeforeWork?() == true { return }
        guard canExecuteCleanup, !isClearingDerivedData, cleanupActivity == .idle else { return }
        cleanupActivity = .autoCleaning
        cleanupResults = []
        processCleanupResults = []
        automaticCleanupSummary = nil
        selectedCleanupIDs.removeAll()
        selectedProcessCleanupIDs.removeAll()
        isShowingCleanupConfirmation = false
        let protectedIdentifiers = protectedCleanupIDs
        let gate = CleanupBatchGate()
        activeBatchGate = gate

        Task.detached(priority: .utility) {
            let input = CleanupEvidenceCollector.collect()
            let proposed = CleanupPolicy.propose(input)
            let plan = AutomaticCleanupPolicy.makePlan(
                candidates: proposed,
                protectedIdentifiers: protectedIdentifiers
            )
            let proposedProcesses = ProcessCleanupPolicy.propose(Self.processCleanupInput())
                .filter { !protectedIdentifiers.contains($0.protectionIdentifier) }

            var results: [CleanupExecutionResult] = []
            var stoppedBeforeRemainingUnits = false
            let shouldMeasureImpact = !plan.targets.isEmpty && gate.canStartNextUnit
            let beforeImpact = shouldMeasureImpact ? SystemImpactCollector.collect() : nil

            for target in plan.targets {
                guard gate.canStartNextUnit else {
                    stoppedBeforeRemainingUnits = true
                    break
                }
                results.append(CleanupExecutor.execute(target))
            }

            let afterImpact = (!results.isEmpty && beforeImpact != nil) ? SystemImpactCollector.collect() : nil
            let impact = beforeImpact.flatMap { before in
                afterImpact.map { after in
                    CleanupImpactSummary(
                        beforeMetrics: before.metrics,
                        afterMetrics: after.metrics,
                        beforeDiskAvailableBytes: before.diskAvailableBytes,
                        afterDiskAvailableBytes: after.diskAvailableBytes,
                        completedAt: Date()
                    )
                }
            }
            let auditEntries = Self.makeAuditEntries(results: results, processResults: [])

            let shouldRefreshCandidates = gate.canStartNextUnit
            let refreshedCandidates: [CleanupCandidate]?
            let refreshedProcessCandidates: [ProcessCleanupCandidate]?
            if shouldRefreshCandidates {
                let refreshedInput = CleanupEvidenceCollector.collect()
                refreshedCandidates = CleanupPolicy.propose(refreshedInput)
                    .filter { !protectedIdentifiers.contains($0.id) }
                refreshedProcessCandidates = ProcessCleanupPolicy.propose(Self.processCleanupInput())
                    .filter { !protectedIdentifiers.contains($0.protectionIdentifier) }
            } else {
                refreshedCandidates = nil
                refreshedProcessCandidates = nil
            }

            let simulatorFollowUps = (refreshedCandidates ?? plan.manualOnly).filter { $0.kind.targetsSimulator }
            let cleanedCount = results.filter { $0.status == .cleaned }.count
            let failedCount = results.count - cleanedCount
            let manualOnlyCount = plan.manualOnly.filter { !$0.kind.targetsSimulator }.count
                + proposedProcesses.filter(\.isActionable).count
            let summary = Self.automaticSummary(
                cleanedCount: cleanedCount,
                failedCount: failedCount,
                manualOnlyCount: manualOnlyCount,
                simulatorConfirmationCount: simulatorFollowUps.count,
                stoppedBeforeRemainingUnits: stoppedBeforeRemainingUnits
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.activeBatchGate === gate {
                    self.activeBatchGate = nil
                }
                self.cleanupResults = results
                self.processCleanupResults = []
                if let impact {
                    self.cleanupImpact = impact
                }
                if !auditEntries.isEmpty {
                    self.cleanupHistory = self.auditStore.append(auditEntries, to: self.cleanupHistory)
                }
                if self.canRunMonitoring, let refreshedCandidates, let refreshedProcessCandidates {
                    self.cleanupCandidates = refreshedCandidates
                    self.processCleanupCandidates = refreshedProcessCandidates
                }
                self.selectedCleanupIDs.removeAll()
                self.selectedProcessCleanupIDs.removeAll()
                self.automaticCleanupSummary = summary
                self.cleanupActivity = .idle
                self.isShowingCleanupConfirmation = false
                if cleanedCount > 0 { self.invalidateStorageScan() }
                if self.canRunMonitoring {
                    self.refresh()
                }
            }
        }
    }

    /// DerivedData 안의 항목만 휴지통으로 이동한다. 폴더가 없거나 비어 있어도 완료로 처리한다.
    func clearDerivedData() {
        if evaluateConflictBeforeWork?() == true { return }
        guard canExecuteCleanup, !isClearingDerivedData, cleanupActivity == .idle else { return }
        isClearingDerivedData = true
        derivedDataClearResult = nil
        Task.detached(priority: .utility) {
            let result = DerivedDataClearer.clear()
            let entry = CleanupAuditEntry(
                id: UUID(), timestamp: Date(), category: "Xcode Derived Data 지우기",
                target: "DerivedData", status: result.status, message: result.message
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.derivedDataClearResult = result
                self.cleanupHistory = self.auditStore.append([entry], to: self.cleanupHistory)
                self.isClearingDerivedData = false
                if result.clearedCount > 0 { self.invalidateStorageScan() }
                if self.canRunMonitoring {
                    self.refresh()
                }
            }
        }
    }

    nonisolated static func processCleanupInput() -> ProcessCleanupPolicyInput {
        ProcessCleanupPolicyInput(
            processes: ProcessCollector.collectOptional(),
            currentUserName: NSUserName(),
            ownPid: ProcessInfo.processInfo.processIdentifier
        )
    }

    func toggleCleanupCandidate(_ candidate: CleanupCandidate) {
        guard canExecuteCleanup, !isClearingDerivedData, cleanupActivity == .idle else { return }
        if selectedCleanupIDs.contains(candidate.id) {
            selectedCleanupIDs.remove(candidate.id)
        } else {
            selectedCleanupIDs.insert(candidate.id)
        }
    }

    func toggleProcessCleanupCandidate(_ candidate: ProcessCleanupCandidate) {
        guard canExecuteCleanup, !isClearingDerivedData, cleanupActivity == .idle, candidate.isActionable else { return }
        if selectedProcessCleanupIDs.contains(candidate.id) {
            selectedProcessCleanupIDs.remove(candidate.id)
        } else {
            selectedProcessCleanupIDs.insert(candidate.id)
        }
    }

    func protectCleanupCandidate(id: String) {
        guard canModifyProtections, !isClearingDerivedData, cleanupActivity == .idle else { return }
        protectedCleanupIDs.insert(id)
        protectionStore.save(protectedCleanupIDs)
        selectedCleanupIDs.remove(id)
        cleanupCandidates.removeAll { $0.id == id }
        let protectedProcessIDs = processCleanupCandidates
            .filter { $0.protectionIdentifier == id }
            .map(\.id)
        selectedProcessCleanupIDs.subtract(protectedProcessIDs)
        processCleanupCandidates.removeAll { $0.protectionIdentifier == id }
    }

    func unprotectCleanupCandidate(id: String) {
        guard canModifyProtections, !isClearingDerivedData, cleanupActivity == .idle else { return }
        guard protectedCleanupIDs.remove(id) != nil else { return }
        protectionStore.save(protectedCleanupIDs)
        if canRunMonitoring {
            scanCleanupCandidates()
        }
    }

    func clearProtections() {
        guard canModifyProtections, !isClearingDerivedData, cleanupActivity == .idle else { return }
        protectedCleanupIDs.removeAll()
        protectionStore.save(protectedCleanupIDs)
        if canRunMonitoring {
            scanCleanupCandidates()
        }
    }

    func requestCleanupConfirmation() {
        if evaluateConflictBeforeWork?() == true {
            isShowingCleanupConfirmation = false
            return
        }
        guard canExecuteCleanup,
              !isClearingDerivedData,
              cleanupActivity == .idle,
              !selectedCandidates.isEmpty || !selectedProcessCandidates.isEmpty
        else {
            isShowingCleanupConfirmation = false
            return
        }
        isShowingCleanupConfirmation = true
    }

    func executeSelectedCleanup() {
        if evaluateConflictBeforeWork?() == true {
            isShowingCleanupConfirmation = false
            return
        }
        let targets = selectedCandidates
        let processTargets = selectedProcessCandidates
        guard canExecuteCleanup,
              !isClearingDerivedData,
              !targets.isEmpty || !processTargets.isEmpty,
              cleanupActivity == .idle
        else {
            isShowingCleanupConfirmation = false
            return
        }
        isShowingCleanupConfirmation = false
        cleanupActivity = .cleaning
        automaticCleanupSummary = nil
        let gate = CleanupBatchGate()
        activeBatchGate = gate

        Task.detached(priority: .utility) {
            let beforeImpact = gate.canStartNextUnit ? SystemImpactCollector.collect() : nil
            var results: [CleanupExecutionResult] = []
            for target in targets {
                guard gate.canStartNextUnit else { break }
                results.append(CleanupExecutor.execute(target))
            }
            var processResults: [ProcessCleanupExecutionResult] = []
            for processTarget in processTargets {
                guard gate.canStartNextUnit else { break }
                processResults.append(ProcessCleanupExecutor.execute(processTarget))
            }

            let didExecuteAny = !results.isEmpty || !processResults.isEmpty
            let afterImpact = (didExecuteAny && beforeImpact != nil) ? SystemImpactCollector.collect() : nil
            let impact = beforeImpact.flatMap { before in
                afterImpact.map { after in
                    CleanupImpactSummary(
                        beforeMetrics: before.metrics,
                        afterMetrics: after.metrics,
                        beforeDiskAvailableBytes: before.diskAvailableBytes,
                        afterDiskAvailableBytes: after.diskAvailableBytes,
                        completedAt: Date()
                    )
                }
            }
            let auditEntries = Self.makeAuditEntries(results: results, processResults: processResults)

            let shouldRefreshCandidates = gate.canStartNextUnit
            let refreshedCandidates: [CleanupCandidate]?
            let refreshedProcessCandidates: [ProcessCleanupCandidate]?
            if shouldRefreshCandidates {
                let refreshedInput = CleanupEvidenceCollector.collect()
                refreshedCandidates = CleanupPolicy.propose(refreshedInput)
                refreshedProcessCandidates = ProcessCleanupPolicy.propose(Self.processCleanupInput())
            } else {
                refreshedCandidates = nil
                refreshedProcessCandidates = nil
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.activeBatchGate === gate {
                    self.activeBatchGate = nil
                }
                self.cleanupResults = results
                self.processCleanupResults = processResults
                if let impact {
                    self.cleanupImpact = impact
                }
                if !auditEntries.isEmpty {
                    self.cleanupHistory = self.auditStore.append(auditEntries, to: self.cleanupHistory)
                }
                if self.canRunMonitoring, let refreshedCandidates, let refreshedProcessCandidates {
                    self.cleanupCandidates = refreshedCandidates.filter { !self.protectedCleanupIDs.contains($0.id) }
                    self.processCleanupCandidates = refreshedProcessCandidates.filter {
                        !self.protectedCleanupIDs.contains($0.protectionIdentifier)
                    }
                }
                self.selectedCleanupIDs.removeAll()
                self.selectedProcessCleanupIDs.removeAll()
                self.cleanupActivity = .idle
                if didExecuteAny {
                    self.invalidateStorageScan()
                }
                if self.canRunMonitoring {
                    self.refresh()
                }
            }
        }
    }

    nonisolated private static func makeAuditEntries(
        results: [CleanupExecutionResult],
        processResults: [ProcessCleanupExecutionResult]
    ) -> [CleanupAuditEntry] {
        let now = Date()
        return results.map {
            CleanupAuditEntry(
                id: UUID(), timestamp: now, category: $0.candidate.kind.koreanLabel,
                target: $0.candidate.targetIdentifier, status: $0.status, message: $0.message
            )
        } + processResults.map {
            CleanupAuditEntry(
                id: UUID(), timestamp: now, category: $0.candidate.kind.koreanLabel,
                target: "pid \($0.candidate.pid)", status: $0.status, message: $0.message
            )
        }
    }

    nonisolated private static func automaticSummary(
        cleanedCount: Int,
        failedCount: Int,
        manualOnlyCount: Int,
        simulatorConfirmationCount: Int,
        stoppedBeforeRemainingUnits: Bool = false
    ) -> String {
        var parts: [String] = ["안전한 파일 자동 정리 \(cleanedCount)개 완료"]
        if failedCount > 0 { parts.append("\(failedCount)개 차단 또는 실패") }
        if stoppedBeforeRemainingUnits {
            parts.append("설정 변경 또는 중지로 남은 미시작 항목은 건너뜀")
        }
        if simulatorConfirmationCount > 0 {
            parts.append("시뮬레이터 정리 \(simulatorConfirmationCount)개는 개별 선택과 최종 확인 후에만 실행")
        }
        if manualOnlyCount > 0 {
            parts.append("\(manualOnlyCount)개는 수동 확인 필요")
        }
        if simulatorConfirmationCount == 0 && manualOnlyCount == 0 && !stoppedBeforeRemainingUnits {
            parts.append("비가역 작업과 프로세스 종료는 실행하지 않음")
        }
        return parts.joined(separator: " · ")
    }

    var selectedCandidates: [CleanupCandidate] {
        cleanupCandidates.filter { selectedCleanupIDs.contains($0.id) }
    }

    var selectedProcessCandidates: [ProcessCleanupCandidate] {
        processCleanupCandidates.filter { $0.isActionable && selectedProcessCleanupIDs.contains($0.id) }
    }

    /// 선택된 디스크 후보의 예상 확보 공간. 메모리 예상치와 절대 합산하지 않는다.
    var selectedCleanupBytes: UInt64 {
        selectedCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }

    /// 선택된 프로세스 후보의 상주 메모리 합계. 디스크 예상치와 별도로만 표시한다.
    var selectedProcessMemoryBytes: UInt64 {
        ProcessCleanupPolicy.totalExpectedResidentBytes(of: selectedProcessCandidates)
    }

    var effectiveStatusLabel: String {
        if hasMigrationError { return "이전 데이터 확인 실패" }
        if isStandaloneConflictActive { return "일시 중지됨 (독립 BTN 실행 중)" }
        if !isManagementEnabled { return "꺼짐" }
        return diagnosis.status.koreanLabel
    }

    var effectiveKeyCause: String {
        if let migrationFailureMessage {
            return migrationFailureMessage
        }
        if isStandaloneConflictActive {
            return "독립 BTN 앱이 실행 중이어서 중복 관측·정리 경합을 막기 위해 작업을 중지했습니다."
        }
        if !isManagementEnabled {
            return "HTT 설정에서 'Mac 관리 사용'을 켜면 시스템 지표와 개발 저장 공간을 확인합니다."
        }
        return diagnosis.keyCause
    }

    var modeBadgeTitle: String {
        if hasMigrationError { return "오류로 중지됨" }
        if isStandaloneConflictActive { return "독립 BTN 실행 중" }
        if !isManagementEnabled { return "꺼짐" }
        if !isCleanupEnabled { return "관찰 전용" }
        return "권장 모드"
    }

    var modeSummaryNote: String {
        if hasMigrationError {
            return "이전 보호 목록·이력 확인에 실패해 안전을 위해 정리를 차단했습니다"
        }
        if isStandaloneConflictActive {
            return "독립 BTN 앱이 종료되면 선택한 설정으로 자동 복구됩니다"
        }
        if !isManagementEnabled {
            return "Mac 관리가 꺼져 있어 수집과 타이머가 실행되지 않습니다"
        }
        if !isCleanupEnabled {
            return "관찰 전용 — 정리 기능 사용이 꺼져 있어 진단만 수행합니다"
        }
        return "권장 모드 — 정리는 항상 확인 후 실행합니다"
    }

    var statusBannerMessage: String? {
        if let migrationFailureMessage {
            return migrationFailureMessage
        }
        if isStandaloneConflictActive {
            return "독립 BTN 앱이 실행 중이어서 중복 관측·정리 경합을 방지하기 위해 HTT Mac 관리의 활성 작업을 일시 중지했습니다. 독립 BTN을 강제 종료하거나 원본 설정을 바꾸지 않으며, 독립 BTN이 종료되면 현재 선택한 HTT 설정대로 자동 복구됩니다."
        }
        if !isManagementEnabled {
            return "현재 'Mac 관리 사용'이 꺼져 있어 지표 수집, 30초 자동 새로고침, 정리 실행이 모두 중지되어 있습니다. HTT 설정에서 'Mac 관리 사용'을 켜면 활성화됩니다."
        }
        if !isCleanupEnabled {
            return "현재 '정리 기능 사용'이 꺼져 있어 진단 및 후보 확인만 가능하며 실제 정리는 시작되지 않습니다. 정리가 필요하면 HTT 설정에서 '정리 기능 사용'을 켜세요."
        }
        return nil
    }

    var statusSymbolName: String {
        if hasMigrationError { return "exclamationmark.triangle.fill" }
        if isStandaloneConflictActive { return "pause.circle" }
        if !isManagementEnabled { return "power" }
        if isRefreshing { return "arrow.triangle.2.circlepath" }
        switch diagnosis.status {
        case .scanning: return "magnifyingglass"
        case .healthy: return "checkmark.circle"
        case .caution: return "exclamationmark.triangle"
        case .pressure: return "exclamationmark.octagon"
        }
    }

    var statusColor: Color {
        if hasMigrationError { return .red }
        if isStandaloneConflictActive { return .orange }
        if !isManagementEnabled { return .secondary }
        switch diagnosis.status {
        case .scanning: return .gray
        case .healthy: return .green
        case .caution: return .yellow
        case .pressure: return .red
        }
    }
}

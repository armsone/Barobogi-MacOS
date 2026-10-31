import AppKit
import SwiftUI

/// 상세 창: 지표, 진단 설명, 개발 관련 프로세스 목록.
struct DetailView: View {
    @ObservedObject var model: MonitorViewModel
    @State private var isShowingAllHistory = false
    @State private var isShowingProtectedList = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                statusBanner
                if model.hasMemoryPressure { memoryPressureAction }
                metricsSection
                storageSection
                derivedDataSection
                cleanupSection
                explanationSection
                processSection
            }
            .padding(16)
        }
        .sheet(isPresented: $model.isShowingCleanupConfirmation) {
            CleanupConfirmationView(model: model)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refresh()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canRunMonitoring || model.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = model.statusBannerMessage {
            GroupBox {
                Label {
                    Text(message)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: model.hasMigrationError
                          ? "exclamationmark.triangle.fill"
                          : (model.isStandaloneConflictActive ? "pause.circle.fill" : "info.circle.fill"))
                        .foregroundStyle(model.hasMigrationError ? .red : (model.isStandaloneConflictActive ? .orange : .secondary))
                }
                .padding(4)
            }
        }
    }

    private var memoryPressureAction: some View {
        GroupBox("메모리 압박 낮추기") {
            VStack(alignment: .leading, spacing: 8) {
                Text("실행 중인 시뮬레이터를 기기 데이터를 유지한 채 종료하거나, 안전 조건을 충족한 유휴 개발 프로세스를 골라 메모리를 확보할 수 있습니다.")
                    .font(.callout)
                HStack {
                    Button {
                        model.scanCleanupCandidates()
                    } label: {
                        Label("해결할 항목 찾기", systemImage: "memorychip")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRunMonitoring || model.isCleanupBusy || model.isClearingDerivedData)

                    Button {
                        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    } label: {
                        Label("활동 모니터 열기", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .help("macOS 활동 모니터를 열어 메모리를 많이 쓰는 일반 앱을 직접 확인합니다.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        if let storage = model.storage {
            GroupBox("개발 저장 공간") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Text("디스크 여유")
                        Text(storage.volumeTotalBytes > 0
                             ? DiagnosticEngine.formatBytes(storage.volumeAvailableBytes)
                             : "확인 불가")
                    }
                    GridRow {
                        Text("시뮬레이터")
                        Text("\(storage.simulatorDeviceCount)개 · \(DiagnosticEngine.formatBytes(storage.simulatorBytes))")
                    }
                    if storage.ephemeralSimulatorCount > 0 {
                        GridRow {
                            Text("테스트 복제본 의심")
                            Text("\(storage.ephemeralSimulatorCount)개")
                                .foregroundStyle(.orange)
                        }
                    }
                    GridRow {
                        Text("Xcode DerivedData")
                        Text(DiagnosticEngine.formatBytes(storage.derivedDataBytes))
                    }
                    if storage.xctestDeviceBytes > 0 {
                        GridRow {
                            Text("XCTest 기기 데이터")
                            Text(DiagnosticEngine.formatBytes(storage.xctestDeviceBytes))
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var derivedDataSection: some View {
        GroupBox("Xcode Derived Data 지우기") {
            VStack(alignment: .leading, spacing: 8) {
                Text("~/Library/Developer/Xcode/DerivedData 안의 빌드 산출물을 모두 휴지통으로 이동합니다. 다음 빌드에서 다시 생성됩니다.")
                    .font(.callout)
                HStack {
                    Button {
                        model.clearDerivedData()
                    } label: {
                        Label("클리어", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExecuteCleanup || model.isClearingDerivedData || model.isCleanupBusy)
                    if model.isClearingDerivedData {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let result = model.derivedDataClearResult {
                    CleanupResultLabel(
                        status: result.status,
                        title: "\(result.status.koreanLabel): DerivedData",
                        message: result.message
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.statusSymbolName)
                .font(.title)
                .foregroundStyle(model.statusColor)
            VStack(alignment: .leading) {
                Text("HTT — Mac 관리 · 상태: \(model.effectiveStatusLabel)")
                    .font(.title2.bold())
                Text(model.effectiveKeyCause)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.modeBadgeTitle)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }

    private var cleanupSection: some View {
        GroupBox("안전한 원상복구") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("수동 목록의 후보는 자동 선택되지 않으며, 실행 직전에 다시 확인합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.scanCleanupCandidates()
                    } label: {
                        Label(
                            model.isScanningCleanup ? "찾는 중" : "정리 후보 찾기",
                            systemImage: "magnifyingglass"
                        )
                    }
                    .disabled(!model.canRunMonitoring || model.isCleanupBusy || model.isClearingDerivedData)
                    Button {
                        model.runAutomaticCleanup()
                    } label: {
                        Label("자동 정리", systemImage: "wand.and.stars")
                    }
                    .disabled(!model.canExecuteCleanup || model.isCleanupBusy || model.isClearingDerivedData)
                    .help("저위험이며 휴지통에서 복원 가능한 파일만 자동으로 정리합니다. 시뮬레이터와 프로세스는 자동 선택하거나 실행하지 않습니다.")
                }

                Text("자동 정리는 저위험·휴지통 복구 가능 파일만 즉시 실행합니다. 시뮬레이터 종료·초기화·삭제와 프로세스 종료는 개별 선택과 최종 확인이 필요합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !model.protectedCleanupIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("보호된 대상 \(model.protectedCleanupIDs.count)개는 제안에서 제외됩니다.", systemImage: "shield.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(isShowingProtectedList ? "목록 접기" : "보호 목록 보기") {
                                isShowingProtectedList.toggle()
                            }
                            .font(.caption)
                            Button("보호 목록 초기화") { model.clearProtections() }
                                .font(.caption)
                                .disabled(!model.canModifyProtections || model.isCleanupBusy || model.isClearingDerivedData)
                        }
                        if isShowingProtectedList {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.protectedCleanupIDs.sorted(), id: \.self) { protectedID in
                                    HStack {
                                        Text(protectedID)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button("보호 해제") {
                                            model.unprotectCleanupCandidate(id: protectedID)
                                        }
                                        .font(.caption2)
                                        .disabled(!model.canModifyProtections || model.isCleanupBusy || model.isClearingDerivedData)
                                    }
                                }
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                if model.isScanningCleanup {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if model.cleanupCandidates.isEmpty && model.processCleanupCandidates.isEmpty {
                    Text("버튼을 눌러 오래된 DerivedData, XCTest 데이터, 종료된 테스트 시뮬레이터, 데이터가 큰 시뮬레이터와 방치된 것으로 보이는 개발 프로세스를 확인하세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if !model.cleanupCandidates.isEmpty {
                        Text("시뮬레이터·디스크 정리")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            ForEach(model.cleanupCandidates) { candidate in
                                CleanupCandidateRow(
                                    candidate: candidate,
                                    isSelected: model.selectedCleanupIDs.contains(candidate.id),
                                    isToggleDisabled: !model.canExecuteCleanup || model.isCleanupBusy || model.isClearingDerivedData,
                                    isProtectDisabled: !model.canModifyProtections || model.isCleanupBusy || model.isClearingDerivedData,
                                    toggle: { model.toggleCleanupCandidate(candidate) },
                                    protect: { model.protectCleanupCandidate(id: candidate.id) }
                                )
                            }
                        }
                    }

                    if !model.processCleanupCandidates.isEmpty {
                        Text("메모리 확보 (프로세스 종료 — 되돌릴 수 없음)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            ForEach(model.processCleanupCandidates) { candidate in
                                ProcessCleanupCandidateRow(
                                    candidate: candidate,
                                    isSelected: model.selectedProcessCleanupIDs.contains(candidate.id),
                                    isToggleDisabled: !model.canExecuteCleanup || model.isCleanupBusy || model.isClearingDerivedData,
                                    isProtectDisabled: !model.canModifyProtections || model.isCleanupBusy || model.isClearingDerivedData,
                                    toggle: { model.toggleProcessCleanupCandidate(candidate) },
                                    protect: { model.protectCleanupCandidate(id: candidate.protectionIdentifier) }
                                )
                            }
                        }
                    }

                    HStack {
                        // 디스크와 메모리는 성격이 다른 예상치이므로 절대 하나로 합산하지 않는다.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("디스크: \(model.selectedCandidates.count)개 선택 · 최대 \(DiagnosticEngine.formatBytes(model.selectedCleanupBytes))")
                            Text("메모리: \(model.selectedProcessCandidates.count)개 선택 · 상주 메모리 약 \(DiagnosticEngine.formatBytes(model.selectedProcessMemoryBytes))")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("선택 항목 정리…") {
                            model.requestCleanupConfirmation()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canExecuteCleanup || (model.selectedCandidates.isEmpty && model.selectedProcessCandidates.isEmpty) || model.isCleanupBusy || model.isClearingDerivedData)
                    }
                }

                if model.isCleaning {
                    ProgressView(
                        model.isAutoCleaning
                            ? "자동 정리 대상을 찾고 항목마다 다시 확인하고 있습니다…"
                            : "항목마다 안전 조건을 다시 확인하고 있습니다…"
                    )
                }

                if let summary = model.automaticCleanupSummary {
                    Label(summary, systemImage: "wand.and.stars")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(model.cleanupResults) { result in
                    CleanupResultLabel(
                        status: result.status,
                        title: "\(result.status.koreanLabel): \(result.candidate.targetIdentifier)",
                        message: result.message
                    )
                }

                ForEach(model.processCleanupResults) { result in
                    CleanupResultLabel(
                        status: result.status,
                        title: "\(result.status.koreanLabel): \(result.candidate.kind.koreanLabel) (pid \(result.candidate.pid))",
                        message: result.message
                    )
                }

                if let impact = model.cleanupImpact {
                    CleanupImpactView(impact: impact)
                }

                if !model.cleanupHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("최근 정리 기록 (\(model.cleanupHistory.count)건)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.cleanupHistory.count > 5 {
                                Button(isShowingAllHistory ? "최근 5건만 보기" : "전체 기록 보기 (\(model.cleanupHistory.count)건)") {
                                    isShowingAllHistory.toggle()
                                }
                                .font(.caption)
                            }
                        }
                        let displayedEntries = isShowingAllHistory
                            ? Array(model.cleanupHistory.reversed())
                            : Array(model.cleanupHistory.suffix(5).reversed())
                        ForEach(displayedEntries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: entry.status == .cleaned ? "checkmark.circle" : "exclamationmark.triangle")
                                        .foregroundStyle(entry.status == .cleaned ? .green : .orange)
                                    Text("\(entry.category) · \(entry.target)")
                                        .lineLimit(1)
                                    Spacer()
                                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                }
                                if isShowingAllHistory {
                                    Text(entry.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 18)
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        if let metrics = model.metrics {
            GroupBox("측정값") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Text("CPU 부하 (1분)")
                        Text(String(format: "%.2f / 코어 %d개 (코어당 %.2f)",
                                    metrics.loadAverage1Min,
                                    metrics.cpuCoreCount,
                                    metrics.normalizedLoad))
                    }
                    GridRow {
                        Text("메모리 압박")
                        Text(metrics.memoryPressure.koreanLabel)
                    }
                    GridRow {
                        Text("사용 가능 메모리")
                        Text(metrics.availableMemoryBytes.map { DiagnosticEngine.formatBytes($0) } ?? "확인 불가")
                    }
                    GridRow {
                        Text("스왑 사용")
                        Text("\(DiagnosticEngine.formatBytes(metrics.swapUsedBytes)) / \(DiagnosticEngine.formatBytes(metrics.swapTotalBytes))")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var explanationSection: some View {
        GroupBox("진단") {
            Text(model.diagnosis.explanation)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }

    private var processSection: some View {
        GroupBox("개발 관련 프로세스 (\(model.diagnosis.devProcesses.count)개)") {
            if model.diagnosis.devProcesses.isEmpty {
                Text("감지된 개발 관련 프로세스가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } else {
                List(model.diagnosis.devProcesses) { process in
                    ProcessRow(process: process)
                }
                .listStyle(.inset)
                .frame(minHeight: 160)
            }
        }
    }
}

private struct CleanupCandidateRow: View {
    let candidate: CleanupCandidate
    let isSelected: Bool
    let isToggleDisabled: Bool
    let isProtectDisabled: Bool
    let toggle: () -> Void
    let protect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(candidate.kind.koreanLabel).bold()
                        Text(candidate.targetIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(DiagnosticEngine.formatBytes(candidate.estimatedBytes))
                            .monospacedDigit()
                    }
                    Text(candidate.koreanReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("위험도 \(candidate.risk.koreanLabel)")
                        Text("·")
                        Text(candidate.recoveryMethod.koreanLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(candidate.isRecoverable ? .green : .orange)
                }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isToggleDisabled)
            Button(action: protect) {
                Image(systemName: "shield")
            }
            .buttonStyle(.borderless)
            .disabled(isProtectDisabled)
            .help("이 대상을 보호하고 앞으로 제안하지 않기")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanupResultLabel: View {
    let status: CleanupExecutionStatus
    let title: String
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: status == .cleaned ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .cleaned ? .green : .orange)
        }
    }
}

private struct ProcessCleanupCandidateRow: View {
    let candidate: ProcessCleanupCandidate
    let isSelected: Bool
    let isToggleDisabled: Bool
    let isProtectDisabled: Bool
    let toggle: () -> Void
    let protect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                Image(systemName: candidate.isActionable ? (isSelected ? "checkmark.square.fill" : "square") : "eye")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(candidate.kind.koreanLabel).bold()
                        Text("pid \(candidate.pid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("메모리 \(DiagnosticEngine.formatBytes(candidate.residentBytes))")
                            .monospacedDigit()
                    }
                    Text(candidate.command)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(candidate.koreanReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("위험도 \(candidate.risk.koreanLabel)")
                        Text("·")
                        Text(candidate.isActionable ? "종료 후 복구 불가" : "관찰 전용 · 종료 차단")
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isToggleDisabled || !candidate.isActionable)
            Button(action: protect) {
                Image(systemName: "shield")
            }
            .buttonStyle(.borderless)
            .disabled(isProtectDisabled)
            .help("이 프로세스를 보호하고 앞으로 제안하지 않기")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanupImpactView: View {
    let impact: CleanupImpactSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("실제 전후 변화")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("메모리 압박")
                    Text("\(impact.beforeMetrics.memoryPressure.koreanLabel) → \(impact.afterMetrics.memoryPressure.koreanLabel)")
                }
                GridRow {
                    Text("사용 가능 메모리")
                    Text(byteChange(
                        before: impact.beforeMetrics.availableMemoryBytes,
                        after: impact.afterMetrics.availableMemoryBytes
                    ))
                }
                GridRow {
                    Text("디스크 여유")
                    Text(byteChange(before: impact.beforeDiskAvailableBytes, after: impact.afterDiskAvailableBytes))
                }
                GridRow {
                    Text("스왑 관측값")
                    Text("\(DiagnosticEngine.formatBytes(impact.beforeMetrics.swapUsedBytes)) → \(DiagnosticEngine.formatBytes(impact.afterMetrics.swapUsedBytes))")
                }
            }
            .font(.caption.monospacedDigit())
            Text("스왑은 측정만 하며 앱이 직접 정리하지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func byteChange(before: UInt64?, after: UInt64?) -> String {
        guard let before, let after else { return "확인 불가" }
        let arrow = "\(DiagnosticEngine.formatBytes(before)) → \(DiagnosticEngine.formatBytes(after))"
        if after >= before {
            return arrow + " (+\(DiagnosticEngine.formatBytes(after - before)))"
        }
        return arrow + " (-\(DiagnosticEngine.formatBytes(before - after)))"
    }
}

private struct CleanupConfirmationView: View {
    @ObservedObject var model: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    private var irreversibleCount: Int {
        model.selectedCandidates.filter { !$0.isRecoverable }.count
    }

    private var totalSelectionCount: Int {
        model.selectedCandidates.count + model.selectedProcessCandidates.count
    }

    private var hasSimulatorShutdown: Bool {
        model.selectedCandidates.contains { $0.kind == .bootedSimulatorShutdown }
    }

    /// 선택된 시뮬레이터 정리 후보(데이터 초기화·삭제)의 예상 확보 크기.
    private var simulatorSelectionBytes: UInt64 {
        model.selectedCandidates
            .filter { $0.kind.targetsSimulator }
            .reduce(0) { $0 + $1.estimatedBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("정리 전 마지막 확인", systemImage: "checkmark.shield")
                .font(.title2.bold())
            Text("선택한 \(totalSelectionCount)개 항목을 실행 직전에 다시 검사합니다. 조건이 달라진 항목은 건드리지 않습니다.")
            if irreversibleCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Label("시뮬레이터 \(irreversibleCount)개는 실행 후 내부 데이터를 복구할 수 없습니다.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if simulatorSelectionBytes > 0 {
                        Text("시뮬레이터에서 예상 확보 \(DiagnosticEngine.formatBytes(simulatorSelectionBytes)) · 데이터 초기화는 기기 자체를 남기고 앱·콘텐츠 데이터만 지웁니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !model.selectedProcessCandidates.isEmpty {
                Label(
                    "프로세스 \(model.selectedProcessCandidates.count)개 종료는 되돌릴 수 없으며, "
                        + "의도적으로 띄워 둔 서버나 진행 중인 작업을 중단시킬 수 있습니다.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
            List {
                ForEach(model.selectedCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(candidate.kind.koreanLabel) — \(candidate.targetIdentifier)")
                            .bold()
                        Text(candidate.recoveryMethod.koreanLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.selectedProcessCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(candidate.kind.koreanLabel) — pid \(candidate.pid) 종료(SIGTERM)")
                            .bold()
                        Text("복구 불가 · 위험도 \(candidate.risk.koreanLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 180)
            HStack {
                // 수치화할 수 있는 자원만 표시하고, 시뮬레이터 종료 효과는 과장하지 않는다.
                VStack(alignment: .leading, spacing: 2) {
                    if model.selectedCleanupBytes > 0 {
                        Text("디스크 예상 최대 확보 \(DiagnosticEngine.formatBytes(model.selectedCleanupBytes))")
                    }
                    if model.selectedProcessMemoryBytes > 0 {
                        Text("메모리 예상 회수(상주 메모리 기준) \(DiagnosticEngine.formatBytes(model.selectedProcessMemoryBytes))")
                    }
                    if hasSimulatorShutdown {
                        Text("시뮬레이터 종료의 메모리 회수량은 실행 상태에 따라 달라집니다.")
                    }
                }
                .font(.callout.monospacedDigit())
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // 실수로 Return 키에 반응하지 않도록 defaultAction 단축키를 주지 않는다.
                Button("확인하고 정리") { model.executeSelectedCleanup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExecuteCleanup)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }
}

private struct ProcessRow: View {
    let process: ClassifiedProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(process.kind.koreanLabel)
                    .font(.callout.bold())
                Text("pid \(process.snapshot.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "CPU %.1f%%  ·  메모리 %@",
                            process.snapshot.cpuPercent,
                            DiagnosticEngine.formatBytes(process.snapshot.residentBytes)))
                    .font(.caption.monospacedDigit())
            }
            Text(process.snapshot.command)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let note = process.uncertaintyNote {
                Label(note, systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

import Foundation

/// 측정값으로 시스템 상태를 판정하는 결정적 규칙 엔진.
/// 네트워크·AI 의존성이 없고, 같은 입력에는 항상 같은 결과를 낸다.
public enum DiagnosticEngine {

    // 임계값 (모두 코드에 고정된 결정적 규칙)
    public static let loadPressureThreshold = 1.5    // 코어당 load
    public static let loadCautionThreshold = 1.0
    public static let swapCautionRatio = 0.6
    public static let swapRatioMinimumBytes: UInt64 = 4 * 1024 * 1024 * 1024
    public static let swapCautionAbsoluteBytes: UInt64 = 8 * 1024 * 1024 * 1024  // 8 GB
    public static let heavyProcessCPUPercent = 80.0
    public static let lowDiskAbsoluteBytes: UInt64 = 50 * 1024 * 1024 * 1024
    public static let lowDiskRatio = 0.10
    public static let simulatorCautionBytes: UInt64 = 20 * 1024 * 1024 * 1024
    public static let simulatorPressureBytes: UInt64 = 50 * 1024 * 1024 * 1024
    public static let simulatorCautionCount = 20
    public static let simulatorPressureCount = 50
    public static let derivedDataCautionBytes: UInt64 = 20 * 1024 * 1024 * 1024

    public static func evaluate(
        metrics: MetricsSnapshot?,
        processes: [ProcessSnapshot],
        storage: StorageSnapshot? = nil
    ) -> Diagnosis {
        let devProcesses = ProcessClassifier.classifyAll(processes)
            .sorted { $0.snapshot.cpuPercent > $1.snapshot.cpuPercent }

        guard let metrics else {
            return Diagnosis(
                status: .scanning,
                keyCause: "측정값 수집 중",
                explanation: "아직 시스템 지표를 읽지 못했습니다. 잠시 후 다시 확인하세요.",
                devProcesses: devProcesses,
                storageFindings: storage.map { storageAssessment(for: $0).findings } ?? []
            )
        }

        var status = SystemStatus.healthy
        var causes: [String] = []

        // 규칙 1: 커널 메모리 압박 (측정 사실)
        switch metrics.memoryPressure {
        case .critical:
            status = .pressure
            causes.append("메모리 압박 심각 (커널 보고)")
        case .warning:
            status = max(status, .caution)
            causes.append("메모리 압박 경고 (커널 보고)")
        case .normal, .unknown:
            break
        }

        // 규칙 2: CPU 부하 (1분 load average / 코어 수)
        if metrics.normalizedLoad >= loadPressureThreshold {
            status = max(status, .pressure)
            causes.append(String(format: "CPU 부하 높음 (코어당 %.2f)", metrics.normalizedLoad))
        } else if metrics.normalizedLoad >= loadCautionThreshold {
            status = max(status, .caution)
            causes.append(String(format: "CPU 부하 주의 (코어당 %.2f)", metrics.normalizedLoad))
        }

        // 규칙 3: 스왑 사용량. 스왑은 macOS가 스스로 관리하며, 이 앱은 관찰만 한다.
        if (metrics.swapUsedRatio >= swapCautionRatio && metrics.swapUsedBytes >= swapRatioMinimumBytes)
            || metrics.swapUsedBytes >= swapCautionAbsoluteBytes {
            status = max(status, .caution)
            causes.append("스왑 사용량 높음 (\(formatBytes(metrics.swapUsedBytes)))")
        }


        var storageFindings: [String] = []
        if let storage {
            let assessment = storageAssessment(for: storage)
            status = max(status, assessment.status)
            causes.append(contentsOf: assessment.findings)
            storageFindings = assessment.findings
        }

        let keyCause = causes.first ?? "특이 사항 없음"
        let explanation = buildExplanation(status: status, causes: causes, devProcesses: devProcesses)

        return Diagnosis(
            status: status,
            keyCause: keyCause,
            explanation: explanation,
            devProcesses: devProcesses,
            storageFindings: storageFindings
        )
    }

    private static func storageAssessment(for storage: StorageSnapshot) -> (status: SystemStatus, findings: [String]) {
        var status = SystemStatus.healthy
        var findings: [String] = []

        if storage.volumeTotalBytes > 0,
           storage.volumeAvailableBytes < lowDiskAbsoluteBytes || storage.availableRatio < lowDiskRatio {
            status = .pressure
            findings.append("디스크 여유 부족 (\(formatBytes(storage.volumeAvailableBytes)) 남음)")
        }

        if storage.simulatorBytes >= simulatorPressureBytes || storage.simulatorDeviceCount >= simulatorPressureCount {
            status = max(status, .pressure)
            findings.append("시뮬레이터 저장 공간 과다 (\(storage.simulatorDeviceCount)개, \(formatBytes(storage.simulatorBytes)))")
        } else if storage.simulatorBytes >= simulatorCautionBytes || storage.simulatorDeviceCount >= simulatorCautionCount {
            status = max(status, .caution)
            findings.append("시뮬레이터 저장 공간 큼 (\(storage.simulatorDeviceCount)개, \(formatBytes(storage.simulatorBytes)))")
        }

        if storage.ephemeralSimulatorCount > 0 {
            status = max(status, storage.ephemeralSimulatorCount >= 10 ? .pressure : .caution)
            findings.append("테스트용 임시 시뮬레이터 의심 \(storage.ephemeralSimulatorCount)개")
        }

        if storage.derivedDataBytes >= derivedDataCautionBytes {
            status = max(status, .caution)
            findings.append("Xcode DerivedData 큼 (\(formatBytes(storage.derivedDataBytes)))")
        }

        if storage.xctestDeviceBytes >= simulatorCautionBytes {
            status = max(status, .caution)
            findings.append("XCTest 기기 데이터 큼 (\(formatBytes(storage.xctestDeviceBytes)))")
        }
        return (status, findings)
    }

    private static func buildExplanation(
        status: SystemStatus,
        causes: [String],
        devProcesses: [ClassifiedProcess]
    ) -> String {
        var lines: [String] = []

        switch status {
        case .healthy:
            lines.append("시스템 지표가 정상 범위입니다.")
        case .caution, .pressure:
            lines.append("측정된 사실: " + causes.joined(separator: ", ") + ".")
        case .scanning:
            lines.append("측정값 수집 중입니다.")
        }

        // 추론 부분은 명시적으로 표시한다.
        let heavy = devProcesses.filter { $0.snapshot.cpuPercent >= heavyProcessCPUPercent }
        if let top = heavy.first {
            lines.append(
                "추정: \(top.kind.koreanLabel) 프로세스(pid \(top.snapshot.pid))가 "
                + String(format: "CPU %.0f%%를 사용 중이라 부하의 원인일 수 있습니다.", top.snapshot.cpuPercent)
            )
        } else if !devProcesses.isEmpty, status != .healthy {
            lines.append("개발 관련 프로세스 \(devProcesses.count)개가 실행 중입니다. 원인 여부는 확실하지 않습니다.")
        }

        let reparented = devProcesses.filter(\.isReparentedToLaunchd)
        if !reparented.isEmpty {
            lines.append(
                "참고: \(reparented.count)개 프로세스가 launchd에 재부착되어 있습니다. "
                + "데몬은 원래 이렇게 동작할 수 있으므로 고아 프로세스라고 단정할 수 없습니다."
            )
        }

        lines.append(
            "진단만으로는 아무것도 종료하지 않습니다. 엄격한 조건의 후보를 사용자가 선택하고 "
            + "실행 직전 다시 확인한 경우에만 정상 종료(SIGTERM)를 요청합니다. 스왑 자체는 조작하지 않습니다."
        )
        return lines.joined(separator: "\n")
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

/// 상태 심각도 비교용 (scanning < healthy < caution < pressure).
extension SystemStatus: Comparable {
    private var severity: Int {
        switch self {
        case .scanning: return 0
        case .healthy: return 1
        case .caution: return 2
        case .pressure: return 3
        }
    }

    public static func < (lhs: SystemStatus, rhs: SystemStatus) -> Bool {
        lhs.severity < rhs.severity
    }
}

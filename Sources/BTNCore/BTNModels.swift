import Foundation

/// 시스템 전체 상태. 규칙 기반으로만 결정되며 외부 의존성이 없다.
public enum SystemStatus: String, Sendable, Equatable {
    case scanning   // 아직 측정값 없음
    case healthy    // 정상
    case caution    // 주의
    case pressure   // 압박

    public var koreanLabel: String {
        switch self {
        case .scanning: return "확인 중"
        case .healthy: return "정상"
        case .caution: return "주의"
        case .pressure: return "압박"
        }
    }
}

/// 커널이 보고하는 메모리 압박 수준.
public enum MemoryPressureLevel: Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown

    public var koreanLabel: String {
        switch self {
        case .normal: return "정상"
        case .warning: return "경고"
        case .critical: return "심각"
        case .unknown: return "확인 불가"
        }
    }
}

/// 한 시점에 측정된 시스템 지표. 전부 로컬 API에서 읽은 관측값이다.
public struct MetricsSnapshot: Sendable, Equatable {
    public var loadAverage1Min: Double
    public var cpuCoreCount: Int
    public var memoryPressure: MemoryPressureLevel
    public var totalMemoryBytes: UInt64
    public var availableMemoryBytes: UInt64?
    public var swapTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var timestamp: Date

    public init(
        loadAverage1Min: Double,
        cpuCoreCount: Int,
        memoryPressure: MemoryPressureLevel,
        totalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64?,
        swapTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        timestamp: Date = Date()
    ) {
        self.loadAverage1Min = loadAverage1Min
        self.cpuCoreCount = max(1, cpuCoreCount)
        self.memoryPressure = memoryPressure
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.timestamp = timestamp
    }

    /// 1분 load average를 코어 수로 나눈 값. 1.0이면 코어가 꽉 찬 상태.
    public var normalizedLoad: Double {
        loadAverage1Min / Double(cpuCoreCount)
    }

    /// 스왑 사용 비율(0...1). 스왑 파일이 없으면 0.
    public var swapUsedRatio: Double {
        guard swapTotalBytes > 0 else { return 0 }
        return Double(swapUsedBytes) / Double(swapTotalBytes)
    }
}

/// `ps` 출력 한 줄에서 파싱한 프로세스 관측값.
public struct ProcessSnapshot: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var user: String
    public var cpuPercent: Double
    public var memPercent: Double
    public var residentBytes: UInt64
    public var state: String
    public var elapsedSeconds: Int?
    /// `ps lstart`가 제공한 프로세스 시작 시각 문자열. PID 재사용 방지용 불변 식별값이다.
    public var startTimeIdentifier: String?
    public var command: String

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        ppid: Int32,
        user: String,
        cpuPercent: Double,
        memPercent: Double,
        residentBytes: UInt64,
        state: String,
        elapsedSeconds: Int?,
        startTimeIdentifier: String? = nil,
        command: String
    ) {
        self.pid = pid
        self.ppid = ppid
        self.user = user
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.residentBytes = residentBytes
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.startTimeIdentifier = startTimeIdentifier
        self.command = command
    }
}

/// 개발 관련 프로세스 분류.
public enum DevProcessKind: String, Sendable, CaseIterable {
    case gradle
    case kotlin
    case java
    case node
    case xcode
    case test
    case simulator
    case emulator
    case adb
    case browserAutomation
    case localServer

    public var koreanLabel: String {
        switch self {
        case .gradle: return "Gradle"
        case .kotlin: return "Kotlin 데몬"
        case .java: return "Java"
        case .node: return "Node.js"
        case .xcode: return "Xcode 빌드"
        case .test: return "테스트 러너"
        case .simulator: return "iOS 시뮬레이터"
        case .emulator: return "Android 에뮬레이터"
        case .adb: return "ADB"
        case .browserAutomation: return "브라우저 자동화"
        case .localServer: return "로컬 서버"
        }
    }
}

/// 분류가 끝난 개발 프로세스. 고아 여부는 근거가 없으면 단정하지 않는다.
public struct ClassifiedProcess: Sendable, Equatable, Identifiable {
    public var snapshot: ProcessSnapshot
    public var kind: DevProcessKind
    /// launchd(pid 1)에 재부착된 프로세스. 원 세션이 끝났을 "가능성"만 뜻한다.
    public var isReparentedToLaunchd: Bool

    public var id: Int32 { snapshot.pid }

    public init(snapshot: ProcessSnapshot, kind: DevProcessKind, isReparentedToLaunchd: Bool) {
        self.snapshot = snapshot
        self.kind = kind
        self.isReparentedToLaunchd = isReparentedToLaunchd
    }

    /// 불확실성을 명시한 상태 설명.
    public var uncertaintyNote: String? {
        guard isReparentedToLaunchd else { return nil }
        return "launchd에 재부착됨 — 원래 세션 종료 여부는 확인 불가"
    }
}

/// 개발 도구가 차지하는 디스크 공간의 읽기 전용 스냅샷.
public struct StorageSnapshot: Sendable, Equatable {
    public var volumeTotalBytes: UInt64
    public var volumeAvailableBytes: UInt64
    public var simulatorDeviceCount: Int
    public var ephemeralSimulatorCount: Int
    public var simulatorBytes: UInt64
    public var derivedDataBytes: UInt64
    public var xctestDeviceBytes: UInt64
    public var timestamp: Date

    public init(
        volumeTotalBytes: UInt64,
        volumeAvailableBytes: UInt64,
        simulatorDeviceCount: Int,
        ephemeralSimulatorCount: Int,
        simulatorBytes: UInt64,
        derivedDataBytes: UInt64,
        xctestDeviceBytes: UInt64,
        timestamp: Date = Date()
    ) {
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeAvailableBytes = volumeAvailableBytes
        self.simulatorDeviceCount = simulatorDeviceCount
        self.ephemeralSimulatorCount = ephemeralSimulatorCount
        self.simulatorBytes = simulatorBytes
        self.derivedDataBytes = derivedDataBytes
        self.xctestDeviceBytes = xctestDeviceBytes
        self.timestamp = timestamp
    }

    public var availableRatio: Double {
        guard volumeTotalBytes > 0 else { return 0 }
        return Double(volumeAvailableBytes) / Double(volumeTotalBytes)
    }
}

/// 진단 결과. 측정 사실과 추론을 분리해 담는다.
public struct Diagnosis: Sendable, Equatable {
    public var status: SystemStatus
    /// 핵심 원인 한 줄 (측정 기반).
    public var keyCause: String
    /// 사람이 읽는 설명. 추론이 섞이면 문장 안에서 명시한다.
    public var explanation: String
    public var devProcesses: [ClassifiedProcess]
    public var storageFindings: [String]

    public init(
        status: SystemStatus,
        keyCause: String,
        explanation: String,
        devProcesses: [ClassifiedProcess],
        storageFindings: [String] = []
    ) {
        self.status = status
        self.keyCause = keyCause
        self.explanation = explanation
        self.devProcesses = devProcesses
        self.storageFindings = storageFindings
    }
}

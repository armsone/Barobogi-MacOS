import Foundation

/// simctl이 보고하는 시뮬레이터 기기 상태.
/// 정확히 아는 문자열만 케이스로 매핑하고, 나머지는 원문을 보존한 unknown으로 둔다(안전한 실패).
public enum SimulatorDeviceState: Sendable, Equatable, Hashable {
    case shutdown
    case booted
    case creating
    case shuttingDown
    case unknown(String)

    /// simctl JSON의 state 문자열을 해석한다. 정확히 일치하지 않으면 unknown.
    public init(rawState: String) {
        switch rawState {
        case "Shutdown": self = .shutdown
        case "Booted": self = .booted
        case "Creating": self = .creating
        case "Shutting Down": self = .shuttingDown
        default: self = .unknown(rawState)
        }
    }

    public var koreanLabel: String {
        switch self {
        case .shutdown: return "종료됨"
        case .booted: return "실행 중"
        case .creating: return "생성 중"
        case .shuttingDown: return "종료 중"
        case .unknown(let raw): return raw.isEmpty ? "알 수 없음" : "알 수 없음(\(raw))"
        }
    }
}

/// `simctl list devices -j`에서 파싱한 시뮬레이터 기기 관측값.
/// 임시(clone) 여부는 simctl로 알 수 없으므로 여기에 포함하지 않는다 — SimulatorDevicePlistEvidence 참조.
public struct SimulatorDevice: Sendable, Equatable, Identifiable {
    public var udid: UUID
    public var name: String
    /// 소속 런타임 식별자 (예: com.apple.CoreSimulator.SimRuntime.iOS-17-0).
    public var runtimeIdentifier: String
    public var state: SimulatorDeviceState
    /// 사용 가능 여부. nil은 "확인 불가"이며 판단 시 불리하게(fail closed) 취급한다.
    public var isAvailable: Bool?
    /// simctl이 보고한 데이터 디렉터리 경로. 없을 수 있다.
    public var dataPath: String?
    /// simctl이 보고한 데이터 디렉터리 크기. 없으면 확인 불가로 취급한다.
    public var dataSizeBytes: UInt64?

    public var id: UUID { udid }

    public init(
        udid: UUID,
        name: String,
        runtimeIdentifier: String,
        state: SimulatorDeviceState,
        isAvailable: Bool?,
        dataPath: String? = nil,
        dataSizeBytes: UInt64? = nil
    ) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.state = state
        self.isAvailable = isAvailable
        self.dataPath = dataPath
        self.dataSizeBytes = dataSizeBytes
    }
}

/// 기기 디렉터리의 device.plist에서 수집한 임시(clone) 증거.
/// simctl 출력이 아닌 파일 시스템 관측값이며, UDID가 일치할 때만 기기와 병합된다.
public struct SimulatorDevicePlistEvidence: Sendable, Equatable {
    public var udid: UUID
    /// device.plist의 isEphemeral 값. 키가 없으면 nil(확인 불가).
    public var isEphemeral: Bool?
    /// 이름에 테스트 clone 표식(예: "Clone N of ...")이 있는지 여부.
    public var hasCloneNameMarker: Bool

    public init(udid: UUID, isEphemeral: Bool?, hasCloneNameMarker: Bool) {
        self.udid = udid
        self.isEphemeral = isEphemeral
        self.hasCloneNameMarker = hasCloneNameMarker
    }

    /// 영구 삭제 후보로 삼을 수 있는 증거. 이름은 설명 보조일 뿐이고 isEphemeral만 인정한다.
    public var indicatesClone: Bool {
        isEphemeral == true
    }
}

/// 파일 시스템에서 관측한 정리 후보 디렉터리 증거 (DerivedData 프로젝트, XCTestDevices 기기 등).
public struct FilesystemCandidateEvidence: Sendable, Equatable {
    /// 디렉터리의 정확한 절대 경로.
    public var path: String
    /// 디렉터리 이름 (경로 마지막 구성 요소).
    public var name: String
    /// 마지막 수정 시각. nil이면 나이를 알 수 없으므로 후보가 되지 않는다(fail closed).
    public var modifiedAt: Date?
    /// 측정된 크기. nil이면 0으로 보수적으로 추정한다.
    public var sizeBytes: UInt64?
    /// XCTestDevices 디렉터리인 경우 device.plist에서 읽은 기기 상태. nil이면 확인 불가.
    public var deviceState: SimulatorDeviceState?
    /// 파일 시스템 장치 번호와 inode를 결합한 식별자. 실행 직전 대상 교체를 감지한다.
    public var filesystemObjectIdentifier: String?

    public init(
        path: String,
        name: String,
        modifiedAt: Date?,
        sizeBytes: UInt64?,
        deviceState: SimulatorDeviceState? = nil,
        filesystemObjectIdentifier: String? = nil
    ) {
        self.path = path
        self.name = name
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.deviceState = deviceState
        self.filesystemObjectIdentifier = filesystemObjectIdentifier
    }
}

/// 정리 후보의 종류.
public enum CleanupCandidateKind: String, Sendable, Equatable, CaseIterable {
    /// 실행 중인 시뮬레이터를 종료하되 기기와 내부 데이터는 그대로 둔다.
    case bootedSimulatorShutdown
    case unavailableSimulatorDevice
    case ephemeralCloneSimulatorDevice
    /// 기기는 남기고 내부 앱·콘텐츠 데이터만 지우는 초기화 (simctl erase).
    case simulatorDataErase
    case derivedDataProject
    case xctestDeviceDirectory

    public var koreanLabel: String {
        switch self {
        case .bootedSimulatorShutdown: return "실행 중인 시뮬레이터 종료"
        case .unavailableSimulatorDevice: return "사용 불가 시뮬레이터"
        case .ephemeralCloneSimulatorDevice: return "테스트용 임시 시뮬레이터"
        case .simulatorDataErase: return "시뮬레이터 데이터 초기화"
        case .derivedDataProject: return "DerivedData 프로젝트"
        case .xctestDeviceDirectory: return "XCTest 기기 데이터"
        }
    }

    /// 시뮬레이터를 대상으로 하며 자동 정리에서 제외되는 수동 작업 종류.
    public var targetsSimulator: Bool {
        switch self {
        case .bootedSimulatorShutdown, .unavailableSimulatorDevice,
             .ephemeralCloneSimulatorDevice, .simulatorDataErase:
            return true
        case .derivedDataProject, .xctestDeviceDirectory:
            return false
        }
    }
}

/// 정리 작업의 위험도.
public enum CleanupRisk: String, Sendable, Equatable, Comparable {
    case low
    case medium
    case high

    public var koreanLabel: String {
        switch self {
        case .low: return "낮음"
        case .medium: return "보통"
        case .high: return "높음"
        }
    }

    private var severity: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: CleanupRisk, rhs: CleanupRisk) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// 정리 후 되돌리는 방법.
public enum CleanupRecoveryMethod: String, Sendable, Equatable {
    /// 휴지통으로 이동하므로 복원 가능.
    case userTrash
    /// 실행 중인 대상을 멈출 뿐 데이터는 유지되며 다시 실행할 수 있음.
    case restartable
    /// 도구가 재생성한다 (예: 재빌드, 시뮬레이터 재생성). 내부 데이터는 돌아오지 않는다.
    case recreatable
    /// 복구 수단 없음.
    case notRecoverable

    public var koreanLabel: String {
        switch self {
        case .userTrash: return "휴지통에서 복원 가능"
        case .restartable: return "다시 실행 가능 · 데이터 유지"
        case .recreatable: return "재생성 가능 (내부 데이터는 복구 불가)"
        case .notRecoverable: return "복구 불가"
        }
    }
}

/// 결정 계층이 제안하는 정리 후보. 실행은 이 계층의 책임이 아니다.
public struct CleanupCandidate: Sendable, Equatable, Identifiable {
    /// 같은 대상에 항상 같은 값이 나오는 안정적 식별자.
    public var id: String
    public var kind: CleanupCandidateKind
    /// 정확한 대상 식별자 (시뮬레이터 UDID 또는 디렉터리 이름).
    public var targetIdentifier: String
    /// 파일 시스템 대상의 정확한 경로. 시뮬레이터는 simctl이 경로를 준 경우에만 채운다.
    public var targetPath: String?
    /// 사람이 읽는 한국어 사유.
    public var koreanReason: String
    /// 확보 예상 크기. 측정값이 없으면 0 (보수적).
    public var estimatedBytes: UInt64
    public var risk: CleanupRisk
    public var isRecoverable: Bool
    public var recoveryMethod: CleanupRecoveryMethod
    public var filesystemObjectIdentifier: String?

    public init(
        id: String,
        kind: CleanupCandidateKind,
        targetIdentifier: String,
        targetPath: String?,
        koreanReason: String,
        estimatedBytes: UInt64,
        risk: CleanupRisk,
        isRecoverable: Bool,
        recoveryMethod: CleanupRecoveryMethod,
        filesystemObjectIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetIdentifier = targetIdentifier
        self.targetPath = targetPath
        self.koreanReason = koreanReason
        self.estimatedBytes = estimatedBytes
        self.risk = risk
        self.isRecoverable = isRecoverable
        self.recoveryMethod = recoveryMethod
        self.filesystemObjectIdentifier = filesystemObjectIdentifier
    }
}

/// 무확인 자동 정리에 사용할 수 있는 파일 후보 계획.
/// 복구 불가능하거나 위험도가 올라간 항목은 새 종류가 추가돼도 자동으로 제외한다.
public struct AutomaticCleanupPlan: Sendable, Equatable {
    public var targets: [CleanupCandidate]
    public var manualOnly: [CleanupCandidate]

    public init(targets: [CleanupCandidate], manualOnly: [CleanupCandidate]) {
        self.targets = targets
        self.manualOnly = manualOnly
    }
}

public enum AutomaticCleanupPolicy {
    public static func isEligible(_ candidate: CleanupCandidate) -> Bool {
        !candidate.kind.targetsSimulator
            && candidate.risk == .low
            && candidate.isRecoverable
            && candidate.recoveryMethod == .userTrash
    }

    public static func makePlan(
        candidates: [CleanupCandidate],
        protectedIdentifiers: Set<String>
    ) -> AutomaticCleanupPlan {
        let visible = candidates.filter { !protectedIdentifiers.contains($0.id) }
        return AutomaticCleanupPlan(
            targets: visible.filter(isEligible),
            manualOnly: visible.filter { !isEligible($0) }
        )
    }
}

/// 실행 직전 재검증 결과. 안전 조건이 하나라도 정확히 일치하지 않으면 차단한다.
public struct CleanupRevalidationResult: Sendable, Equatable {
    public var isAllowed: Bool
    public var koreanReason: String

    public init(isAllowed: Bool, koreanReason: String) {
        self.isAllowed = isAllowed
        self.koreanReason = koreanReason
    }
}

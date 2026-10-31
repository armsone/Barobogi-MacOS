import Foundation

/// 메모리 확보를 위한 프로세스 종료 후보의 종류.
/// 명확히 "개발 잔여물"로 분류할 수 있는 것만 케이스로 둔다.
/// 일반 Java/Node, Xcode, 시뮬레이터, Android 에뮬레이터, ADB, 시스템 프로세스는
/// 의도적으로 여기에 없다 — 어떤 입력에서도 후보가 되지 않는다.
public enum ProcessCleanupKind: String, Sendable, Equatable, CaseIterable {
    case gradleDaemon
    case kotlinDaemon
    case testRunner
    case browserAutomation
    case localServer

    public var koreanLabel: String {
        switch self {
        case .gradleDaemon: return "Gradle 데몬"
        case .kotlinDaemon: return "Kotlin 데몬"
        case .testRunner: return "테스트 러너"
        case .browserAutomation: return "브라우저 자동화"
        case .localServer: return "로컬 개발 서버"
        }
    }
}

/// 메모리 확보용 프로세스 종료 후보. 제안 시점의 관측값을 불변 증거로 담아
/// 실행 직전 재검증에 그대로 사용한다. 종료는 되돌릴 수 없다.
public struct ProcessCleanupCandidate: Sendable, Equatable, Identifiable {
    /// 같은 대상에 항상 같은 값이 나오는 안정적 식별자.
    public var id: String
    public var kind: ProcessCleanupKind
    /// 제안 시점의 정확한 PID. 이 PID 외에는 어떤 대상에도 시그널을 보내지 않는다.
    public var pid: Int32
    /// 제안 시점의 PPID. 후보는 항상 1(launchd)이다.
    public var ppid: Int32
    /// 제안 시점의 소유 사용자 (현재 사용자와 정확히 일치해야 후보가 된다).
    public var user: String
    /// 제안 시점의 정확한 명령줄. 재검증 때 한 글자라도 다르면 차단한다.
    public var command: String
    /// 제안 시점의 경과 시간(초). 재검증 때 이 값보다 줄어들면 PID 재사용으로 보고 차단한다.
    public var elapsedSeconds: Int
    /// 제안 시점의 프로세스 시작 시각. PID가 재사용돼도 반드시 달라지는 식별값이다.
    public var startTimeIdentifier: String
    public var cpuPercent: Double
    /// 종료 시 확보를 기대할 수 있는 상주 메모리. 디스크 공간과 절대 합산하지 않는다.
    public var residentBytes: UInt64
    public var risk: CleanupRisk
    public var koreanReason: String

    /// 현재 버전에서 실제 종료를 허용하는지 여부.
    /// 로컬 서버는 사용자가 의도적으로 상시 실행했을 가능성이 높아 관찰만 한다.
    public var isActionable: Bool { kind != .localServer }

    /// PID는 재사용되고 명령 인수에는 비밀값이 포함될 수 있으므로 종류와 실행 파일만 저장한다.
    /// 실행 파일 단위 보호는 일부 대상을 넓게 제외할 수 있지만, 안전 측면에서는 보수적인 방향이다.
    public var protectionIdentifier: String {
        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "unknown"
        return "process:\(kind.rawValue):\(executable)"
    }

    public init(
        id: String,
        kind: ProcessCleanupKind,
        pid: Int32,
        ppid: Int32,
        user: String,
        command: String,
        elapsedSeconds: Int,
        startTimeIdentifier: String,
        cpuPercent: Double,
        residentBytes: UInt64,
        risk: CleanupRisk,
        koreanReason: String
    ) {
        self.id = id
        self.kind = kind
        self.pid = pid
        self.ppid = ppid
        self.user = user
        self.command = command
        self.elapsedSeconds = elapsedSeconds
        self.startTimeIdentifier = startTimeIdentifier
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.risk = risk
        self.koreanReason = koreanReason
    }
}

/// ProcessCleanupPolicy에 넘기는 관측값 묶음.
/// nil은 "수집 실패/확인 불가"를 뜻하며 후보를 하나도 제안하지 않는다(fail closed).
public struct ProcessCleanupPolicyInput: Sendable, Equatable {
    /// 현재 사용자 소유 프로세스 스냅샷. nil이면 후보를 제안하지 않는다.
    public var processes: [ProcessSnapshot]?
    /// 현재 사용자 이름. nil이거나 비어 있으면 후보를 제안하지 않는다.
    public var currentUserName: String?
    /// 이 앱 자신의 PID. 어떤 경우에도 후보가 되지 않는다.
    public var ownPid: Int32

    public init(processes: [ProcessSnapshot]?, currentUserName: String?, ownPid: Int32) {
        self.processes = processes
        self.currentUserName = currentUserName
        self.ownPid = ownPid
    }
}

/// 결정적 메모리 확보 정책. 같은 입력에는 항상 같은 후보 목록을 낸다.
/// 제안만 하며 시그널 전송 등 어떤 실행도 하지 않는다.
public enum ProcessCleanupPolicy {

    /// 후보가 되기 위한 최소 경과 시간 (30분).
    public static let minimumElapsedSeconds = 30 * 60
    /// 후보가 되기 위한 최대 CPU 사용률 (1%).
    public static let maximumCpuPercent = 1.0
    /// 후보가 되기 위한 최소 상주 메모리 (64 MiB).
    public static let minimumResidentBytes: UInt64 = 64 * 1024 * 1024
    /// 후보가 될 수 있는 ps 상태의 첫 글자. 실행 중(R)·좀비(Z)·정지(T)·대기 불가(U)는 제외.
    public static let allowedStateFirstCharacters: Set<Character> = ["S", "I"]

    /// 관측값으로부터 종료 후보를 제안한다. 결과는 종류·PID 순으로 정렬돼 결정적이다.
    /// 모든 후보는 기본 미선택으로 표시돼야 하며, 위험도는 최소 medium이다.
    public static func propose(_ input: ProcessCleanupPolicyInput) -> [ProcessCleanupCandidate] {
        guard let processes = input.processes,
              let currentUser = input.currentUserName,
              !currentUser.isEmpty
        else { return [] }

        return processes
            .compactMap { snapshot -> ProcessCleanupCandidate? in
                guard let kind = classifyLeftover(command: snapshot.command),
                      isEligible(snapshot, currentUser: currentUser, ownPid: input.ownPid),
                      let elapsed = snapshot.elapsedSeconds,
                      let startTimeIdentifier = snapshot.startTimeIdentifier
                else { return nil }
                let risk = risk(for: kind)
                return ProcessCleanupCandidate(
                    id: "proc:\(kind.rawValue):\(snapshot.pid)",
                    kind: kind,
                    pid: snapshot.pid,
                    ppid: snapshot.ppid,
                    user: snapshot.user,
                    command: snapshot.command,
                    elapsedSeconds: elapsed,
                    startTimeIdentifier: startTimeIdentifier,
                    cpuPercent: snapshot.cpuPercent,
                    residentBytes: snapshot.residentBytes,
                    risk: risk,
                    koreanReason: reason(kind: kind, elapsedSeconds: elapsed)
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.pid < rhs.pid
            }
    }

    /// 명령줄이 명확한 개발 잔여물 종류에 해당하는지 판정한다. 해당 없으면 nil.
    /// ProcessClassifier의 구체 분류를 재사용하되, 허용 목록에 있는 종류만 통과시킨다.
    public static func classifyLeftover(command: String) -> ProcessCleanupKind? {
        guard let devKind = ProcessClassifier.classify(command: command) else { return nil }
        switch devKind {
        case .gradle:
            // Gradle 분류에는 gradlew 래퍼(진행 중 빌드)도 포함되므로
            // 명령줄에 데몬 표식이 있을 때만 데몬으로 인정한다.
            return command.lowercased().contains("daemon") ? .gradleDaemon : nil
        case .kotlin:
            return .kotlinDaemon
        case .test:
            return .testRunner
        case .browserAutomation:
            return .browserAutomation
        case .localServer:
            return .localServer
        case .java, .node, .xcode, .simulator, .emulator, .adb:
            // 일반 JVM/Node는 무엇을 하는지 알 수 없고,
            // Xcode·시뮬레이터·에뮬레이터·ADB는 종료 대상이 아니다.
            return nil
        }
    }

    /// 스냅샷 한 건이 안전 조건을 전부 충족하는지 판정한다. 하나라도 확인 불가면 false.
    public static func isEligible(
        _ snapshot: ProcessSnapshot,
        currentUser: String,
        ownPid: Int32
    ) -> Bool {
        guard snapshot.pid > 1, snapshot.pid != ownPid else { return false }
        guard snapshot.user == currentUser else { return false }
        guard snapshot.ppid == 1 else { return false }
        guard let elapsed = snapshot.elapsedSeconds, elapsed >= minimumElapsedSeconds else { return false }
        guard let startTimeIdentifier = snapshot.startTimeIdentifier,
              !startTimeIdentifier.isEmpty
        else { return false }
        guard snapshot.cpuPercent.isFinite,
              snapshot.cpuPercent >= 0,
              snapshot.cpuPercent <= maximumCpuPercent
        else { return false }
        guard snapshot.residentBytes >= minimumResidentBytes else { return false }
        guard let stateFirst = snapshot.state.first,
              allowedStateFirstCharacters.contains(stateFirst)
        else { return false }
        return true
    }

    /// 종류별 위험도. 로컬 서버는 의도적으로 띄워 둔 것일 수 있어 high, 나머지는 medium.
    /// low는 존재하지 않는다 — 프로세스 종료는 되돌릴 수 없기 때문이다.
    public static func risk(for kind: ProcessCleanupKind) -> CleanupRisk {
        kind == .localServer ? .high : .medium
    }

    /// 후보들의 상주 메모리 합계. 디스크 확보 예상치와 절대 합산하지 말 것.
    public static func totalExpectedResidentBytes(of candidates: [ProcessCleanupCandidate]) -> UInt64 {
        candidates.reduce(0) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.residentBytes)
            return overflow ? UInt64.max : sum
        }
    }

    private static func reason(kind: ProcessCleanupKind, elapsedSeconds: Int) -> String {
        let minutes = elapsedSeconds / 60
        let ageText = minutes >= 60 ? "\(minutes / 60)시간 이상" : "\(minutes)분 이상"
        let base = "\(ageText) launchd(PID 1)에 재부착된 채 거의 유휴 상태인 \(kind.koreanLabel)입니다. "
            + "PPID 1은 원래 세션이 끝났을 가능성을 보여주는 정황일 뿐, 작업이 버려졌다는 증명은 아닙니다. "
            + "종료(SIGTERM)는 되돌릴 수 없습니다."
        guard kind == .localServer else { return base }
        return base + " 의도적으로 계속 띄워 둔 서버라면 종료 시 접속이 끊깁니다."
    }
}

/// 실행 직전 재검증. 새 스냅샷으로 정책을 다시 돌려 같은 PID가 같은 모습으로
/// 다시 후보가 되는지 확인한다. 하나라도 달라졌거나 수집에 실패하면 차단한다.
public enum ProcessCleanupRevalidation {

    /// 후보 하나를 새 관측값으로 재검증한다. 순수 함수이며 아무것도 실행하지 않는다.
    public static func revalidate(
        candidate: ProcessCleanupCandidate,
        against freshInput: ProcessCleanupPolicyInput
    ) -> CleanupRevalidationResult {
        let fresh = ProcessCleanupPolicy.propose(freshInput)
        guard let match = fresh.first(where: { $0.pid == candidate.pid }) else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "최신 확인 결과 이 프로세스가 더 이상 안전 조건을 충족하지 않아 종료를 중단했습니다."
            )
        }
        guard match.kind == candidate.kind,
              match.ppid == candidate.ppid,
              match.user == candidate.user,
              match.startTimeIdentifier == candidate.startTimeIdentifier,
              match.command == candidate.command
        else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "프로세스가 처음 확인했을 때와 정확히 일치하지 않아 종료를 중단했습니다."
            )
        }
        // 경과 시간이 줄었다면 같은 PID를 다른 프로세스가 재사용한 것이다.
        guard match.elapsedSeconds >= candidate.elapsedSeconds else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "PID가 다른 프로세스에 재사용된 것으로 보여 종료를 중단했습니다."
            )
        }
        return CleanupRevalidationResult(
            isAllowed: true,
            koreanReason: "최신 확인 결과 안전 조건이 그대로 유지되고 있습니다."
        )
    }
}

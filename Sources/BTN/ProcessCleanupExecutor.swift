import Foundation
import Darwin

struct ProcessCleanupExecutionResult: Identifiable, Sendable {
    let id = UUID()
    let candidate: ProcessCleanupCandidate
    let status: CleanupExecutionStatus
    let message: String
}

/// 실행 직전에 프로세스 스냅샷을 다시 수집·재검증한 뒤, 정확히 그 PID 하나에만
/// SIGTERM을 보낸다. SIGKILL·프로세스 그룹 시그널·데몬 중지 명령은 어떤 경우에도 쓰지 않는다.
enum ProcessCleanupExecutor {

    /// SIGTERM 후 종료를 기다리는 최대 시간. 넘기면 강제 수단 없이 실패로 보고한다.
    static let exitWaitSeconds: TimeInterval = 5
    static let pollIntervalSeconds: TimeInterval = 0.2
    static let maximumPollAttempts = Int(exitWaitSeconds / pollIntervalSeconds)

    enum SignalResult: Equatable {
        case sent
        case noSuchProcess
        case notPermitted
        case failed(Int32)
    }

    /// 시스템 경계를 주입해 실제 사용자 프로세스를 건드리지 않고 종료 흐름 전체를 검증한다.
    struct Dependencies {
        var freshInput: () -> ProcessCleanupPolicyInput
        var sendTermination: (Int32) -> SignalResult
        var isRunning: (Int32) -> Bool
        var wait: (TimeInterval) -> Void

        static let live = Dependencies(
            freshInput: {
                ProcessCleanupPolicyInput(
                    processes: ProcessCollector.collectOptional(),
                    currentUserName: NSUserName(),
                    ownPid: ProcessInfo.processInfo.processIdentifier
                )
            },
            sendTermination: { pid in
                guard kill(pid, SIGTERM) == 0 else {
                    let code = errno
                    switch code {
                    case ESRCH: return .noSuchProcess
                    case EPERM: return .notPermitted
                    default: return .failed(code)
                    }
                }
                return .sent
            },
            isRunning: { pid in
                if kill(pid, 0) == 0 { return true }
                // EPERM은 존재하지만 조회 권한이 없는 프로세스다. 종료됐다고 오판하지 않는다.
                return errno != ESRCH
            },
            wait: { seconds in
                usleep(useconds_t(seconds * 1_000_000))
            }
        )
    }

    static func execute(
        _ candidate: ProcessCleanupCandidate,
        dependencies: Dependencies = .live
    ) -> ProcessCleanupExecutionResult {
        guard candidate.isActionable else {
            return result(candidate, .blocked, "로컬 개발 서버는 의도적으로 실행 중일 수 있어 관찰만 하며 종료하지 않습니다.")
        }

        let freshInput = dependencies.freshInput()
        let validation = ProcessCleanupRevalidation.revalidate(candidate: candidate, against: freshInput)
        guard validation.isAllowed else {
            return result(candidate, .blocked, validation.koreanReason)
        }
        // 양수 PID만 허용한다. 0·음수는 프로세스 그룹/전체 대상 시그널이 되므로 절대 보내지 않는다.
        guard candidate.pid > 1 else {
            return result(candidate, .blocked, "PID가 올바르지 않아 종료를 중단했습니다.")
        }

        switch dependencies.sendTermination(candidate.pid) {
        case .sent:
            break
        case .noSuchProcess:
            return result(candidate, .blocked, "프로세스가 이미 종료돼 있어 아무것도 하지 않았습니다.")
        case .notPermitted:
            return result(candidate, .blocked, "종료 권한이 없어 아무것도 하지 않았습니다.")
        case .failed(let code):
            return result(candidate, .failed, "SIGTERM 전송에 실패했습니다 (errno \(code)).")
        }

        for _ in 0..<maximumPollAttempts {
            dependencies.wait(pollIntervalSeconds)
            if !dependencies.isRunning(candidate.pid) {
                return result(
                    candidate, .cleaned,
                    "SIGTERM으로 정상 종료됐습니다. 상주 메모리 약 "
                        + DiagnosticEngine.formatBytes(candidate.residentBytes)
                        + "가 회수될 것으로 예상하지만, 실제 확보량은 시스템이 결정합니다."
                )
            }
        }
        return result(
            candidate, .failed,
            "SIGTERM을 보냈지만 \(Int(exitWaitSeconds))초 안에 종료되지 않았습니다. "
                + "이 앱은 강제 종료(SIGKILL)를 사용하지 않으므로 프로세스는 그대로 남아 있습니다. "
                + "필요하면 활성 상태 보기에서 직접 확인하세요."
        )
    }

    private static func result(
        _ candidate: ProcessCleanupCandidate,
        _ status: CleanupExecutionStatus,
        _ message: String
    ) -> ProcessCleanupExecutionResult {
        ProcessCleanupExecutionResult(candidate: candidate, status: status, message: message)
    }
}

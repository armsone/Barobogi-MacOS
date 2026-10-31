import Foundation

enum CleanupExecutionStatus: String, Sendable, Equatable, Codable {
    case cleaned
    case blocked
    case failed

    var koreanLabel: String {
        switch self {
        case .cleaned: return "정리 완료"
        case .blocked: return "안전 조건 변경으로 중단"
        case .failed: return "정리 실패"
        }
    }
}

struct CleanupExecutionResult: Identifiable, Sendable {
    let id = UUID()
    let candidate: CleanupCandidate
    let status: CleanupExecutionStatus
    let message: String
}

/// 허용 목록에 있는 작업만 수행하고, 각 항목을 실행 직전에 다시 수집·검증한다.
enum CleanupExecutor {
    static func execute(_ candidate: CleanupCandidate) -> CleanupExecutionResult {
        let freshInput = CleanupEvidenceCollector.collect(for: candidate.kind, measureSizes: false)
        let validation = CleanupRevalidation.revalidate(candidate: candidate, against: freshInput)
        guard validation.isAllowed else {
            return result(candidate, .blocked, validation.koreanReason)
        }

        switch candidate.kind {
        case .bootedSimulatorShutdown:
            return shutdownSimulator(candidate)
        case .unavailableSimulatorDevice, .ephemeralCloneSimulatorDevice:
            return deleteSimulator(candidate)
        case .simulatorDataErase:
            return eraseSimulator(candidate)
        case .derivedDataProject:
            return moveToTrash(candidate, allowedRoot: CleanupEvidenceCollector.derivedDataRoot)
        case .xctestDeviceDirectory:
            return moveToTrash(candidate, allowedRoot: CleanupEvidenceCollector.xctestDevicesRoot)
        }
    }

    /// 정확히 선택한 실행 중 시뮬레이터 하나만 종료한다. 기기와 내부 데이터는 지우지 않는다.
    private static func shutdownSimulator(_ candidate: CleanupCandidate) -> CleanupExecutionResult {
        guard UUID(uuidString: candidate.targetIdentifier) != nil else {
            return result(candidate, .blocked, "시뮬레이터 식별자가 올바르지 않아 중단했습니다.")
        }
        let immediateInput = CleanupEvidenceCollector.collect(for: candidate.kind, measureSizes: false)
        let immediateValidation = CleanupRevalidation.revalidate(candidate: candidate, against: immediateInput)
        guard immediateValidation.isAllowed else {
            return result(candidate, .blocked, immediateValidation.koreanReason)
        }
        guard let command = ControlledCommand.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "shutdown", candidate.targetIdentifier],
            timeout: 60
        ) else {
            return result(candidate, .failed, "simctl을 시작하지 못했습니다.")
        }
        guard command.status == 0 else {
            let detail = command.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result(candidate, .failed, detail.isEmpty ? "시뮬레이터를 종료하지 못했습니다." : detail)
        }
        return result(candidate, .cleaned, "시뮬레이터를 종료했습니다. 기기와 내부 데이터는 그대로 유지됩니다.")
    }

    private static func deleteSimulator(_ candidate: CleanupCandidate) -> CleanupExecutionResult {
        guard UUID(uuidString: candidate.targetIdentifier) != nil else {
            return result(candidate, .blocked, "시뮬레이터 식별자가 올바르지 않아 중단했습니다.")
        }
        // simctl delete 직전에 상태를 한 번 더 읽어 부팅·생성·종료 전환이 시작된 기기를 차단한다.
        let immediateInput = CleanupEvidenceCollector.collect(for: candidate.kind, measureSizes: false)
        let immediateValidation = CleanupRevalidation.revalidate(candidate: candidate, against: immediateInput)
        guard immediateValidation.isAllowed else {
            return result(candidate, .blocked, immediateValidation.koreanReason)
        }
        guard let command = ControlledCommand.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "delete", candidate.targetIdentifier],
            timeout: 60
        ) else {
            return result(candidate, .failed, "simctl을 시작하지 못했습니다.")
        }
        guard command.status == 0 else {
            let detail = command.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result(candidate, .failed, detail.isEmpty ? "simctl이 삭제를 완료하지 못했습니다." : detail)
        }
        return result(candidate, .cleaned, "종료 상태를 다시 확인한 뒤 시뮬레이터를 삭제했습니다. 내부 데이터는 복구할 수 없습니다.")
    }

    /// 기기는 남기고 내부 데이터만 지운다. 삭제와 동일하게 실행 직전 상태를 다시 확인한다.
    private static func eraseSimulator(_ candidate: CleanupCandidate) -> CleanupExecutionResult {
        guard UUID(uuidString: candidate.targetIdentifier) != nil else {
            return result(candidate, .blocked, "시뮬레이터 식별자가 올바르지 않아 중단했습니다.")
        }
        // simctl erase 직전에 상태를 한 번 더 읽어 부팅·생성·종료 전환이 시작된 기기를 차단한다.
        let immediateInput = CleanupEvidenceCollector.collect(for: candidate.kind, measureSizes: false)
        let immediateValidation = CleanupRevalidation.revalidate(candidate: candidate, against: immediateInput)
        guard immediateValidation.isAllowed else {
            return result(candidate, .blocked, immediateValidation.koreanReason)
        }
        guard let command = ControlledCommand.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "erase", candidate.targetIdentifier],
            timeout: 120
        ) else {
            return result(candidate, .failed, "simctl을 시작하지 못했습니다.")
        }
        guard command.status == 0 else {
            let detail = command.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result(candidate, .failed, detail.isEmpty ? "simctl이 초기화를 완료하지 못했습니다." : detail)
        }
        return result(
            candidate, .cleaned,
            "종료 상태를 다시 확인한 뒤 시뮬레이터 데이터를 초기화했습니다. "
                + "앱·콘텐츠 데이터는 복구할 수 없지만 기기는 그대로 남아 다시 사용할 수 있습니다."
        )
    }

    private static func moveToTrash(
        _ candidate: CleanupCandidate,
        allowedRoot: URL
    ) -> CleanupExecutionResult {
        guard let path = candidate.targetPath,
              candidate.targetIdentifier == URL(fileURLWithPath: path).lastPathComponent,
              let target = CleanupPathValidator.validatedDirectChild(
                path: path,
                expectedObjectIdentifier: candidate.filesystemObjectIdentifier,
                allowedRoot: allowedRoot
              )
        else {
            return result(candidate, .blocked, "허용된 개발 폴더의 직접 하위 대상이 아니어서 중단했습니다.")
        }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &trashedURL)
            return result(candidate, .cleaned, "휴지통으로 이동했습니다. 필요하면 Finder의 휴지통에서 복원할 수 있습니다.")
        } catch {
            // 영구 삭제로 폴백하지 않는다.
            return result(candidate, .failed, "휴지통으로 이동하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private static func result(
        _ candidate: CleanupCandidate,
        _ status: CleanupExecutionStatus,
        _ message: String
    ) -> CleanupExecutionResult {
        CleanupExecutionResult(candidate: candidate, status: status, message: message)
    }
}

/// 앱이 명시적으로 허용한 단일 도구를 제한 시간 안에서 실행한다.
private enum ControlledCommand {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, output: String)? {
        guard let result = BoundedCommandRunner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            includeStandardError: true
        ) else { return nil }
        return (result.status, String(data: result.data, encoding: .utf8) ?? "")
    }
}

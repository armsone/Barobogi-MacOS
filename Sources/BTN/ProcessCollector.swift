import Foundation

/// 읽기 전용 `/bin/ps` 실행으로 현재 사용자 소유 프로세스 스냅샷을 얻는다.
/// 어떤 프로세스에도 시그널을 보내지 않는다.
enum ProcessCollector {

    static func collect() -> [ProcessSnapshot] {
        collectOptional() ?? []
    }

    /// 안전 판단용 수집. 실패를 빈 목록과 구분해 정리를 닫힌 상태로 실패시킨다.
    static func collectOptional() -> [ProcessSnapshot]? {
        // -x: 터미널 없는 프로세스 포함, 기본적으로 현재 사용자 소유만.
        guard let result = ReadOnlyCommand.run(
            executable: "/bin/ps",
            arguments: ["-xo", PsParser.outputFormat],
            timeout: 5
        ), result.status == 0,
              let output = String(data: result.data, encoding: .utf8) else {
            return nil
        }
        // 자기 자신과 ps는 제외한다.
        let selfPid = ProcessInfo.processInfo.processIdentifier
        return PsParser.parse(output).filter { $0.pid != selfPid }
    }
}

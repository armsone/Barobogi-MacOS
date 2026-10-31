import Foundation

/// 앱이 직접 시작한 읽기 전용 도구만 제한 시간 안에서 실행한다.
/// 제한 시간을 넘기면 해당 자식 도구만 종료하며 사용자 작업 프로세스에는 관여하지 않는다.
enum ReadOnlyCommand {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (data: Data, status: Int32)? {
        BoundedCommandRunner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            includeStandardError: false
        )
    }
}

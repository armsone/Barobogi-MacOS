import Foundation
import Darwin

/// 앱이 시작한 단일 도구를 제한 시간 안에서 끝내고, 파이프 EOF에 무한 대기하지 않는다.
enum BoundedCommandRunner {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        includeStandardError: Bool
    ) -> (data: Data, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeStandardError ? pipe : FileHandle.nullDevice

        let output = LockedDataBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { readable in
            let chunk = readable.availableData
            if !chunk.isEmpty { output.append(chunk) }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            try? handle.close()
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                guard finished.wait(timeout: .now() + 1) == .success else {
                    handle.readabilityHandler = nil
                    try? handle.close()
                    return nil
                }
            }
        }

        // 종료와 마지막 readability 콜백의 순서를 보장하지 않으므로 짧게 양보한다.
        usleep(20_000)
        handle.readabilityHandler = nil
        try? handle.close()
        return (output.value, process.terminationStatus)
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

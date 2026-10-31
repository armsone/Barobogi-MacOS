import Darwin
import Foundation

enum ProcessHealthIssue: Equatable {
    case sustainedCPU
    case excessiveMemory
    case unresponsiveMainThread

    var recoveryDescription: String {
        switch self {
        case .sustainedCPU: "CPU 사용량이 계속 높음"
        case .excessiveMemory: "메모리 사용량이 계속 높음"
        case .unresponsiveMainThread: "앱 응답이 지연됨"
        }
    }
}

struct ProcessHealthSnapshot {
    let cpuPercent: Double
    let residentBytes: UInt64
    let mainThreadDelay: TimeInterval
}

struct ProcessHealthEvaluator {
    struct Configuration {
        var cpuPercentThreshold = 50.0
        var residentBytesThreshold: UInt64 = 256 * 1_024 * 1_024
        var mainThreadDelayThreshold: TimeInterval = 15
        var consecutiveSampleLimit = 6
        var mainThreadSampleLimit = 2
    }

    private let configuration: Configuration
    private var highCPUSamples = 0
    private var highMemorySamples = 0
    private var delayedMainThreadSamples = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func evaluate(_ snapshot: ProcessHealthSnapshot) -> ProcessHealthIssue? {
        highCPUSamples = snapshot.cpuPercent >= configuration.cpuPercentThreshold ? highCPUSamples + 1 : 0
        highMemorySamples = snapshot.residentBytes >= configuration.residentBytesThreshold ? highMemorySamples + 1 : 0
        delayedMainThreadSamples = snapshot.mainThreadDelay >= configuration.mainThreadDelayThreshold
            ? delayedMainThreadSamples + 1
            : 0

        if delayedMainThreadSamples >= configuration.mainThreadSampleLimit {
            reset()
            return .unresponsiveMainThread
        }
        if highCPUSamples >= configuration.consecutiveSampleLimit {
            reset()
            return .sustainedCPU
        }
        if highMemorySamples >= configuration.consecutiveSampleLimit {
            reset()
            return .excessiveMemory
        }
        return nil
    }

    mutating func reset() {
        highCPUSamples = 0
        highMemorySamples = 0
        delayedMainThreadSamples = 0
    }
}

final class ProcessHealthMonitor {
    var onIssue: ((ProcessHealthIssue, ProcessHealthSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.nasfinder.TrackpadGuard.health", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var evaluator = ProcessHealthEvaluator(
        configuration: ProcessHealthEvaluator.Configuration(
            cpuPercentThreshold: .greatestFiniteMagnitude,
            residentBytesThreshold: .max
        )
    )
    private var previousCPUTime: TimeInterval?
    private var previousUptime: TimeInterval?
    private var pendingMainThreadHeartbeatSince: TimeInterval?
    private var isAwaitingRecovery = false

    func start() {
        stateLock.lock()
        guard timer == nil else {
            stateLock.unlock()
            return
        }

        evaluator.reset()
        previousCPUTime = nil
        previousUptime = nil
        pendingMainThreadHeartbeatSince = nil
        isAwaitingRecovery = false

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        stateLock.unlock()
        timer.resume()
    }

    func stop() {
        stateLock.lock()
        let timer = self.timer
        self.timer = nil
        evaluator.reset()
        previousCPUTime = nil
        previousUptime = nil
        pendingMainThreadHeartbeatSince = nil
        isAwaitingRecovery = false
        stateLock.unlock()
        timer?.cancel()
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let mainThreadDelay = updateMainThreadHeartbeat(at: now)
        guard let cpuTime = Self.processCPUTime(),
              let residentBytes = Self.residentMemoryBytes() else { return }

        stateLock.lock()
        defer { stateLock.unlock() }

        guard timer != nil, !isAwaitingRecovery else { return }
        defer {
            previousCPUTime = cpuTime
            previousUptime = now
        }

        guard let previousCPUTime, let previousUptime, now > previousUptime else { return }
        let cpuPercent = max(0, (cpuTime - previousCPUTime) / (now - previousUptime) * 100)
        let snapshot = ProcessHealthSnapshot(
            cpuPercent: cpuPercent,
            residentBytes: residentBytes,
            mainThreadDelay: mainThreadDelay
        )

        guard let issue = evaluator.evaluate(snapshot) else { return }
        isAwaitingRecovery = true
        DispatchQueue.main.async { [weak self] in self?.onIssue?(issue, snapshot) }
    }

    private func updateMainThreadHeartbeat(at now: TimeInterval) -> TimeInterval {
        stateLock.lock()
        let pendingSince: TimeInterval
        if let existing = pendingMainThreadHeartbeatSince {
            pendingSince = existing
        } else {
            pendingMainThreadHeartbeatSince = now
            pendingSince = now
            DispatchQueue.main.async { [weak self] in
                self?.stateLock.lock()
                self?.pendingMainThreadHeartbeatSince = nil
                self?.stateLock.unlock()
            }
        }
        stateLock.unlock()
        return now - pendingSince
    }

    private static func processCPUTime() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}

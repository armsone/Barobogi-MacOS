import Foundation
import Darwin

/// 로컬 macOS API(getloadavg, sysctl, Mach host 통계)로만 지표를 읽는다.
/// 관리자 권한이 필요 없고 시스템 상태를 바꾸지 않는다.
enum MetricsCollector {

    static func collect() -> MetricsSnapshot {
        let swap = readSwapUsage()
        return MetricsSnapshot(
            loadAverage1Min: readLoadAverage(),
            cpuCoreCount: ProcessInfo.processInfo.activeProcessorCount,
            memoryPressure: readMemoryPressure(),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableMemoryBytes: readAvailableMemory(),
            swapTotalBytes: swap?.total ?? 0,
            swapUsedBytes: swap?.used ?? 0
        )
    }

    private static func readLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1 else { return 0 }
        return loads[0]
    }

    /// kern.memorystatus_vm_pressure_level: 1=정상, 2=경고, 4=심각.
    /// 읽지 못하면 unknown으로 두고 판단에서 제외한다(안전한 실패).
    private static func readMemoryPressure() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private static func readSwapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (total: usage.xsu_total, used: usage.xsu_used)
    }

    /// free + inactive 페이지를 "사용 가능"으로 근사한다. 실패 시 nil.
    private static func readAvailableMemory() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { pointer in
            let hostPort = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, hostPort) }
            return pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
    }
}

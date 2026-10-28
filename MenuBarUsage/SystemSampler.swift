import Darwin
import Foundation

/// CPU and memory samples from the Mach host. CPU percent needs two ticks
/// a couple of seconds apart; memory is a single reading.
enum SystemSampler {
    /// The host port does not change for the life of the process.
    static let host: mach_port_t = mach_host_self()

    /// Page size is fixed for the boot. `nil` if the kernel would not report it.
    static let pageSize: UInt64? = {
        var size: vm_size_t = 0
        guard host_page_size(host, &size) == KERN_SUCCESS, size > 0 else { return nil }
        return UInt64(size)
    }()

    static let physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    struct CPUTicks: Equatable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    struct Memory: Equatable {
        var usedBytes: UInt64
        var totalBytes: UInt64

        var percent: Double? {
            guard totalBytes > 0 else { return nil }
            return Double(usedBytes) / Double(totalBytes) * 100
        }
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(host, HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // CPU_STATE_USER, SYSTEM, IDLE, NICE.
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    static func cpuPercent(from previous: CPUTicks, to current: CPUTicks) -> Double? {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }

    /// Active + wired + compressed pages, which is the memory Activity Monitor
    /// groups as used. File cache stays out of the used number.
    static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, let pageSize else { return nil }
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let total = physicalMemory
        let used = min(usedPages * pageSize, total)
        return Memory(usedBytes: used, totalBytes: total)
    }
}

import Darwin
import Foundation

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

public struct ProcessUsage: Equatable, Sendable {
    public var rss: UInt64
    public var cpu: Double
    public var processes: Int
}

public struct UsageSnapshot: Equatable, Sendable {
    public var takenAt: Date
    public var ramTotal: UInt64
    public var ramUsed: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure
    public var cpu: Double
    public var claude: ProcessUsage
    public var perSession: [Int32: ProcessUsage]

    public var ramFraction: Double { ramTotal == 0 ? 0 : min(1, Double(ramUsed) / Double(ramTotal)) }
}

public final class UsageSampler: @unchecked Sendable {
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastProcTime: [Int32: UInt64] = [:]
    private var lastSampleAt: Date?
    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    public init() {}

    public func sample(claudePIDs: [Int32], now: Date = Date()) -> UsageSnapshot {
        let (total, used, compressed) = Self.memory()
        let (swapUsed, swapTotal) = Self.swap()
        let cpu = systemCPU()
        let tree = Self.descendants(of: claudePIDs)
        let dt = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        var nextTimes: [Int32: UInt64] = [:]
        var per: [Int32: ProcessUsage] = [:]
        var all = ProcessUsage(rss: 0, cpu: 0, processes: 0)
        for (root, pids) in tree {
            var u = ProcessUsage(rss: 0, cpu: 0, processes: 0)
            for pid in pids {
                guard let (rss, time) = Self.task(pid) else { continue }
                u.rss += rss
                u.processes += 1
                if dt > 0.2, let prev = lastProcTime[pid], time >= prev {
                    u.cpu += Double(time - prev) * Self.timebase / 1e9 / dt * 100
                }
                nextTimes[pid] = time
            }
            per[root] = u
            all.rss += u.rss
            all.cpu += u.cpu
            all.processes += u.processes
        }
        lastProcTime = nextTimes
        lastSampleAt = now
        return UsageSnapshot(takenAt: now, ramTotal: total, ramUsed: used, compressed: compressed,
                             swapUsed: swapUsed, swapTotal: swapTotal, pressure: Self.pressure(),
                             cpu: cpu, claude: all, perSession: per)
    }

    static func descendants(of roots: [Int32]) -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for pid in Proc.allPids() {
            if let i = Proc.info(pid) { children[i.ppid, default: []].append(pid) }
        }
        var out: [Int32: [Int32]] = [:]
        for root in roots {
            var seen: Set<Int32> = [root]
            var stack = [root]
            while let p = stack.popLast() {
                for c in children[p] ?? [] where seen.insert(c).inserted { stack.append(c) }
            }
            out[root] = Array(seen)
        }
        return out
    }

    static func task(_ pid: Int32) -> (rss: UInt64, time: UInt64)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_user_time + info.ri_system_time)
    }

    static func memory() -> (total: UInt64, used: UInt64, compressed: UInt64) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (total, 0, 0) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count)
        let comp = UInt64(stats.compressor_page_count)
        return (total, (app + wired + comp) * page, comp * page)
    }

    static func swap() -> (used: UInt64, total: UInt64) {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return (0, 0) }
        return (x.xsu_used, x.xsu_total)
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    func systemCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let user = UInt64(t.0), sys = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + sys + nice, total = busy + idle
        defer { lastCPUTicks = (busy, total) }
        guard let last = lastCPUTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    public static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}

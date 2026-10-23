import Darwin
import Foundation

public enum MemoryAlertLevel: Int, Comparable, Sendable {
    case warning = 1
    case critical = 2

    public static func < (a: MemoryAlertLevel, b: MemoryAlertLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct MemoryAlert: Equatable, Sendable {
    public struct Child: Equatable, Sendable {
        public var pid: Int32
        public var name: String
        public var rss: UInt64
        public var comm: String?
        public var startedAt: Date?

        public init(pid: Int32, name: String, rss: UInt64, comm: String? = nil, startedAt: Date? = nil) {
            self.pid = pid
            self.name = name
            self.rss = rss
            self.comm = comm
            self.startedAt = startedAt
        }
    }

    public struct Entry: Equatable, Sendable {
        public var sessionPID: Int32
        public var rss: UInt64
        public var cpu: Double
        public var children: [Child]

        public init(sessionPID: Int32, rss: UInt64, cpu: Double, children: [Child]) {
            self.sessionPID = sessionPID
            self.rss = rss
            self.cpu = cpu
            self.children = children
        }
    }

    public var level: MemoryAlertLevel
    public var ramUsed: UInt64
    public var ramTotal: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var top: [Entry]

    public init(level: MemoryAlertLevel, ramUsed: UInt64, ramTotal: UInt64, swapUsed: UInt64, swapTotal: UInt64, top: [Entry]) {
        self.level = level
        self.ramUsed = ramUsed
        self.ramTotal = ramTotal
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.top = top
    }
}

public struct MemorySignals: Equatable, Sendable {
    public var pressure: MemoryPressure
    public var ramUsed: UInt64
    public var ramTotal: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64

    public init(pressure: MemoryPressure, ramUsed: UInt64, ramTotal: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        self.pressure = pressure
        self.ramUsed = ramUsed
        self.ramTotal = ramTotal
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
    }

    public var swapFraction: Double { swapTotal == 0 ? 0 : Double(swapUsed) / Double(swapTotal) }

    public static func read() -> MemorySignals {
        let (total, used, _) = UsageSampler.memory()
        let (swapUsed, swapTotal) = UsageSampler.swap()
        return MemorySignals(pressure: UsageSampler.pressure(), ramUsed: used, ramTotal: total, swapUsed: swapUsed, swapTotal: swapTotal)
    }
}

public struct MemoryWatch: Sendable {
    public static let cooldown: TimeInterval = 600
    public static let swapHigh = 0.8
    public static let swapClear = 0.7

    private var active: MemoryAlertLevel?
    private var lastFired: (level: MemoryAlertLevel, at: Date)?

    public init() {}

    public mutating func evaluate(_ s: MemorySignals, now: Date = Date()) -> MemoryAlertLevel? {
        let current: MemoryAlertLevel?
        switch s.pressure {
        case .critical: current = .critical
        case .warning: current = .warning
        case .normal:
            if s.swapFraction > Self.swapHigh || (active != nil && s.swapFraction > Self.swapClear) {
                current = .warning
            } else {
                current = nil
            }
        }
        let previous = active
        active = current
        guard let current, previous == nil || current > previous! else { return nil }
        if let last = lastFired, now.timeIntervalSince(last.at) < Self.cooldown, current <= last.level { return nil }
        lastFired = (current, now)
        return current
    }

    public static func alert(level: MemoryAlertLevel, sessionPIDs: [Int32], sampler: UsageSampler) -> MemoryAlert {
        let snap = sampler.sample(claudePIDs: sessionPIDs)
        let tree = UsageSampler.descendants(of: sessionPIDs)
        let top = snap.perSession
            .map { pid, u -> MemoryAlert.Entry in
                let kids = (tree[pid] ?? [])
                    .filter { $0 != pid }
                    .compactMap { c -> MemoryAlert.Child? in
                        guard let (rss, _) = UsageSampler.task(c) else { return nil }
                        let info = Proc.info(c)
                        return MemoryAlert.Child(pid: c, name: processName(c), rss: rss, comm: info?.comm, startedAt: info?.startedAt)
                    }
                    .sorted { $0.rss > $1.rss }
                return MemoryAlert.Entry(sessionPID: pid, rss: u.rss, cpu: u.cpu, children: Array(kids.prefix(3)))
            }
            .sorted { $0.rss > $1.rss }
        return MemoryAlert(level: level, ramUsed: snap.ramUsed, ramTotal: snap.ramTotal,
                           swapUsed: snap.swapUsed, swapTotal: snap.swapTotal, top: top)
    }

    public static func stillSame(_ child: MemoryAlert.Child) -> Bool {
        guard let info = Proc.info(child.pid), let comm = child.comm, let started = child.startedAt else { return false }
        return info.comm == comm && abs(info.startedAt.timeIntervalSince(started)) < 1
    }

    public static func isStoppable(_ pid: Int32, sessionPIDs: [Int32]) -> Bool {
        guard pid > 1, !sessionPIDs.contains(pid), pid != getpid() else { return false }
        return UsageSampler.descendants(of: sessionPIDs).values.contains { $0.contains(pid) }
    }

    public static func processName(_ pid: Int32) -> String {
        let comm = Proc.info(pid)?.comm ?? "process"
        let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "java", "uv", "npx", "uvx"]
        guard runtimes.contains(comm) else { return comm }
        let args = Proc.args(pid).dropFirst().filter { !$0.hasPrefix("-") }
        guard let script = args.first else { return comm }
        var name = (script as NSString).lastPathComponent
        for ext in [".js", ".mjs", ".cjs", ".ts", ".py"] where name.hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        if ["index", "main", "cli", "server", "dist"].contains(name) {
            let parent = ((script as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty, parent != "dist", parent != "bin" { name = parent }
        }
        return name.isEmpty ? comm : String(name.prefix(24))
    }
}

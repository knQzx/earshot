import Darwin
import Foundation

public enum Proc {
    public struct Info: Equatable, Sendable {
        public var pid: Int32
        public var ppid: Int32
        public var tty: String?
        public var comm: String
        public var startedAt: Date
    }

    public static func info(_ pid: Int32) -> Info? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let tv = kp.kp_proc.p_un.__p_starttime
        return Info(
            pid: pid,
            ppid: kp.kp_eproc.e_ppid,
            tty: ttyName(kp.kp_eproc.e_tdev),
            comm: comm,
            startedAt: Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6))
    }

    public static func ttyName(_ dev: dev_t) -> String? {
        guard dev != -1, dev != 0, let p = devname(dev, S_IFCHR) else { return nil }
        let name = String(cString: p)
        return name.isEmpty || name == "??" ? nil : name
    }

    public static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return s.isEmpty ? nil : s
    }

    public static func args(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public static func allPids() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got))).filter { $0 > 0 }
    }

    public static func mightBeClaude(comm: String) -> Bool {
        if comm == "claude" || comm == "node" || comm == "bun" { return true }
        return !comm.isEmpty && comm.allSatisfy { $0.isNumber || $0 == "." }
    }

    public static func isClaude(_ pid: Int32, comm: String? = nil) -> Bool {
        let c = comm ?? info(pid)?.comm ?? ""
        if c == "claude" { return true }
        let p = path(pid) ?? ""
        if p.contains("/claude/versions/") || (p as NSString).lastPathComponent == "claude" { return true }
        if c == "node" || c == "bun" {
            return args(pid).dropFirst().prefix(3).contains { a in
                a.contains("@anthropic-ai/claude-code") || (a as NSString).lastPathComponent == "claude"
            }
        }
        return false
    }

    public static func claudeAncestor(from pid: Int32, maxDepth: Int = 16) -> Info? {
        var cur = pid
        for _ in 0..<maxDepth {
            guard cur > 1, let i = info(cur) else { return nil }
            if isClaude(cur, comm: i.comm) { return i }
            cur = i.ppid
        }
        return nil
    }

    public static func appAncestor(from pid: Int32, maxDepth: Int = 24) -> (pid: Int32, bundlePath: String)? {
        var cur = pid
        for _ in 0..<maxDepth {
            guard cur > 1, let i = info(cur) else { return nil }
            if let p = path(cur), let r = p.range(of: ".app/Contents/MacOS/") {
                return (cur, String(p[..<r.lowerBound]) + ".app")
            }
            cur = i.ppid
        }
        return nil
    }

    public static func claudeProcesses() -> [ClaudeProcess] {
        allPids().compactMap { pid in
            guard let i = info(pid), i.tty != nil, mightBeClaude(comm: i.comm), isClaude(pid, comm: i.comm), let tty = i.tty else { return nil }
            if let parent = info(i.ppid), isClaude(i.ppid, comm: parent.comm) { return nil }
            return ClaudeProcess(pid: pid, tty: tty, cwd: cwd(pid) ?? "", startedAt: i.startedAt)
        }
    }
}

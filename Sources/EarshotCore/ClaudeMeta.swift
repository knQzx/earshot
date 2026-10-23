import Foundation

public struct ClaudeMeta: Equatable, Sendable {
    public var sessionID: String?
    public var cwd: String?
    public var name: String?
    public var nameSource: String?
    public var status: String?
    public var statusUpdatedAt: Date?
    public var aiTitle: String?

    public init(sessionID: String? = nil, cwd: String? = nil, name: String? = nil, nameSource: String? = nil,
                status: String? = nil, statusUpdatedAt: Date? = nil, aiTitle: String? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.aiTitle = aiTitle
    }
}

public final class ClaudeMetaReader: @unchecked Sendable {
    public static let tailBytes = 256 * 1024
    public static let wideTailBytes = 2 * 1024 * 1024

    public static var configDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    private struct TitleCache {
        var path: String
        var size: UInt64
        var mtime: Date
        var title: String?
        var checkedAt: Date
        var wideRead = false
    }

    public static let missingRetry: TimeInterval = 60

    let sessionsDir: URL
    let projectsDir: URL
    let refreshEvery: TimeInterval
    private let clock: () -> Date
    private let lock = NSLock()
    private var titles: [String: TitleCache] = [:]
    private var missing: [String: Date] = [:]
    private(set) var transcriptReads = 0

    public init(configDir: URL = ClaudeMetaReader.configDir, refreshEvery: TimeInterval = 30, clock: @escaping () -> Date = Date.init) {
        sessionsDir = configDir.appendingPathComponent("sessions", isDirectory: true)
        projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        self.refreshEvery = refreshEvery
        self.clock = clock
    }

    public func meta(pid: Int32, processStart: Date? = nil) -> ClaudeMeta? {
        guard pid > 0 else { return nil }
        let url = sessionsDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let p = (o["pid"] as? NSNumber)?.int32Value, p != pid { return nil }
        if let start = processStart, let raw = o["procStart"] as? String, let recorded = Self.procStart(raw),
           abs(recorded.timeIntervalSince(start)) > 5 {
            return nil
        }
        func text(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var m = ClaudeMeta(
            sessionID: text("sessionId"),
            cwd: text("cwd"),
            name: text("name"),
            nameSource: text("nameSource"),
            status: text("status"),
            statusUpdatedAt: (o["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        if let sid = m.sessionID {
            m.aiTitle = aiTitle(sessionID: sid, cwd: m.cwd)
        }
        return m
    }

    public func aiTitle(sessionID sid: String, cwd: String?) -> String? {
        guard sid.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let now = clock()
        lock.lock()
        let cached = titles[sid]
        lock.unlock()
        if let c = cached, now.timeIntervalSince(c.checkedAt) < refreshEvery { return c.title }
        lock.lock()
        let missedAt = missing[sid]
        lock.unlock()
        if cached == nil, let missedAt, now.timeIntervalSince(missedAt) < Self.missingRetry { return nil }

        let path = cached.map(\.path).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? transcriptPath(sessionID: sid, cwd: cwd)
        guard let path, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else {
            if cached == nil {
                lock.lock()
                missing[sid] = now
                lock.unlock()
            }
            return cached?.title
        }

        let samePath = cached?.path == path
        var entry = TitleCache(path: path, size: size, mtime: mtime, title: cached?.title, checkedAt: now,
                               wideRead: samePath && cached?.wideRead == true)
        if let c = cached, samePath, c.size == size, c.mtime == mtime {
            entry.title = c.title
        } else {
            let (t, wide) = readTitle(path: path, size: size, allowWide: !entry.wideRead)
            if let t { entry.title = t }
            if wide { entry.wideRead = true }
        }
        lock.lock()
        titles[sid] = entry
        missing[sid] = nil
        lock.unlock()
        return entry.title
    }

    public func prune(keeping sessionIDs: Set<String>) {
        lock.lock()
        titles = titles.filter { sessionIDs.contains($0.key) }
        missing = missing.filter { sessionIDs.contains($0.key) }
        lock.unlock()
    }

    func transcriptPath(sessionID sid: String, cwd: String?) -> String? {
        let fm = FileManager.default
        let file = sid + ".jsonl"
        if let cwd {
            for dir in [cwd.replacingOccurrences(of: "/", with: "-"),
                        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })] {
                let p = projectsDir.appendingPathComponent(dir).appendingPathComponent(file).path
                if fm.fileExists(atPath: p) { return p }
            }
        }
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return nil }
        for d in dirs {
            let p = projectsDir.appendingPathComponent(d).appendingPathComponent(file).path
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func readTitle(path: String, size: UInt64, allowWide: Bool) -> (title: String?, wide: Bool) {
        guard let h = FileHandle(forReadingAtPath: path) else { return (nil, false) }
        defer { try? h.close() }
        var wide = false
        for window in allowWide ? [Self.tailBytes, Self.wideTailBytes] : [Self.tailBytes] {
            let start = size > UInt64(window) ? size - UInt64(window) : 0
            if window == Self.wideTailBytes { wide = true }
            lock.lock()
            transcriptReads += 1
            lock.unlock()
            guard (try? h.seek(toOffset: start)) != nil,
                  let data = try? h.read(upToCount: Int(size - start)) else { return (nil, wide) }
            if let t = Self.lastTitle(in: data) { return (t, wide) }
            if start == 0 { break }
        }
        return (nil, wide)
    }

    static func lastTitle(in data: Data) -> String? {
        let marker = Data("\"ai-title\"".utf8)
        var end = data.endIndex
        while end > data.startIndex, let r = data.range(of: marker, options: .backwards, in: data.startIndex..<end) {
            let lineStart = data[..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[r.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let o = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
               o["type"] as? String == "ai-title",
               let t = (o["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
            end = lineStart
        }
        return nil
    }

    static func procStart(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
    }
}

import Darwin
import Foundation

public struct PolicyLoad: Equatable, Sendable {
    public var policy: Policy
    public var problem: String?
    public var unreadable: Bool
}

public enum PolicyStore {
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["EARSHOT_POLICY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Paths.supportDir.appendingPathComponent("policy.json")
    }

    public static var defaults: Policy { PolicyCatalog.defaults }

    public static func lastGoodURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).last-good.json")
    }

    public static func load(from url: URL = defaultURL) -> Policy? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Policy.self, from: data)
    }

    public static func effective(at url: URL = defaultURL) -> PolicyLoad {
        guard let data = try? Data(contentsOf: url) else {
            return PolicyLoad(policy: defaults, problem: nil, unreadable: false)
        }
        if let p = try? JSONDecoder().decode(Policy.self, from: data) {
            let problem = p.skipped > 0 ? "\(p.skipped) rule\(p.skipped == 1 ? "" : "s") in policy.json could not be read and \(p.skipped == 1 ? "is" : "are") ignored" : nil
            return PolicyLoad(policy: p, problem: problem, unreadable: false)
        }
        if let good = load(from: lastGoodURL(for: url)) {
            return PolicyLoad(policy: good, problem: "policy.json has an error, the last good copy is in use", unreadable: true)
        }
        return PolicyLoad(policy: defaults, problem: "policy.json has an error, the defaults are in use", unreadable: true)
    }

    public static func save(_ policy: Policy, to url: URL = defaultURL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var p = policy
        p.version = Policy.version
        for r in PolicyCatalog.rules where p.catalog[r.id] == nil { p.catalog[r.id] = r.defaultChoice }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(p) + Data([0x0A])
        try atomicWrite(data, to: url)
        try? atomicWrite(data, to: lastGoodURL(for: url))
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".policy.json.\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    @discardableResult
    public static func ensureDefaults(at url: URL = defaultURL) throws -> Policy {
        guard let data = try? Data(contentsOf: url) else {
            try save(defaults, to: url)
            return defaults
        }
        guard let p = try? JSONDecoder().decode(Policy.self, from: data) else { return effective(at: url).policy }
        let stored = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int ?? 1
        let missing = PolicyCatalog.rules.contains { p.catalog[$0.id] == nil }
        if stored < Policy.version || missing {
            try save(p, to: url)
        } else if p.skipped == 0 {
            try? atomicWrite(data, to: lastGoodURL(for: url))
        }
        return p
    }

    public static func update(at url: URL = defaultURL, _ change: (inout Policy) -> Void) throws -> Policy {
        var p: Policy
        if FileManager.default.fileExists(atPath: url.path) {
            guard let loaded = load(from: url) else { throw CocoaError(.fileReadCorruptFile) }
            p = loaded
        } else {
            p = defaults
        }
        change(&p)
        try save(p, to: url)
        return p
    }
}

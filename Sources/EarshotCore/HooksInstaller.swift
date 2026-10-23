import Foundation

public enum HookInstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
    case viaPlugin

    public var isActive: Bool { self == .installed || self == .viaPlugin }
}

public enum HooksInstallerError: Error, Equatable {
    case invalidSettings(String)
    case changedWhileWriting
}

public enum HooksInstaller {
    public static let marker = "earshot-hook"
    public static let backupSuffix = ".earshot-backup"

    public static let events: [String] = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure",
    ]

    public static var settingsURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public static func command(for hookPath: String) -> String {
        if hookPath.hasPrefix("\"") { return hookPath }
        var escaped = ""
        for c in hookPath {
            if "\"$`\\".contains(c) { escaped.append("\\") }
            escaped.append(c)
        }
        return "\"\(escaped)\""
    }

    public static func timeout(for event: String) -> Int {
        event == "PermissionRequest" || event == "PreToolUse" ? 86400 : 10
    }

    public static func status(hookCommand: String, settingsURL: URL = settingsURL) -> HookInstallState {
        guard let (_, root) = try? load(settingsURL.resolvingSymlinksInPath()) else { return .notInstalled }
        let direct = state(root, command: command(for: hookCommand))
        if direct == .installed { return .installed }
        if (root["enabledPlugins"] as? [String: Any])?[pluginID] as? Bool == true { return .viaPlugin }
        return direct
    }

    public static let pluginID = "earshot@earshot"

    public static func install(hookCommand: String, settingsURL: URL = settingsURL) throws {
        let cmd = command(for: hookCommand)
        try edit(settingsURL) { root in
            if state(root, command: cmd) == .installed { return false }
            var hooks = try hooksObject(root)
            stripOurs(&hooks)
            for event in events {
                var groups = hooks[event] as? [Any] ?? []
                groups.append(group(event: event, command: cmd))
                hooks[event] = groups
            }
            root["hooks"] = hooks
            return true
        }
    }

    public static func uninstall(settingsURL: URL = settingsURL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try edit(settingsURL) { root in
            guard root["hooks"] != nil else { return false }
            var hooks = try hooksObject(root)
            guard stripOurs(&hooks) else { return false }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            return true
        }
    }

    static func group(event: String, command: String) -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [["type": "command", "command": command, "timeout": timeout(for: event)] as [String: Any]],
        ]
    }

    private struct Handler {
        var matcher: String?
        var hook: [String: Any]
    }

    private static func ourHandlers(_ value: Any) -> [Handler] {
        guard let groups = value as? [Any] else { return [] }
        var out: [Handler] = []
        for case let g as [String: Any] in groups {
            guard let hs = g["hooks"] as? [Any] else { continue }
            for case let h as [String: Any] in hs where isOurs(h) {
                out.append(Handler(matcher: g["matcher"] as? String, hook: h))
            }
        }
        return out
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) ?? false
    }

    private static func matches(_ h: Handler, event: String, command: String) -> Bool {
        h.matcher == "*"
            && h.hook["type"] as? String == "command"
            && h.hook["command"] as? String == command
            && (h.hook["timeout"] as? NSNumber)?.intValue == timeout(for: event)
            && h.hook.count == 3
    }

    private static func state(_ root: [String: Any], command cmd: String) -> HookInstallState {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var seen = false
        var exact = true
        for (event, value) in hooks {
            let ours = ourHandlers(value)
            if !ours.isEmpty { seen = true }
            if events.contains(event) {
                if ours.count != 1 || !matches(ours[0], event: event, command: cmd) { exact = false }
            } else if !ours.isEmpty {
                exact = false
            }
        }
        if events.contains(where: { hooks[$0] == nil }) { exact = false }
        if !seen { return .notInstalled }
        return exact ? .installed : .outdated
    }

    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else { throw HooksInstallerError.invalidSettings("\"hooks\" is not an object") }
        for (event, value) in hooks where !(value is [Any]) {
            throw HooksInstallerError.invalidSettings("\"hooks.\(event)\" is not an array")
        }
        return hooks
    }

    @discardableResult
    private static func stripOurs(_ hooks: inout [String: Any]) -> Bool {
        var changed = false
        for (event, value) in hooks {
            guard var groups = value as? [Any] else { continue }
            var i = groups.count - 1
            while i >= 0 {
                if var g = groups[i] as? [String: Any], var hs = g["hooks"] as? [Any] {
                    let before = hs.count
                    hs.removeAll { ($0 as? [String: Any]).map(isOurs) ?? false }
                    if hs.count != before {
                        changed = true
                        if hs.isEmpty {
                            groups.remove(at: i)
                        } else {
                            g["hooks"] = hs
                            groups[i] = g
                        }
                    }
                }
                i -= 1
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        return changed
    }

    private static func load(_ url: URL) throws -> (Data?, [String: Any]) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return (nil, [:])
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return (data, [:]) }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers])
        } catch {
            throw HooksInstallerError.invalidSettings("not valid JSON")
        }
        guard let root = obj as? [String: Any] else { throw HooksInstallerError.invalidSettings("top level is not an object") }
        return (data, root)
    }

    private static func edit(_ url: URL, _ change: (inout [String: Any]) throws -> Bool) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        for _ in 0..<3 {
            let (original, loaded) = try load(target)
            var root = loaded
            guard try change(&root) else { return }
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0A])
            if out == original { return }

            let dir = target.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + backupSuffix)
            if let original, !fm.fileExists(atPath: backup.path) {
                try writeExclusive(original, to: backup)
            }

            let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).earshot-\(UUID().uuidString)")
            guard fm.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: mode]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let current = try? Data(contentsOf: target)
            if current != original {
                try? fm.removeItem(at: tmp)
                continue
            }
            if rename(tmp.path, target.path) != 0 {
                let err = errno
                try? fm.removeItem(at: tmp)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            return
        }
        throw HooksInstallerError.changedWhileWriting
    }

    static func writeExclusive(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == EEXIST { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += n
            }
            return true
        }
        if !ok { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

import Foundation

public enum JumpScript {
    public static let terminalBundleID = "com.apple.Terminal"
    public static let iTermBundleID = "com.googlecode.iterm2"

    public static func normalizedTTY(_ raw: String?) -> String? {
        guard var t = raw else { return nil }
        if t.hasPrefix("/dev/") { t.removeFirst(5) }
        guard t.range(of: "^ttys?[0-9]+$", options: .regularExpression) != nil else { return nil }
        return t
    }

    public static func terminal(tty raw: String, dryRun: Bool = false) -> String? {
        guard let tty = normalizedTTY(raw) else { return nil }
        let action = dryRun ? ["return \"found \" & (wid as text) & \" \" & (n as text)"] : [
            "set w to window id wid",
            "set miniaturized of w to false",
            "set selected tab of w to tab n of w",
            "set index of w to 1",
            "activate",
            "return \"found\"",
        ]
        return ([
            "tell application id \"\(terminalBundleID)\"",
            "set wid to missing value",
            "repeat with w in windows",
            "try",
            "set n to 0",
            "repeat with t in tabs of w",
            "set n to n + 1",
            "if tty of t is \"/dev/\(tty)\" then",
            "set wid to id of w",
            "exit repeat",
            "end if",
            "end repeat",
            "end try",
            "if wid is not missing value then exit repeat",
            "end repeat",
            "if wid is missing value then return \"missing\"",
        ] + action + ["end tell"]).joined(separator: "\n")
    }

    public static func iTerm(tty raw: String, dryRun: Bool = false) -> String? {
        guard let tty = normalizedTTY(raw) else { return nil }
        let action = dryRun ? ["return \"found \" & (wid as text) & \" \" & (ti as text) & \" \" & (si as text)"] : [
            "set w to window id wid",
            "try",
            "set miniaturized of w to false",
            "end try",
            "tell w to select",
            "tell tab ti of w to select",
            "tell session si of tab ti of w to select",
            "activate",
            "return \"found\"",
        ]
        return ([
            "tell application id \"\(iTermBundleID)\"",
            "set wid to missing value",
            "repeat with w in windows",
            "try",
            "set ti to 0",
            "repeat with t in tabs of w",
            "set ti to ti + 1",
            "set si to 0",
            "repeat with s in sessions of t",
            "set si to si + 1",
            "if tty of s is \"/dev/\(tty)\" then",
            "set wid to id of w",
            "exit repeat",
            "end if",
            "end repeat",
            "if wid is not missing value then exit repeat",
            "end repeat",
            "end try",
            "if wid is not missing value then exit repeat",
            "end repeat",
            "if wid is missing value then return \"missing\"",
        ] + action + ["end tell"]).joined(separator: "\n")
    }

    public struct TmuxPane: Equatable, Sendable {
        public var session: String
        public var window: String
        public var pane: String
    }

    public struct TmuxClient: Equatable, Sendable {
        public var tty: String
        public var session: String
        public var activity: Int
        public var pid: Int32
    }

    public static let tmuxPaneFormat = "#{pane_tty} #{session_id} #{window_id} #{pane_id}"
    public static let tmuxClientFormat = "#{client_tty} #{session_id} #{client_activity} #{client_pid}"

    public static func tmuxPane(listing: String, tty raw: String) -> TmuxPane? {
        guard let tty = normalizedTTY(raw) else { return nil }
        for line in listing.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 4, f[0] == "/dev/\(tty)" else { continue }
            return TmuxPane(session: f[1], window: f[2], pane: f[3])
        }
        return nil
    }

    public static func tmuxClients(listing: String) -> [TmuxClient] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 4, let tty = normalizedTTY(f[0]) else { return nil }
            return TmuxClient(tty: tty, session: f[1], activity: Int(f[2]) ?? 0, pid: Int32(f[3]) ?? 0)
        }
    }

    public static func bestClient(_ clients: [TmuxClient], session: String) -> (client: TmuxClient, needsSwitch: Bool)? {
        let byActivity = clients.sorted { $0.activity > $1.activity }
        if let c = byActivity.first(where: { $0.session == session }) { return (c, false) }
        return byActivity.first.map { ($0, true) }
    }

    public static func tmuxSocketArgs(serverArgs: [String]) -> [String] {
        var out: [String] = []
        var i = 1
        while i < serverArgs.count {
            let a = serverArgs[i]
            if (a == "-L" || a == "-S"), i + 1 < serverArgs.count {
                out = [a, serverArgs[i + 1]]
                i += 2
                continue
            }
            if !a.hasPrefix("-") { break }
            i += ["-f", "-c", "-T"].contains(a) ? 2 : 1
        }
        return out
    }
}

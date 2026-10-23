import Darwin
import EarshotCore
import Foundation

signal(SIGPIPE, SIG_IGN)


func hookCommand() -> String {
    let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

SocketClient.acceptPeer = PeerTrust.earshotApp(hookPath: hookCommand(), env: ProcessInfo.processInfo.environment)

func appVersion() -> String {
    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
    var dir = URL(fileURLWithPath: hookCommand()).deletingLastPathComponent()
    for _ in 0..<3 {
        let plist = dir.appendingPathComponent("Info.plist")
        if let d = NSDictionary(contentsOf: plist), let v = d["CFBundleShortVersionString"] as? String { return v }
        dir = dir.deletingLastPathComponent()
    }
    return "unknown (not inside Earshot.app)"
}

func say(_ s: String, to h: FileHandle = .standardOutput) {
    try? h.write(contentsOf: Data((s + "\n").utf8))
}

func admin(_ body: () throws -> String) -> Never {
    do {
        say(try body())
        exit(0)
    } catch {
        say("earshot-hook: \(error)", to: .standardError)
        exit(1)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "--version":
    admin { appVersion() }
case "--install":
    admin {
        let cmd = hookCommand()
        try HooksInstaller.install(hookCommand: cmd)
        return "installed hooks for \(cmd)"
    }
case "--uninstall":
    admin {
        try HooksInstaller.uninstall()
        return "removed Earshot hooks"
    }
case "--list":
    admin {
        let msg = WireMessage(kind: .query, pid: 0, tty: nil, term: nil, payload: .null)
        guard FileManager.default.fileExists(atPath: Paths.socket.path),
              let data = try? SocketClient.send(try Wire.line(msg), to: Paths.socket, awaitReply: true),
              let rows = try? JSONDecoder().decode([SessionSnapshot].self, from: data)
        else { return "Earshot is not running" }
        return SessionTable.render(rows)
    }
case "--simulate":
    admin {
        let kinds = ["memory", "memory-critical", "jump", "finished", "approval", "blocked", "burst"]
        guard let what = CommandLine.arguments.dropFirst(2).first, kinds.contains(what) else {
            return "usage: earshot-hook --simulate " + kinds.joined(separator: "|")
        }
        guard FileManager.default.fileExists(atPath: Paths.socket.path) else { return "Earshot is not running" }
        let msg = WireMessage(kind: .debug, pid: 0, tty: nil, term: nil, payload: .object(["simulate": .string(what)]))
        _ = try SocketClient.send(try Wire.line(msg), to: Paths.socket, awaitReply: false)
        return "sent \(what)"
    }
case "--status":
    admin { "\(HooksInstaller.status(hookCommand: hookCommand()))" }
default:
    let input: Data = isatty(STDIN_FILENO) == 1 ? Data() : ((try? FileHandle.standardInput.readToEnd()) ?? nil) ?? Data()
    let out = HookRunner.run(
        stdin: input,
        env: ProcessInfo.processInfo.environment,
        ancestor: Proc.claudeAncestor(from: getppid()),
        socket: Paths.socket,
        policyURL: PolicyStore.defaultURL)
    if let out { try? FileHandle.standardOutput.write(contentsOf: out) }
    exit(0)
}

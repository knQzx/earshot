import AppKit
import EarshotCore
import Foundation

final class TerminalJumper: TerminalJumping {
    private let queue = DispatchQueue(label: "io.github.knqzx.earshot.jump", qos: .userInitiated)
    private static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    func jump(to session: Session, done: @escaping (JumpProblem?) -> Void) {
        let pid = session.pid
        let known = session.tty
        let viaTmux = session.term == "tmux"
        queue.async {
            let tty = JumpScript.normalizedTTY(known ?? (pid > 0 ? Proc.info(pid)?.tty : nil))
            done(Self.jump(pid: pid, tty: tty, termIsTmux: viaTmux))
        }
    }

    private enum ScriptResult {
        case found, missing, denied, failed
    }

    private static func jump(pid: Int32, tty: String?, termIsTmux: Bool) -> JumpProblem? {
        let tmuxServer = pid > 0 ? ancestor(of: pid, comm: "tmux") : nil
        if let tty, tmuxServer != nil || termIsTmux, let handled = jumpTmux(tty: tty, server: tmuxServer) { return handled }
        return focus(tty: tty, hostPid: pid > 0 ? pid : nil)
    }

    private static func focus(tty: String?, hostPid: Int32?) -> JumpProblem? {
        if let hostPid, let host = hostApp(of: hostPid) {
            var problem: JumpProblem?
            if let tty, let script = script(for: host.bundleID, tty: tty) {
                switch run(script) {
                case .found: return nil
                case .missing: break
                case .denied: problem = JumpProblem(app: host.name, denied: true)
                case .failed: problem = JumpProblem(app: host.name, denied: false)
                }
            }
            if let app = host.app { activate(app) }
            return problem
        }
        guard let tty else { return nil }
        for (id, name) in [(JumpScript.terminalBundleID, "Terminal"), (JumpScript.iTermBundleID, "iTerm")] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                  let script = script(for: id, tty: tty) else { continue }
            switch run(script) {
            case .found: return nil
            case .missing: continue
            case .denied, .failed:
                activate(app)
                return JumpProblem(app: name, denied: true)
            }
        }
        return nil
    }

    private static func script(for bundleID: String?, tty: String) -> String? {
        switch bundleID {
        case JumpScript.terminalBundleID: return JumpScript.terminal(tty: tty)
        case JumpScript.iTermBundleID: return JumpScript.iTerm(tty: tty)
        default: return nil
        }
    }

    private static func jumpTmux(tty: String, server: Int32?) -> JumpProblem?? {
        let serverPath = server.flatMap { Proc.path($0) }
        guard let bin = ([serverPath].compactMap { $0 } + tmuxPaths).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let socket = server.map { JumpScript.tmuxSocketArgs(serverArgs: Proc.args($0)) } ?? []
        func tmux(_ args: [String]) -> String? { exec(bin, socket + args) }

        guard let panes = tmux(["list-panes", "-a", "-F", JumpScript.tmuxPaneFormat]),
              let pane = JumpScript.tmuxPane(listing: panes, tty: tty) else { return nil }
        _ = tmux(["select-window", "-t", pane.window])
        _ = tmux(["select-pane", "-t", pane.pane])

        guard let clients = tmux(["list-clients", "-F", JumpScript.tmuxClientFormat]),
              let best = JumpScript.bestClient(JumpScript.tmuxClients(listing: clients), session: pane.session) else { return .some(nil) }
        if best.needsSwitch {
            _ = tmux(["switch-client", "-c", "/dev/" + best.client.tty, "-t", pane.session])
        }
        return .some(focus(tty: best.client.tty, hostPid: best.client.pid > 0 ? best.client.pid : nil))
    }

    private static func ancestor(of pid: Int32, comm: String) -> Int32? {
        var cur = pid
        for _ in 0..<24 {
            guard cur > 1, let i = Proc.info(cur) else { return nil }
            if i.comm == comm { return cur }
            cur = i.ppid
        }
        return nil
    }

    private static func hostApp(of pid: Int32) -> (bundleID: String?, name: String, app: NSRunningApplication?)? {
        guard let found = Proc.appAncestor(from: pid) else { return nil }
        var bundle = found.bundlePath
        if let r = (bundle + "/").range(of: ".app/") {
            bundle = String(bundle[..<r.lowerBound]) + ".app"
        }
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == bundle }
            ?? NSRunningApplication(processIdentifier: found.pid)
        let name = app?.localizedName ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        return (app?.bundleIdentifier ?? Bundle(path: bundle)?.bundleIdentifier, name, app)
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func activate(_ app: NSRunningApplication) {
        DispatchQueue.main.async {
            if app.isHidden { app.unhide() }
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    private static func run(_ source: String) -> ScriptResult {
        if Thread.isMainThread { return runOnMain(source) }
        return DispatchQueue.main.sync { runOnMain(source) }
    }

    private static func runOnMain(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else { return .failed }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            return code == -1743 || code == -1744 ? .denied : .failed
        }
        return out.stringValue == "found" ? .found : .missing
    }

    private static func exec(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import AppKit
import Combine
import EarshotCore

extension SocketServer: EventSource {}

enum LaunchMode: Equatable {
    case normal
    #if DEBUG
    case trace(NotchController.TraceKind)
    #endif
    case snapshot(String)

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "--snapshot") {
            self = .snapshot(i + 1 < arguments.count ? arguments[i + 1] : "snapshots")
            return
        }
        #if DEBUG
        if arguments.contains("--trace-hover") {
            self = .trace(.hover)
        } else if arguments.contains("--trace-panel") {
            self = .trace(.panel)
        } else if arguments.contains("--trace-stack") {
            self = .trace(.stack)
        } else if arguments.contains("--trace-finished") {
            self = .trace(.finished)
        } else if arguments.contains("--trace-approval") {
            self = .trace(.approval)
        } else {
            self = .normal
        }
        #else
        self = .normal
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: LaunchMode
    private let prefs = Preferences()
    private var model: AppModel?
    private var notch: NotchController?
    private var sounds: Sounds?
    private var settings: SettingsWindow?
    private var hotKey: HotKey?
    private var bag = Set<AnyCancellable>()

    init(mode: LaunchMode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case .snapshot(let dir):
            Snapshotter.run(into: URL(fileURLWithPath: dir))
            exit(0)
        #if DEBUG
        case .trace:
            launch(source: SampleSource(), scanner: SampleScanner(), jumper: SampleJumper(), hooks: .simulated(.notInstalled), samples: true)
        #endif
        case .normal:
            launch(source: SocketServer(), scanner: ProcessScanner(), jumper: TerminalJumper(), hooks: .live(), samples: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    private func launch(source: EventSource, scanner: ProcessScanning, jumper: TerminalJumping, hooks: HookControl, samples: Bool) {
        let model = samples
            ? AppModel(source: source, scanner: scanner, jumper: jumper, groupsURL: nil, policyURL: nil)
            : AppModel(source: source, scanner: scanner, jumper: jumper)
        self.model = model
        if samples {
            model.stallAfter = SampleSource.stallAfter
        } else {
            prefs.$stallMinutes
                .sink { m in MainActor.assumeIsolated { model.stallAfter = TimeInterval(m * 60) } }
                .store(in: &bag)
        }
        do {
            try model.start()
        } catch {
            FileHandle.standardError.write(Data("Earshot: \(error.localizedDescription)\n".utf8))
            self.model = nil
            NSApp.terminate(nil)
            return
        }
        if samples { SampleAgent.seedGroups(model) }

        let sounds = Sounds(prefs: prefs)
        let notch = NotchController(model: model, prefs: prefs, hooks: hooks)
        let settings = SettingsWindow(prefs: prefs, policy: PolicySettings(url: model.policyURL))
        notch.onOpenSettings = { [weak settings] in settings?.show() }
        #if DEBUG
        if case .trace(let kind) = mode {
            self.notch = notch
            var agents = [SampleAgent.notch, SampleAgent.billing]
            model.onFinished = { [weak notch] s in notch?.sessionFinished(s) }
            model.onSimulateFinished = { [weak notch] s in notch?.simulateFinished(s) }
            model.onBlocked = { [weak notch] s, rule, command in notch?.blockedArrived(s, rule: rule, command: command ?? "") }
            notch.runTrace(kind) { command in
                guard let fake = source as? SampleSource else { return }
                if command.hasPrefix("sim:") {
                    fake.send(WireMessage(kind: .debug, pid: 0, tty: nil, term: nil, payload: .object(["simulate": .string(String(command.dropFirst(4)))])))
                    return
                }
                let named: [String: SampleAgent] = ["auth": .auth, "infra": .infra]
                if command == "request", !agents.isEmpty {
                    let agent = agents.removeFirst()
                    let fields = SamplePayload.permission(["command": "rm -rf build && make app", "description": "Rebuild the app bundle"], rule: "make app")
                    fake.send(agent.message("PermissionRequest", fields, request: true), requestID: UUID())
                } else if command.hasPrefix("stop:"), let a = named[String(command.dropFirst(5))] {
                    fake.send(a.message("Stop", SamplePayload.stop("All 48 tests pass. The flaky retry came from a shared temp dir.")))
                } else if command.hasPrefix("prompt:"), let a = named[String(command.dropFirst(7))] {
                    fake.send(a.message("UserPromptSubmit", SamplePayload.prompt("One more pass")))
                }
            }
            return
        }
        #endif
        model.onRequestAdded = { [weak notch, weak sounds] item in
            sounds?.permissionRequested()
            notch?.requestAdded(item)
        }
        model.onStatusChange = { [weak notch] session, status in
            notch?.statusChanged(session, status)
        }
        model.onSimulateFinished = { [weak notch] session in notch?.simulateFinished(session) }
        model.onBlocked = { [weak notch] session, rule, command in notch?.blockedArrived(session, rule: rule, command: command ?? "") }
        model.onFinished = { [weak notch, weak sounds] session in
            sounds?.sessionWaiting()
            notch?.sessionFinished(session)
        }
        hotKey = HotKey.panelToggle { [weak notch] in
            MainActor.assumeIsolated { notch?.toggle() }
        }
        self.sounds = sounds
        self.notch = notch
        self.settings = settings
    }
}

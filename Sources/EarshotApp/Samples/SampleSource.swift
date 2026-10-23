import EarshotCore
import Foundation

struct SampleAgent {
    let pid: Int32
    let session: String
    let cwd: String
    let tty: String

    static let notch = SampleAgent(pid: 91001, session: "d1", cwd: "/Users/you/code/web-app", tty: "ttys001")
    static let billing = SampleAgent(pid: 91002, session: "d2", cwd: "/Users/you/work/billing-service", tty: "ttys002")
    static let auth = SampleAgent(pid: 91003, session: "d3", cwd: "/Users/you/oss/auth-service", tty: "ttys003")
    static let blog = SampleAgent(pid: 91004, session: "d4", cwd: "/Users/you/code/mobile-app", tty: "ttys004")
    static let infra = SampleAgent(pid: 91005, session: "d5", cwd: "/Users/you/study/docs-site", tty: "ttys005")
    static let dotfiles = SampleAgent(pid: 91006, session: "d6", cwd: "/Users/you/code/notes-app", tty: "ttys006")

    static let all = [notch, billing, auth, blog, infra, dotfiles]

    func message(_ event: String, _ fields: [String: JSONValue] = [:], request: Bool = false) -> WireMessage {
        var p: [String: JSONValue] = [
            "hook_event_name": .string(event),
            "session_id": .string(session),
            "cwd": .string(cwd),
        ]
        p.merge(fields) { $1 }
        return WireMessage(kind: request ? .request : .event, pid: pid, tty: tty, term: "Apple_Terminal", payload: .object(p))
    }
}

extension SampleAgent {
    @MainActor
    static func seedGroups(_ model: AppModel) {
        let plan: [(String, GroupColor, [SampleAgent])] = [
            ("Work", .blue, [.notch, .billing]),
            ("Open Source", .mint, [.auth, .blog]),
            ("Study", .purple, [.infra]),
        ]
        for (name, color, agents) in plan {
            let id = model.newGroup(name: name, color: color)
            for a in agents {
                if let s = model.session(withID: SessionStore.key(pid: a.pid, sessionID: nil)) { model.move(s, to: id) }
            }
        }
    }
}

enum SamplePayload {
    static func prompt(_ text: String) -> [String: JSONValue] { ["prompt": .string(text)] }

    static func tool(_ name: String, _ input: [String: String]) -> [String: JSONValue] {
        ["tool_name": .string(name), "tool_input": .object(input.mapValues { .string($0) })]
    }

    static func stop(_ text: String) -> [String: JSONValue] { ["last_assistant_message": .string(text)] }

    static func question(_ q: String) -> [String: JSONValue] {
        ["tool_name": .string("AskUserQuestion"),
         "tool_input": .object(["questions": .array([.object(["question": .string(q)])])])]
    }

    static let cleanBuild = ["command": "rm -rf .build && swift build -c release", "description": "Clean release build"]

    static func permission(_ input: [String: String], rule: String) -> [String: JSONValue] {
        var f = tool("Bash", input)
        f["permission_suggestions"] = .array([.object([
            "type": .string("addRules"),
            "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string(rule)])]),
            "behavior": .string("allow"),
            "destination": .string("localSettings"),
        ])])
        return f
    }
}

final class SampleSource: EventSource {
    static let stallAfter: TimeInterval = 20
    static let period: TimeInterval = 54

    var onMessage: ((WireMessage, UUID?) -> Void)?
    var onRequestClosed: ((UUID) -> Void)?

    private struct Step {
        var at: TimeInterval
        var agent: SampleAgent
        var event: String
        var fields: [String: JSONValue] = [:]
        var request = false
    }

    private let scripted: Bool
    private var timer: Timer?
    private var index = 0
    private var cycleStart = Date()
    private var labels: [UUID: String] = [:]

    init(scripted: Bool = true) {
        self.scripted = scripted
    }

    func start() throws {
        guard scripted else { return }
        for step in Self.setup { emit(step) }
        cycleStart = Date()
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reply(_ requestID: UUID, _ reply: Reply) {
        guard scripted else { return }
        let label = labels.removeValue(forKey: requestID) ?? requestID.uuidString
        print("[sample] \(label) -> \(reply.decision.rawValue)")
        fflush(stdout)
    }

    func send(_ message: WireMessage, requestID: UUID? = nil) {
        onMessage?(message, requestID)
    }

    private func emit(_ step: Step) {
        let m = step.agent.message(step.event, step.fields, request: step.request)
        var id: UUID?
        if step.request {
            let rid = UUID()
            let summary = ToolSummary(tool: step.fields["tool_name"]?.string ?? "?", input: step.fields["tool_input"])
            labels[rid] = "\(step.agent.cwd.split(separator: "/").last ?? "") \(summary.short)"
            print("[sample] permission request: \(labels[rid] ?? "")")
            fflush(stdout)
            id = rid
        }
        onMessage?(m, id)
    }

    private func scheduleNext() {
        let fire = cycleStart.addingTimeInterval(Self.cycle[index].at)
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(cycleStart)
        while index < Self.cycle.count, Self.cycle[index].at <= elapsed + 0.05 {
            emit(Self.cycle[index])
            index += 1
        }
        if index >= Self.cycle.count {
            index = 0
            cycleStart = cycleStart.addingTimeInterval(Self.period)
        }
        scheduleNext()
    }

    private static let setup: [Step] = SampleAgent.all.map { Step(at: 0, agent: $0, event: "SessionStart") } + [
        Step(at: 0, agent: .notch, event: "UserPromptSubmit", fields: SamplePayload.prompt("Make the notch panel spring open like the Dynamic Island")),
        Step(at: 0, agent: .billing, event: "UserPromptSubmit", fields: SamplePayload.prompt("Fix the flaky retry test in invoice sync")),
        Step(at: 0, agent: .infra, event: "UserPromptSubmit", fields: SamplePayload.prompt("Bump the AWS provider to 6.x and run a plan")),
    ]

    private static let cycle: [Step] = {
        let readIsland = SamplePayload.tool("Read", ["file_path": "/Users/you/code/web-app/Sources/EarshotApp/Views/IslandView.swift"])
        let editIsland = SamplePayload.tool("Edit", ["file_path": "/Users/you/code/web-app/Sources/EarshotApp/Views/IslandView.swift"])
        let editDot = SamplePayload.tool("Edit", ["file_path": "/Users/you/code/web-app/Sources/EarshotApp/Views/SessionRow.swift"])
        let buildNotch = SamplePayload.tool("Bash", ["command": "swift build", "description": "Build the app"])
        let testBilling = SamplePayload.tool("Bash", ["command": "swift test --filter InvoiceSyncTests", "description": "Run invoice sync tests"])
        let cleanBuild = SamplePayload.tool("Bash", SamplePayload.cleanBuild)
        let grepSlots = SamplePayload.tool("Grep", ["pattern": "clusterGenNodesSlotsInfo", "path": "src"])
        let readCluster = SamplePayload.tool("Read", ["file_path": "/Users/you/oss/auth-service/src/cluster.c"])
        let plan = SamplePayload.tool("Bash", ["command": "terraform plan -out tfplan", "description": "Plan provider upgrade"])
        let question = SamplePayload.question("Should the post also cover abstract sockets on Linux?")
        let writePost = SamplePayload.tool("Write", ["file_path": "/Users/you/code/mobile-app/posts/unix-socket-permissions.md"])
        return [
            Step(at: 0.5, agent: .notch, event: "PreToolUse", fields: readIsland),
            Step(at: 1.0, agent: .billing, event: "PreToolUse", fields: testBilling),
            Step(at: 1.5, agent: .auth, event: "UserPromptSubmit", fields: SamplePayload.prompt("Why did CLUSTER SLOTS get slower after the 8.1 upgrade?")),
            Step(at: 2.0, agent: .auth, event: "PreToolUse", fields: grepSlots),
            Step(at: 2.5, agent: .infra, event: "PreToolUse", fields: plan),
            Step(at: 3.0, agent: .blog, event: "UserPromptSubmit", fields: SamplePayload.prompt("Draft a post about unix socket permissions")),
            Step(at: 4.0, agent: .notch, event: "PostToolUse", fields: readIsland),
            Step(at: 4.2, agent: .notch, event: "PreToolUse", fields: editIsland),
            Step(at: 6.0, agent: .billing, event: "PostToolUse", fields: testBilling),
            Step(at: 7.0, agent: .billing, event: "PermissionRequest",
                 fields: SamplePayload.permission(SamplePayload.cleanBuild, rule: "swift build:*"), request: true),
            Step(at: 9.0, agent: .blog, event: "PreToolUse", fields: question),
            Step(at: 11.0, agent: .notch, event: "PostToolUse", fields: editIsland),
            Step(at: 11.2, agent: .notch, event: "PreToolUse", fields: buildNotch),
            Step(at: 14.0, agent: .infra, event: "StopFailure", fields: ["error": .string("Rate limit reached. Try again in 2 minutes.")]),
            Step(at: 16.0, agent: .notch, event: "PostToolUse", fields: buildNotch),
            Step(at: 16.2, agent: .notch, event: "Stop",
                 fields: SamplePayload.stop("Done. The panel now springs out of the notch and closes when the mouse leaves.")),
            Step(at: 20.0, agent: .billing, event: "PostToolUse", fields: cleanBuild),
            Step(at: 21.0, agent: .billing, event: "PreToolUse", fields: testBilling),
            Step(at: 23.0, agent: .blog, event: "PostToolUse", fields: question),
            Step(at: 23.2, agent: .blog, event: "PreToolUse", fields: writePost),
            Step(at: 27.0, agent: .billing, event: "PostToolUse", fields: testBilling),
            Step(at: 27.2, agent: .billing, event: "Stop", fields: SamplePayload.stop("All 48 invoice sync tests pass. The flake came from a shared temp dir.")),
            Step(at: 31.0, agent: .notch, event: "UserPromptSubmit", fields: SamplePayload.prompt("Now add a small hop when a session finishes")),
            Step(at: 32.0, agent: .notch, event: "PreToolUse", fields: editDot),
            Step(at: 34.0, agent: .blog, event: "PostToolUse", fields: writePost),
            Step(at: 34.2, agent: .blog, event: "Stop", fields: SamplePayload.stop("Draft saved to posts/unix-socket-permissions.md, about 1,200 words.")),
            Step(at: 38.0, agent: .infra, event: "UserPromptSubmit", fields: SamplePayload.prompt("Retry the plan")),
            Step(at: 39.0, agent: .infra, event: "PreToolUse", fields: plan),
            Step(at: 44.0, agent: .infra, event: "PostToolUse", fields: plan),
            Step(at: 44.2, agent: .infra, event: "Stop", fields: SamplePayload.stop("Plan: 3 to change, 0 to add, 0 to destroy.")),
            Step(at: 46.0, agent: .billing, event: "UserPromptSubmit", fields: SamplePayload.prompt("Ship it: bump the version and tag")),
            Step(at: 48.0, agent: .auth, event: "PostToolUse", fields: grepSlots),
            Step(at: 48.2, agent: .auth, event: "PreToolUse", fields: readCluster),
            Step(at: 50.0, agent: .notch, event: "PostToolUse", fields: editDot),
        ]
    }()
}

import AppKit
import EarshotCore
import Foundation

struct MissedItem: Identifiable, Equatable {
    enum Kind: Equatable { case finished, memory, blocked }

    var id = UUID()
    var kind: Kind
    var sessionID: String?
    var text: String
    var at = Date()

    var action: String { kind == .blocked ? "Details" : "Open" }
}

struct BlockedCommand: Identifiable, Equatable {
    let id = UUID()
    var session: Session
    var rule: String
    var command: String?
    var at: Date
}

struct RequestItem: Identifiable, Equatable {
    var session: Session
    var request: PendingRequest
    var simulated = false
    var id: UUID { request.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var requests: [RequestItem] = []
    @Published private(set) var now = Date()
    @Published private(set) var groups = GroupStore()
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var jumpProblem: JumpProblem?
    @Published private(set) var memoryAlert: MemoryAlert?
    private(set) var memoryAlertSimulated = false
    private(set) var simulating = false
    @Published private(set) var missed: [MissedItem] = []
    @Published private(set) var lastBlocked: BlockedCommand?
    var onBlocked: ((Session, String, String?) -> Void)?

    var stallAfter: TimeInterval = SessionStore.stallAfter
    var onRequestAdded: ((RequestItem) -> Void)?
    var onStatusChange: ((Session, DisplayStatus) -> Void)?
    var onFinished: ((Session) -> Void)?
    var onSimulateFinished: ((Session) -> Void)?

    private var store = SessionStore()
    private let groupsURL: URL?
    let policyURL: URL?
    private let sampler = UsageSampler()
    private let usageQueue = DispatchQueue(label: "io.github.knqzx.earshot.usage", qos: .utility)
    private var usageTimer: Timer?
    private let source: EventSource
    private let scanner: ProcessScanning
    private let jumper: TerminalJumping
    private var timer: Timer?
    private var lastDisplay: [String: DisplayStatus] = [:]
    private var memoryWatch = MemoryWatch()
    private var memoryTimer: Timer?
    private var simulatedRequest: RequestItem?

    init(source: EventSource, scanner: ProcessScanning, jumper: TerminalJumping, groupsURL: URL? = GroupStore.defaultURL,
         policyURL: URL? = PolicyStore.defaultURL) {
        self.source = source
        self.scanner = scanner
        self.jumper = jumper
        self.groupsURL = groupsURL
        self.policyURL = policyURL
        if let groupsURL { groups = GroupStore.load(from: groupsURL) }
    }

    var sections: [(group: SessionGroup?, sessions: [Session])] {
        groups.sections(sessions)
    }

    func group(for s: Session) -> SessionGroup? {
        groups.group(for: s)
    }

    func group(withID id: UUID) -> SessionGroup? {
        groups.index(of: id).map { groups.groups[$0] }
    }

    func session(withID id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    @discardableResult
    func groupTogether(_ dragged: Session, onto target: Session) -> UUID? {
        guard dragged.id != target.id else { return nil }
        if let g = groups.group(for: target) {
            editGroups { $0.add(dragged, to: g.id) }
            return g.id
        }
        var id: UUID?
        editGroups { id = $0.create(with: target, dragged) }
        return id
    }

    func move(_ s: Session, to groupID: UUID?) {
        editGroups { g in
            if let groupID { g.add(s, to: groupID) } else { g.remove(s) }
        }
    }

    @discardableResult
    func newGroup(name: String? = nil, color: GroupColor? = nil) -> UUID {
        var id = UUID()
        editGroups { id = $0.create(name: name, color: color) }
        return id
    }

    func renameGroup(_ id: UUID, _ name: String) { editGroups { $0.rename(id, to: name) } }
    func recolorGroup(_ id: UUID, _ color: GroupColor) { editGroups { $0.recolor(id, to: color) } }
    func toggleGroup(_ id: UUID) { editGroups { $0.toggleCollapsed(id) } }
    func deleteGroup(_ id: UUID) { editGroups { $0.delete(id) } }

    private func editGroups(_ body: (inout GroupStore) -> Void) {
        var g = groups
        body(&g)
        guard g != groups else { return }
        groups = g
        if let groupsURL { try? g.save(to: groupsURL) }
    }

    func start() throws {
        source.onMessage = { [weak self] m, id in
            MainActor.assumeIsolated { self?.ingest(m, requestID: id) }
        }
        source.onRequestClosed = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.requestClosed(id, now: Date())
                self.publish()
            }
        }
        if let server = source as? SocketServer {
            server.onQuery = { [weak self] in
                MainActor.assumeIsolated { self?.snapshotJSON() }
            }
        }
        if let policyURL { _ = try? PolicyStore.ensureDefaults(at: policyURL) }
        try source.start()
        rescan()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let m = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMemory() }
        }
        m.tolerance = 2
        RunLoop.main.add(m, forMode: .common)
        memoryTimer = m
    }

    private func checkMemory() {
        usageQueue.async {
            let signals = MemorySignals.read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if signals.pressure == .normal, signals.swapFraction < MemoryWatch.swapClear {
                        self.missed.removeAll { $0.kind == .memory }
                    }
                    guard let level = self.memoryWatch.evaluate(signals) else { return }
                    self.raiseMemoryAlert(level)
                }
            }
        }
    }

    private func raiseMemoryAlert(_ level: MemoryAlertLevel, simulated: Bool = false) {
        let pids = sessions.map(\.pid).filter { $0 > 0 }
        let sampler = self.sampler
        usageQueue.async {
            let alert = MemoryWatch.alert(level: level, sessionPIDs: pids, sampler: sampler)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.memoryAlertSimulated = simulated
                    self?.memoryAlert = alert
                }
            }
        }
    }

    func dismissMemoryAlert() {
        memoryAlert = nil
    }

    func addMissed(_ item: MissedItem) {
        missed.insert(item, at: 0)
        if missed.count > 20 { missed.removeLast(missed.count - 20) }
    }

    func removeMissed(_ id: UUID) {
        missed.removeAll { $0.id == id }
    }

    func clearMissed() {
        missed = []
    }

    @discardableResult
    func stopProcess(_ pid: Int32) -> Bool {
        let pids = sessions.map(\.pid).filter { $0 > 0 }
        guard let child = memoryAlert?.top.lazy.flatMap(\.children).first(where: { $0.pid == pid }),
              MemoryWatch.stillSame(child),
              MemoryWatch.isStoppable(pid, sessionPIDs: pids),
              kill(pid, SIGTERM) == 0 else { return false }
        if var alert = memoryAlert {
            for i in alert.top.indices {
                if let c = alert.top[i].children.first(where: { $0.pid == pid }) {
                    alert.top[i].children.removeAll { $0.pid == pid }
                    alert.top[i].rss = alert.top[i].rss > c.rss ? alert.top[i].rss - c.rss : 0
                }
            }
            memoryAlert = alert
        }
        return true
    }

    private var newestSession: Session? {
        sessions.max { $0.startedAt < $1.startedAt }
    }

    private func simulate(_ what: String) {
        simulating = true
        defer { simulating = false }
        switch what {
        case "memory": raiseMemoryAlert(.warning, simulated: true)
        case "memory-critical": raiseMemoryAlert(.critical, simulated: true)
        case "jump":
            jumpProblem = JumpProblem(app: newestSession?.term ?? "Terminal", denied: true)
        case "finished":
            if let s = newestSession { onSimulateFinished?(s) }
        case "approval":
            guard let s = newestSession, let item = fakeRequest(for: s) else { return }
            simulatedRequest = item
            publish()
            onRequestAdded?(item)
        case "blocked":
            if let s = newestSession {
                lastBlocked = BlockedCommand(session: s, rule: "No force push", command: "git push --force origin main", at: Date())
                onBlocked?(s, "No force push", "git push --force origin main")
            }
        case "burst":
            let steps = ["approval", "finished", "memory", "blocked"]
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { [weak self] in
                    MainActor.assumeIsolated { self?.simulate(step) }
                }
            }
        default:
            break
        }
    }

    private func fakeRequest(for s: Session) -> RequestItem? {
        var scratch = SessionStore()
        let payload: JSONValue = .object([
            "hook_event_name": .string("PermissionRequest"),
            "session_id": .string(s.sessionID ?? "simulated"),
            "cwd": .string(s.cwd),
            "tool_name": .string("Bash"),
            "tool_input": .object([
                "command": .string("echo simulated request"),
                "description": .string("Simulated by earshot-hook --simulate, never sent to Claude"),
            ]),
        ])
        let m = WireMessage(kind: .request, pid: s.pid, tty: s.tty, term: s.term, payload: payload)
        scratch.ingest(m, requestID: UUID(), now: Date())
        guard let r = scratch.pendingQueue.first?.request else { return nil }
        return RequestItem(session: s, request: r, simulated: true)
    }

    var usageVisible: Bool { usageTimer != nil }

    func setUsageVisible(_ on: Bool) {
        guard on != usageVisible else { return }
        usageTimer?.invalidate()
        usageTimer = nil
        guard on else { return }
        sampleUsage()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleUsage() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        usageTimer = t
    }

    func usage(for s: Session) -> ProcessUsage? {
        usage?.perSession[s.pid]
    }

    private func sampleUsage() {
        let pids = sessions.map(\.pid).filter { $0 > 0 }
        let sampler = self.sampler
        usageQueue.async {
            let snap = sampler.sample(claudePIDs: pids)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.usageVisible else { return }
                    self.usage = snap
                }
            }
        }
    }

    func stop() {
        setUsageVisible(false)
        memoryTimer?.invalidate()
        memoryTimer = nil
        timer?.invalidate()
        timer = nil
        for r in requests { source.reply(r.id, .pass) }
        source.stop()
    }

    func decide(_ requestID: UUID, _ decision: Decision) {
        if simulatedRequest?.id == requestID {
            simulatedRequest = nil
            publish()
            return
        }
        apply(store.resolve(requestID: requestID, reply: Reply(decision, message: decision == .deny ? "Denied from Earshot" : nil), now: Date()))
        publish()
    }

    func jump(to session: Session) {
        store.markSeen(id: session.id, now: Date())
        publish()
        jumper.jump(to: session) { [weak self] problem in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.jumpProblem = problem }
            }
        }
    }

    func dismissJumpProblem() {
        jumpProblem = nil
    }

    func openAutomationSettings() {
        jumpProblem = nil
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }


    func display(_ s: Session) -> DisplayStatus {
        s.display(now: now, stallAfter: stallAfter)
    }

    func snapshotJSON() -> Data? {
        let t = Date()
        return try? JSONEncoder().encode(sessions.map { SessionSnapshot($0, display: $0.display(now: t, stallAfter: stallAfter), now: t) })
    }

    private func ingest(_ m: WireMessage, requestID: UUID?) {
        if m.kind == .debug {
            if let what = m.payload["simulate"]?.string { simulate(what) }
            return
        }
        let before = Set(store.pendingQueue.map { $0.request.id })
        apply(store.ingest(m, requestID: requestID, now: Date()))
        publish()
        for r in requests where !before.contains(r.id) { onRequestAdded?(r) }
    }

    private func rescan() {
        scanner.scan { [weak self] procs in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.store.sync(processes: procs, isAlive: self.scanner.isAlive, now: Date()))
                self.publish()
                var g = self.groups
                g.prune(live: self.sessions)
                if g != self.groups { self.editGroups { $0 = g } }
            }
        }
    }

    private func apply(_ effects: [StoreEffect]) {
        for case let .reply(id, r) in effects { source.reply(id, r) }
        for case let .blocked(key, match) in effects {
            guard let s = store.sessions[key] else { continue }
            lastBlocked = BlockedCommand(session: s, rule: match.label, command: match.command, at: Date())
            onBlocked?(s, match.label, match.command)
        }
    }

    func dismissBlocked() {
        lastBlocked = nil
    }

    private func publish() {
        let t = Date()
        now = t
        let ordered = store.ordered(now: t)
        var reqs = store.pendingQueue.map { RequestItem(session: $0.session, request: $0.request) }
        if var sim = simulatedRequest {
            if let live = ordered.first(where: { $0.id == sim.session.id }) {
                sim.session = live
                simulatedRequest = sim
                reqs.append(sim)
            } else {
                simulatedRequest = nil
            }
        }
        if ordered != sessions { sessions = ordered }
        if reqs != requests { requests = reqs }
        var next: [String: DisplayStatus] = [:]
        for s in ordered {
            let d = s.display(now: t, stallAfter: stallAfter)
            next[s.id] = d
            if let prev = lastDisplay[s.id], prev != d {
                onStatusChange?(s, d)
                if FinishRule.fires(from: prev, to: d, session: s) { onFinished?(s) }
            }
        }
        lastDisplay = next
        let stale = missed.filter { m in
            guard m.kind == .finished, let id = m.sessionID else { return false }
            guard let s = ordered.first(where: { $0.id == id }) else { return true }
            let d = next[id]
            return !s.unseen || d == .working || d == .permission || d == .question
        }
        if !stale.isEmpty {
            let ids = Set(stale.map(\.id))
            missed.removeAll { ids.contains($0.id) }
        }
    }
}

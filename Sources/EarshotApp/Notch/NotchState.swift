import EarshotCore
import SwiftUI

struct SessionInfo: Identifiable, Equatable {
    var session: Session
    var display: DisplayStatus
    var group: SessionGroup?

    var id: String { session.id }
    var needsYou: Bool { Theme.needsYou(display, unseen: session.unseen) }
    var unseen: Bool { session.unseen }

    func look(onBlack: Bool) -> SparkLook { .of(display, unseen: unseen, onBlack: onBlack) }
}

struct SessionSection: Identifiable, Equatable {
    var group: SessionGroup?
    var items: [SessionInfo]

    var id: String { group?.id.uuidString ?? "ungrouped" }
    var needsYou: Int { items.filter(\.needsYou).count }
}

struct ProcLoad: Equatable {
    var rss: UInt64
    var cpu: Double
}

struct UsageInfo: Equatable {
    var ramUsed: UInt64
    var ramTotal: UInt64
    var compressed: UInt64
    var swapUsed: UInt64
    var pressure: String
    var cpu: Double
    var claude: ProcLoad
    var claudeProcesses: Int
    var perSession: [Int32: ProcLoad]

    init(ramUsed: UInt64, ramTotal: UInt64, compressed: UInt64, swapUsed: UInt64, pressure: String, cpu: Double,
         claude: ProcLoad, claudeProcesses: Int, perSession: [Int32: ProcLoad]) {
        self.ramUsed = ramUsed
        self.ramTotal = ramTotal
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.cpu = cpu
        self.claude = claude
        self.claudeProcesses = claudeProcesses
        self.perSession = perSession
    }

    init(_ s: UsageSnapshot) {
        let pressure: String
        switch s.pressure {
        case .normal: pressure = "normal"
        case .warning: pressure = "elevated"
        case .critical: pressure = "critical"
        }
        self.init(ramUsed: s.ramUsed, ramTotal: s.ramTotal, compressed: s.compressed, swapUsed: s.swapUsed,
                  pressure: pressure, cpu: s.cpu, claude: ProcLoad(rss: s.claude.rss, cpu: s.claude.cpu),
                  claudeProcesses: s.claude.processes,
                  perSession: s.perSession.mapValues { ProcLoad(rss: $0.rss, cpu: $0.cpu) })
    }
}

struct MemoryLine: Equatable {
    var used: UInt64
    var total: UInt64

    var text: String { "\(Self.gb(used)) of \(Self.gb(total, round: true)) GB" }

    static func gb(_ b: UInt64, round: Bool = false) -> String {
        let g = Double(b) / 1_073_741_824
        if round || g >= 10 { return String(format: "%.0f", g) }
        return String(format: "%.1f", g)
    }
}

struct Board: Equatable {
    private(set) var items: [SessionInfo] = []
    private(set) var sections: [SessionSection] = []
    private(set) var requests: [RequestItem] = []
    private(set) var groups = GroupStore()
    var usage: UsageInfo?
    var memory: MemoryLine?

    init() {}

    init(sessions: [Session], requests: [RequestItem], groups: GroupStore, now: Date, stallAfter: TimeInterval = SessionStore.stallAfter) {
        self.requests = requests
        self.groups = groups
        let home = NSHomeDirectory()
        let infos = sessions.map {
            SessionInfo(session: $0, display: $0.display(now: now, stallAfter: stallAfter), group: groups.group(for: $0, home: home))
        }
        items = Self.needsFirst(infos)
        let byID = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
        let raw = groups.sections(sessions, home: home).map { sec in
            SessionSection(group: sec.group, items: Self.needsFirst(sec.sessions.compactMap { byID[$0.id] }))
        }
        let shown = raw.filter { !$0.items.isEmpty }
        sections = shown.filter { $0.needsYou > 0 } + shown.filter { $0.needsYou == 0 }
    }

    var isEmpty: Bool { items.isEmpty }
    var needsYou: Int { items.filter(\.needsYou).count }
    var hasGroups: Bool { sections.contains { $0.group != nil } }

    func info(_ id: String) -> SessionInfo? { items.first { $0.id == id } }

    func group(_ id: UUID) -> SessionGroup? { groups.index(of: id).map { groups.groups[$0] } }

    func groupOf(_ s: Session) -> SessionGroup? { info(s.id)?.group ?? groups.group(for: s) }

    private static func needsFirst(_ xs: [SessionInfo]) -> [SessionInfo] {
        xs.filter(\.needsYou) + xs.filter { !$0.needsYou }
    }
}

enum IslandMode: Equatable {
    case empty
    case ears
    case approval(RequestItem)
    case finished(SessionInfo, Int)
    case memory(MemoryAlert)
    case blocked(BlockedAlert)
}

struct BlockedAlert: Equatable, Identifiable {
    var id = UUID()
    var session: Session
    var rule: String
    var command: String
    var simulated = false
}

enum AlertItem: Equatable, Identifiable {
    case approval(RequestItem)
    case memory(MemoryAlert)
    case blocked(BlockedAlert)
    case finished(SessionInfo)

    var id: String {
        switch self {
        case .approval(let r): return "approval-\(r.id)"
        case .memory: return "memory"
        case .blocked(let b): return "blocked-\(b.id)"
        case .finished(let f): return "finished-\(f.id)"
        }
    }

    var mode: IslandMode {
        switch self {
        case .approval(let r): return .approval(r)
        case .memory(let m): return .memory(m)
        case .blocked(let b): return .blocked(b)
        case .finished(let f): return .finished(f, 0)
        }
    }

    var dwell: TimeInterval? {
        switch self {
        case .approval: return nil
        case .memory: return 12
        case .blocked: return 6
        case .finished: return 8
        }
    }
}

struct NotchActions {
    var toggle: () -> Void = {}
    var expand: () -> Void = {}
    var decide: (UUID, Decision) -> Void = { _, _ in }
    var openTerminal: (Session) -> Void = { _ in }
    var open: (Session) -> Void = { _ in }
    var installHooks: () -> Void = {}
    var showMenu: () -> Void = {}
    var cardAppeared: (UUID) -> Void = { _ in }
    var isArmed: (UUID) -> Bool = { _ in true }
    var contentHeight: (CGFloat) -> Void = { _ in }
    var toggleUsage: () -> Void = {}
    var finishedOpen: (Session) -> Void = { _ in }
    var finishedLater: () -> Void = {}
    var memoryOpen: (Session) -> Void = { _ in }
    var memoryStop: (Int32) -> Void = { _ in }
    var memoryDismiss: () -> Void = {}
    var blockedDetails: (BlockedAlert) -> Void = { _ in }
    var blockedDismiss: (UUID) -> Void = { _ in }
    var missedAction: (MissedItem) -> Void = { _ in }
    var missedClear: () -> Void = {}
    var fixAutomation: () -> Void = {}
    var dismissJumpProblem: () -> Void = {}
    var prefetchUsage: () -> Void = {}
    var groupTogether: (String, String) -> Void = { _, _ in }
    var moveToGroup: (String, UUID?) -> Void = { _, _ in }
    var startNaming: (UUID) -> Void = { _ in }
    var deleteGroup: (UUID) -> Void = { _ in }
    var toggleGroup: (UUID) -> Void = { _ in }
    var renameGroup: (UUID, String) -> Void = { _, _ in }
    var recolorGroup: (UUID, GroupColor) -> Void = { _, _ in }
    var finishNaming: () -> Void = {}
    var dragStarted: () -> Void = {}
}

@MainActor
final class NotchState: ObservableObject {
    @Published var metrics: NotchMetrics
    @Published var expanded = false
    @Published var board = Board()
    @Published var hooks: HookInstallState = .installed
    @Published var jumpProblem: JumpProblem?
    var contentHeight: CGFloat?
    @Published var usageOpen = false
    @Published var naming: UUID?
    @Published var finished: [String] = []
    @Published var forcedFinished: Set<String> = []
    @Published var memoryAlert: MemoryAlert?
    var memorySimulated = false
    @Published var blocked: [BlockedAlert] = []
    @Published var missed: [MissedItem] = []
    @Published var stackHovered = false
    @Published var highlightSessionID: String?
    @Published var glowKey: UUID?
    var namingIsNew = false
    @Published var dropTarget: String?
    @Published var glass = false
    var actions = NotchActions()

    init(metrics: NotchMetrics) {
        self.metrics = metrics
    }

    var mode: IslandMode {
        if board.isEmpty && board.requests.isEmpty && memoryAlert == nil && blocked.isEmpty { return .empty }
        if !expanded { return Self.collapsedMode(board: board, finished: finished, forced: forcedFinished, memory: memoryAlert, blocked: blocked) }
        return .ears
    }

    var stack: [AlertItem] {
        expanded ? [] : Self.alertStack(board: board, finished: finished, forced: forcedFinished, memory: memoryAlert, blocked: blocked)
    }

    static func alertStack(board: Board, finished: [String], forced: Set<String>, memory: MemoryAlert?, blocked: [BlockedAlert]) -> [AlertItem] {
        var out: [AlertItem] = board.requests.map { .approval($0) }
        if let m = memory, m.level == .critical { out.append(.memory(m)) }
        out += blocked.map { .blocked($0) }
        out += finishedItems(board: board, ids: finished, forced: forced).reversed().map { .finished($0) }
        if let m = memory, m.level == .warning { out.append(.memory(m)) }
        return out
    }

    static func finishedItems(board: Board, ids: [String], forced: Set<String> = []) -> [SessionInfo] {
        ids.compactMap { board.info($0) }.filter { forced.contains($0.id) || ($0.display == .waiting && $0.unseen) }
    }

    static func collapsedMode(board: Board, finished: [String], forced: Set<String> = [], memory: MemoryAlert? = nil,
                              blocked: [BlockedAlert] = []) -> IslandMode {
        if let front = alertStack(board: board, finished: finished, forced: forced, memory: memory, blocked: blocked).first {
            return front.mode
        }
        if board.isEmpty && board.requests.isEmpty { return .empty }
        return .ears
    }

    var layout: IslandLayout { IslandLayout.of(mode, metrics: metrics, board: board) }
}

private struct StaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}

import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case unknown
    case idle
    case working
    case waiting
    case permission
    case question
    case error
}

public enum DisplayStatus: String, Sendable, CaseIterable {
    case permission
    case question
    case error
    case waiting
    case stalled
    case working
    case idle
    case unknown

    public var urgency: Int { DisplayStatus.allCases.firstIndex(of: self)! }

    public var needsUser: Bool { self == .permission || self == .question }
}

public struct PendingRequest: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var toolName: String
    public var toolInput: JSONValue
    public var summary: ToolSummary
    public var suggestions: JSONValue?
    public var createdAt: Date
    public var policyRule: PolicyMatch? = nil
    public var gate = false

    public var canAlways: Bool { !(suggestions?.isEmptyOrNull ?? true) }
}

public struct Session: Identifiable, Equatable, Sendable {
    public var id: String
    public var agent: String
    public var pid: Int32
    public var sessionID: String?
    public var tty: String?
    public var term: String?
    public var cwd: String
    public var hookTitle: String?
    public var aiTitle: String?
    public var metaName: String?
    public var metaNameSource: String?
    public var status: SessionStatus
    public var activity: String?
    public var lastMessage: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var statusSince: Date
    public var pending: [PendingRequest]
    public var seenAt: Date?

    public init(id: String, agent: String = "claude", pid: Int32, tty: String? = nil, term: String? = nil, cwd: String, now: Date) {
        self.id = id
        self.agent = agent
        self.pid = pid
        self.tty = tty
        self.term = term
        self.cwd = cwd
        self.status = .unknown
        self.startedAt = now
        self.lastEventAt = now
        self.statusSince = now
        self.pending = []
    }

    public var unseen: Bool {
        seenAt.map { $0 < statusSince } ?? true
    }

    public var title: String? {
        get {
            func text(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
            if metaNameSource == "user", let n = text(metaName) { return n }
            if let t = text(aiTitle) { return t }
            if metaNameSource != "derived", let n = text(metaName) { return n }
            return hookTitle
        }
        set { hookTitle = newValue }
    }

    public var isHome: Bool {
        cwd.isEmpty || (cwd as NSString).standardizingPath == (NSHomeDirectory() as NSString).standardizingPath
    }

    public var name: String {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return projectName }
        return ToolSummary.clip(t, 48)
    }

    public var detail: String? {
        guard let t = title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return displayPath
    }

    public var displayPath: String {
        guard !cwd.isEmpty else { return "~" }
        let full = (cwd as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        let path = full == home ? "~" : full.hasPrefix(home + "/") ? "~" + full.dropFirst(home.count) : full
        guard path.count > 40 else { return path }
        let parts = path.split(separator: "/")
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    public var chipName: String {
        ToolSummary.clip(name, 24)
    }

    public var projectName: String {
        if !cwd.isEmpty, (cwd as NSString).standardizingPath == (NSHomeDirectory() as NSString).standardizingPath {
            return "~"
        }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public func display(now: Date, stallAfter: TimeInterval = SessionStore.stallAfter) -> DisplayStatus {
        switch status {
        case .unknown: return .unknown
        case .idle: return .idle
        case .working: return now.timeIntervalSince(lastEventAt) > stallAfter ? .stalled : .working
        case .waiting: return .waiting
        case .permission: return .permission
        case .question: return .question
        case .error: return .error
        }
    }
}

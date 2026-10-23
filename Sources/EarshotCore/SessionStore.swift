import Foundation

public struct ClaudeProcess: Equatable, Sendable {
    public var pid: Int32
    public var tty: String?
    public var cwd: String
    public var startedAt: Date
    public var meta: ClaudeMeta?

    public init(pid: Int32, tty: String?, cwd: String, startedAt: Date, meta: ClaudeMeta? = nil) {
        self.pid = pid
        self.tty = tty
        self.cwd = cwd
        self.startedAt = startedAt
        self.meta = meta
    }
}

public enum StoreEffect: Equatable, Sendable {
    case reply(UUID, Reply)
    case blocked(sessionKey: String, PolicyMatch)
}

public struct SessionStore: Sendable {
    public static let stallAfter: TimeInterval = 300
    public static let orphanTTL: TimeInterval = 6 * 3600
    public static let lateNoticeWindow: TimeInterval = 10

    public private(set) var sessions: [String: Session] = [:]
    private var settledAt: [String: Date] = [:]
    private var ended: Set<Int32> = []
    private var hooked: Set<String> = []
    private var policyHints: [String: [String: PolicyMatch]] = [:]

    public init() {}

    public static func key(pid: Int32, sessionID: String?) -> String {
        pid > 0 ? "pid:\(pid)" : "sid:\(sessionID ?? "unknown")"
    }

    public func ordered(now: Date) -> [Session] {
        sessions.values.sorted {
            let a = $0.display(now: now).urgency, b = $1.display(now: now).urgency
            if a != b { return a < b }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
    }

    public var pendingQueue: [(session: Session, request: PendingRequest)] {
        sessions.values
            .flatMap { s in s.pending.map { (session: s, request: $0) } }
            .sorted {
                if $0.request.createdAt != $1.request.createdAt { return $0.request.createdAt < $1.request.createdAt }
                if $0.session.id != $1.session.id { return $0.session.id < $1.session.id }
                return $0.request.id.uuidString < $1.request.id.uuidString
            }
    }

    @discardableResult
    public mutating func ingest(_ m: WireMessage, requestID: UUID? = nil, now: Date) -> [StoreEffect] {
        let e = HookEvent(payload: m.payload)
        let k = SessionStore.key(pid: m.pid, sessionID: e.sessionID)
        var effects: [StoreEffect] = []

        if let id = requestID, e.name != "PermissionRequest", !(e.name == "PreToolUse" && m.policy?.action == .ask) {
            effects.append(.reply(id, .pass))
        }

        if e.name == "SessionEnd", !Self.processSurvives(e.reason) {
            if let s = sessions.removeValue(forKey: k) { effects += Self.passAll(s.pending) }
            settledAt[k] = nil
            hooked.remove(k)
            policyHints[k] = nil
            if m.pid > 0 { ended.insert(m.pid) }
            return effects
        }
        ended.remove(m.pid)
        hooked.insert(k)

        var s = sessions[k] ?? Session(id: k, agent: m.agent, pid: m.pid, tty: m.tty, term: m.term, cwd: e.cwd ?? "", now: now)
        let pendingBefore = s.pending.count
        if let t = m.tty { s.tty = t }
        if let t = m.term { s.term = t }
        if let c = e.cwd, !c.isEmpty { s.cwd = c }
        if let sid = e.sessionID, sid != s.sessionID {
            if s.sessionID != nil {
                effects += Self.passAll(s.pending)
                s.pending = []
                Self.forgetTitles(&s)
                s.lastMessage = nil
                s.activity = nil
            }
            s.sessionID = sid
        }
        s.lastEventAt = now

        func set(_ st: SessionStatus) {
            if s.status != st {
                s.status = st
                s.statusSince = now
            }
        }

        func cancelMatching() {
            let sig = Self.signature(e.toolName, e.toolInput)
            guard let i = s.pending.firstIndex(where: { Self.signature($0.toolName, $0.toolInput) == sig }) else { return }
            effects += Self.passAll([s.pending.remove(at: i)])
        }

        func cancelAll() {
            effects += Self.passAll(s.pending)
            s.pending = []
        }

        switch e.name {
        case "SessionStart":
            if let t = e.sessionTitle, !t.isEmpty { s.hookTitle = t }
            if e.source != "compact" || s.status == .unknown {
                set(.idle)
                s.activity = nil
            }

        case "SessionEnd":
            cancelAll()
            set(.idle)
            s.activity = nil
            Self.forgetTitles(&s)
            s.lastMessage = nil

        case "UserPromptSubmit":
            cancelAll()
            set(.working)
            s.activity = nil
            s.lastMessage = nil
            if let t = e.sessionTitle, !t.isEmpty {
                s.hookTitle = t
            } else if s.hookTitle == nil, let p = e.prompt {
                let line = ToolSummary.firstLine(p)
                if !line.isEmpty { s.hookTitle = ToolSummary.clip(line, 80) }
            }

        case "PreToolUse":
            if let p = m.policy, p.action == .deny {
                effects.append(.blocked(sessionKey: k, p))
                s.activity = "Blocked · " + p.label
                break
            }
            if let id = requestID, let p = m.policy, p.action == .ask {
                let sum = ToolSummary(tool: e.toolName ?? "?", input: e.toolInput, mcpServer: e.mcpServer)
                if !s.pending.contains(where: { $0.id == id }) {
                    s.pending.append(PendingRequest(
                        id: id,
                        toolName: e.toolName ?? "?",
                        toolInput: e.toolInput ?? .null,
                        summary: sum,
                        suggestions: nil,
                        createdAt: now,
                        policyRule: p,
                        gate: true))
                }
                set(.permission)
                s.activity = sum.short
                break
            }
            if let p = m.policy, p.action == .ask {
                policyHints[k, default: [:]][Self.signature(e.toolName, e.toolInput)] = p
            }
            if !s.pending.isEmpty { break }
            let sum = ToolSummary(tool: e.toolName ?? "?", input: e.toolInput, mcpServer: e.mcpServer)
            set(e.toolName == "AskUserQuestion" ? .question : .working)
            s.activity = sum.short

        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            policyHints[k]?[Self.signature(e.toolName, e.toolInput)] = nil
            cancelMatching()
            if s.pending.isEmpty {
                set(.working)
                s.activity = nil
            }

        case "PermissionRequest":
            let sum = ToolSummary(tool: e.toolName ?? "?", input: e.toolInput, mcpServer: e.mcpServer)
            if e.toolName == "AskUserQuestion" {
                if let id = requestID { effects.append(.reply(id, .pass)) }
                if s.pending.isEmpty {
                    set(.question)
                    s.activity = sum.short
                }
                break
            }
            let sig = Self.signature(e.toolName, e.toolInput)
            if let id = requestID, s.pending.contains(where: { $0.gate && Self.signature($0.toolName, $0.toolInput) == sig }) {
                effects.append(.reply(id, .pass))
            } else if let id = requestID, !s.pending.contains(where: { $0.id == id }) {
                s.pending.append(PendingRequest(
                    id: id,
                    toolName: e.toolName ?? "?",
                    toolInput: e.toolInput ?? .null,
                    summary: sum,
                    suggestions: e.permissionSuggestions,
                    createdAt: now,
                    policyRule: policyHints[k]?.removeValue(forKey: Self.signature(e.toolName, e.toolInput))))
            }
            set(.permission)
            s.activity = sum.short

        case "Notification":
            switch e.notificationType {
            case "permission_prompt":
                if s.status == .permission || s.status == .question { break }
                if s.pending.isEmpty, let t = settledAt[k], now.timeIntervalSince(t) < Self.lateNoticeWindow { break }
                set(.permission)
                if let msg = e.message { s.activity = msg }
            case "idle_prompt":
                if ![.permission, .question, .error].contains(s.status) { set(.waiting) }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                set(.question)
                if let msg = e.message { s.activity = msg }
            case "elicitation_complete", "elicitation_response":
                if s.status == .question { set(.working) }
            default:
                break
            }

        case "Stop":
            cancelAll()
            set(.waiting)
            s.activity = nil
            if let msg = e.lastAssistantMessage {
                let line = ToolSummary.firstLine(msg)
                s.lastMessage = line.isEmpty ? nil : ToolSummary.clip(line, 160)
            }

        case "StopFailure":
            cancelAll()
            set(.error)
            s.activity = ToolSummary.clip(Self.failureText(e), 160)

        default:
            break
        }

        if s.pending.count < pendingBefore { settledAt[k] = now }
        if ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"].contains(e.name) { policyHints[k] = nil }
        sessions[k] = s
        return effects
    }

    @discardableResult
    public mutating func resolve(requestID: UUID, reply: Reply, now: Date) -> [StoreEffect] {
        guard var s = sessions.values.first(where: { $0.pending.contains { $0.id == requestID } }) else { return [] }
        s.pending.removeAll { $0.id == requestID }
        if s.pending.isEmpty, s.status == .permission, reply.decision != .pass {
            s.status = .working
            s.statusSince = now
            s.activity = nil
        }
        s.lastEventAt = now
        sessions[s.id] = s
        settledAt[s.id] = now
        return [.reply(requestID, reply)]
    }

    public mutating func requestClosed(_ requestID: UUID, now: Date) {
        guard var s = sessions.values.first(where: { $0.pending.contains { $0.id == requestID } }) else { return }
        s.pending.removeAll { $0.id == requestID }
        if s.pending.isEmpty, s.status == .permission {
            s.status = .idle
            s.statusSince = now
            s.activity = "interrupted"
        }
        sessions[s.id] = s
        settledAt[s.id] = now
    }

    @discardableResult
    public mutating func sync(processes: [ClaudeProcess], isAlive: (Int32) -> Bool, now: Date) -> [StoreEffect] {
        var effects: [StoreEffect] = []
        ended = ended.filter { isAlive($0) }
        for p in processes where !ended.contains(p.pid) {
            let k = SessionStore.key(pid: p.pid, sessionID: nil)
            var s = sessions[k] ?? Session(id: k, pid: p.pid, tty: p.tty, cwd: p.cwd, now: now)
            if s.tty == nil { s.tty = p.tty }
            if s.cwd.isEmpty { s.cwd = p.cwd }
            s.startedAt = p.startedAt
            if let m = p.meta { Self.apply(m, to: &s, hooked: hooked.contains(k), now: now) }
            sessions[k] = s
        }
        for (k, s) in sessions {
            let dead = s.pid > 0 ? !isAlive(s.pid) : now.timeIntervalSince(s.lastEventAt) > Self.orphanTTL
            if dead {
                effects += Self.passAll(s.pending)
                sessions.removeValue(forKey: k)
                settledAt[k] = nil
                hooked.remove(k)
                policyHints[k] = nil
            }
        }
        return effects
    }

    public mutating func markSeen(id: String, now: Date) {
        sessions[id]?.seenAt = now
    }

    public mutating func remove(id: String) -> [StoreEffect] {
        settledAt[id] = nil
        hooked.remove(id)
        policyHints[id] = nil
        guard let s = sessions.removeValue(forKey: id) else { return [] }
        return Self.passAll(s.pending)
    }

    static func apply(_ m: ClaudeMeta, to s: inout Session, hooked: Bool, now: Date) {
        if let sid = m.sessionID, sid != s.sessionID {
            if hooked, s.sessionID != nil { return }
            if s.sessionID != nil {
                forgetTitles(&s)
                s.lastMessage = nil
            }
            s.sessionID = sid
        }
        if s.cwd.isEmpty, let c = m.cwd { s.cwd = c }
        s.metaName = m.name
        s.metaNameSource = m.nameSource
        if let t = m.aiTitle { s.aiTitle = t }
        guard !hooked else { return }
        switch m.status {
        case "busy":
            if s.status != .working {
                s.status = .working
                s.statusSince = m.statusUpdatedAt ?? now
            }
            s.lastEventAt = now
        case "idle":
            if s.status != .waiting {
                s.status = .waiting
                s.statusSince = m.statusUpdatedAt ?? now
                s.seenAt = s.statusSince
            }
        default:
            break
        }
    }

    static func forgetTitles(_ s: inout Session) {
        s.hookTitle = nil
        s.aiTitle = nil
        s.metaName = nil
        s.metaNameSource = nil
    }

    static func processSurvives(_ reason: String?) -> Bool {
        reason == "clear" || reason == "resume"
    }

    static func failureText(_ e: HookEvent) -> String {
        let known: [String: String] = [
            "rate_limit": "Rate limit reached",
            "overloaded": "API overloaded",
            "authentication_failed": "Authentication failed",
            "billing_error": "Billing error",
            "server_error": "API server error",
            "max_output_tokens": "Output token limit reached",
            "model_not_found": "Model not found",
            "invalid_request": "Invalid API request",
        ]
        if let code = e.error, let text = known[code] { return text }
        if let d = e.errorDetails {
            let line = ToolSummary.firstLine(d)
            if !line.isEmpty { return line }
        }
        return e.error ?? "API error"
    }

    static func signature(_ tool: String?, _ input: JSONValue?) -> String {
        (tool ?? "") + "|" + (input?.canonical ?? "")
    }

    static func passAll(_ reqs: [PendingRequest]) -> [StoreEffect] {
        reqs.map { .reply($0.id, .pass) }
    }
}

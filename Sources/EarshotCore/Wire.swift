import Foundation

public enum WireKind: String, Codable, Sendable {
    case event
    case request
    case query
    case debug
}

public struct WireMessage: Codable, Equatable, Sendable {
    public var v: Int
    public var kind: WireKind
    public var agent: String
    public var pid: Int32
    public var tty: String?
    public var term: String?
    public var payload: JSONValue
    public var policy: PolicyMatch?

    public init(v: Int = Wire.version, kind: WireKind, agent: String = "claude", pid: Int32, tty: String?, term: String?, payload: JSONValue, policy: PolicyMatch? = nil) {
        self.v = v
        self.kind = kind
        self.agent = agent
        self.pid = pid
        self.tty = tty
        self.term = term
        self.payload = payload
        self.policy = policy
    }
}

public enum Decision: String, Codable, Sendable {
    case allow
    case always
    case deny
    case pass
}

public struct Reply: Codable, Equatable, Sendable {
    public var decision: Decision
    public var message: String?

    public init(_ decision: Decision, message: String? = nil) {
        self.decision = decision
        self.message = message
    }

    public static let pass = Reply(.pass)
}

public enum Wire {
    public static let version = 1

    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var d = try JSONEncoder().encode(value)
        d.append(0x0A)
        return d
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var pid: Int32
    public var tty: String?
    public var project: String
    public var cwd: String
    public var status: String
    public var title: String?
    public var activity: String?
    public var lastMessage: String?
    public var seconds: Int
    public var pending: Int

    public init(_ s: Session, display: DisplayStatus, now: Date) {
        pid = s.pid
        tty = s.tty
        project = s.projectName
        cwd = s.cwd
        status = display.rawValue
        title = s.title
        activity = s.activity
        lastMessage = s.lastMessage
        seconds = max(0, Int(now.timeIntervalSince(s.statusSince)))
        pending = s.pending.count
    }
}

public enum Paths {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Earshot", isDirectory: true)
    }

    public static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["EARSHOT_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDir.appendingPathComponent("earshot.sock")
    }
}

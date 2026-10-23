import Darwin
import Foundation

public enum PolicyAction: String, Codable, Sendable, CaseIterable {
    case deny = "block"
    case ask

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(lenient: raw)
    }

    public init(lenient raw: String) {
        switch raw.lowercased() {
        case "block", "deny": self = .deny
        default: self = .ask
        }
    }

    public var hookDecision: String {
        switch self {
        case .deny: return "deny"
        case .ask: return "ask"
        }
    }
}

public enum PolicyChoice: String, Codable, Sendable, CaseIterable {
    case off
    case ask
    case block

    public init?(lenient raw: String) {
        switch raw.lowercased() {
        case "off", "allow", "none", "disabled": self = .off
        case "ask": self = .ask
        case "block", "deny": self = .block
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let c = Self(lenient: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown choice \(raw)"))
        }
        self = c
    }

    public var action: PolicyAction? {
        switch self {
        case .off: return nil
        case .ask: return .ask
        case .block: return .deny
        }
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask"
        case .block: return "Block"
        }
    }
}

public struct PolicyMatcher: Codable, Equatable, Sendable {
    public var tools: [String]
    public var command: String?
    public var script: String?
    public var path: String?
    public var input: String?
    public var redirect: String?
    public var outsideProject: Bool?
    public var host: String?
    public var reason: String?
    public var words: [String]?

    public init(tools: [String], command: String? = nil, script: String? = nil, path: String? = nil, input: String? = nil,
                redirect: String? = nil, outsideProject: Bool? = nil, host: String? = nil, reason: String? = nil, words: [String]? = nil) {
        self.tools = tools
        self.command = command
        self.script = script
        self.path = path
        self.input = input
        self.redirect = redirect
        self.outsideProject = outsideProject
        self.host = host
        self.reason = reason
        self.words = words
    }
}

public struct PolicyRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var action: PolicyAction
    public var pattern: String?
    public var tools: [String]?
    public var when: [PolicyMatcher]?

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, action: PolicyAction,
                pattern: String? = nil, tools: [String]? = nil, when: [PolicyMatcher]? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.action = action
        self.pattern = pattern
        self.tools = tools
        self.when = when
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? nil
        tools = (try? c.decodeIfPresent([String].self, forKey: .tools)) ?? nil
        when = try c.decodeIfPresent([PolicyMatcher].self, forKey: .when)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? pattern ?? id
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
        let raw = ((try? c.decodeIfPresent(String.self, forKey: .action)) ?? nil) ?? "ask"
        action = PolicyAction(lenient: raw)
        if raw.lowercased() == "allow" { enabled = false }
    }

    public var matchers: [PolicyMatcher] {
        var out = when ?? []
        if let pattern, !pattern.trimmingCharacters(in: .whitespaces).isEmpty, let re = Self.regex(fromPattern: pattern) {
            let scope = tools.flatMap { $0.isEmpty ? nil : $0 } ?? ["Bash"]
            let shell = scope.filter { $0 == "Bash" }
            let other = scope.filter { $0 != "Bash" }
            if !shell.isEmpty { out.append(PolicyMatcher(tools: shell, command: re, words: Self.leadingWord(pattern))) }
            if !other.isEmpty { out.append(PolicyMatcher(tools: other, input: re)) }
        }
        return out
    }

    static func leadingWord(_ pattern: String) -> [String]? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.hasPrefix("regex:"), let first = p.split(separator: " ").first else { return nil }
        let w = (String(first) as NSString).lastPathComponent
        guard !w.isEmpty, w.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else { return nil }
        return [w]
    }

    public static func regex(fromPattern raw: String) -> String? {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("regex:") {
            let r = String(p.dropFirst(6))
            return (try? NSRegularExpression(pattern: r)) == nil ? nil : r
        }
        var out = "^"
        if let f = p.first, f.isLetter || f.isNumber { out += #"(?:\S*/)?"# }
        var lastSpace = false
        for c in p {
            if c == "*" {
                out += ".*"
                lastSpace = false
            } else if c == " " || c == "\t" {
                if !lastSpace { out += #"\s+"# }
                lastSpace = true
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
                lastSpace = false
            }
        }
        return out + "$"
    }
}

public struct PolicyMatch: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var action: PolicyAction
    public var reason: String?
    public var command: String?

    public init(id: String, name: String, action: PolicyAction, reason: String? = nil, command: String? = nil) {
        self.id = id
        self.name = name
        self.action = action
        self.reason = reason
        self.command = command
    }

    public var label: String {
        reason.map { "\(name) (\($0))" } ?? name
    }
}

public struct PolicyInput: Sendable {
    public var tool: String
    public var input: JSONValue
    public var cwd: String?
    public var home: String
    public var extraRoots: [String]

    public init(tool: String, input: JSONValue, cwd: String?, home: String = NSHomeDirectory(), extraRoots: [String] = []) {
        self.tool = tool
        self.input = input
        self.cwd = cwd
        self.home = home
        self.extraRoots = extraRoots
    }

    public init?(event e: HookEvent, home: String = NSHomeDirectory()) {
        guard let tool = e.toolName, tool != "AskUserQuestion" else { return nil }
        let roots = [e.scratchpadDir, home + "/.claude/plans"].compactMap { $0 }.filter { !$0.isEmpty }
        self.init(tool: tool, input: e.toolInput ?? .null, cwd: e.cwd, home: home, extraRoots: roots)
    }

    var filePath: String? {
        input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string
    }

    var subject: String {
        if tool == "Bash" { return input["command"]?.string ?? "" }
        if tool == "Glob" { return (input["path"]?.string ?? "") + "/" + (input["pattern"]?.string ?? "") }
        if tool == "Grep", let g = input["glob"]?.string { return (input["path"]?.string ?? "") + "/" + g }
        if let p = filePath { return p }
        if let u = input["url"]?.string { return u }
        return input.isEmptyOrNull ? "" : input.canonical
    }

    func outside(_ path: String) -> Bool {
        guard let p = PathCheck.resolve(path, cwd: cwd, home: home) else { return true }
        let roots = [cwd].compactMap { $0 } + extraRoots
        if roots.contains(where: { !$0.isEmpty && PathCheck.under(p, $0) }) { return false }
        return !PathCheck.isMemory(p, home: home)
    }
}

public struct Policy: Codable, Equatable, Sendable {
    public static let version = 2

    public var version: Int
    public var catalog: [String: PolicyChoice]
    public var rules: [PolicyRule]
    public var skipped = 0

    public init(version: Int = Policy.version, catalog: [String: PolicyChoice] = [:], rules: [PolicyRule] = []) {
        self.version = version
        self.catalog = catalog
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case version, catalog, rules }

    struct Lenient: Decodable {
        var rule: PolicyRule?
        init(from decoder: Decoder) throws { rule = try? PolicyRule(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        let lenient = try c.decodeIfPresent([Lenient].self, forKey: .rules) ?? []
        let rules = lenient.compactMap(\.rule)
        if v < 2 {
            self = PolicyCatalog.migrate(v1: rules)
            skipped = lenient.count - rules.count
            return
        }
        version = v
        var catalog: [String: PolicyChoice] = [:]
        for (k, value) in try c.decodeIfPresent([String: JSONValue].self, forKey: .catalog) ?? [:] {
            if let raw = value.string, let choice = PolicyChoice(lenient: raw) { catalog[k] = choice }
        }
        self.catalog = catalog
        self.rules = rules
        skipped = lenient.count - rules.count
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(catalog, forKey: .catalog)
        try c.encode(rules, forKey: .rules)
    }

    public func choice(_ id: String) -> PolicyChoice {
        catalog[id] ?? PolicyCatalog.rule(id)?.defaultChoice ?? .off
    }

    public var activeRules: [PolicyRule] {
        let builtIn: [PolicyRule] = PolicyCatalog.rules.compactMap { r in
            guard let action = choice(r.id).action else { return nil }
            return PolicyRule(id: r.id, name: r.name, action: action, when: r.when)
        }
        return builtIn + rules.filter(\.enabled)
    }

    public func evaluate(_ x: PolicyInput) -> PolicyMatch? {
        let script = x.tool == "Bash" ? ShellScript.parse(x.subject) : nil
        let dirs = script.map { Self.dirs($0.commands, x) } ?? []
        let active = activeRules
        for action in PolicyAction.allCases {
            for rule in active where rule.action == action {
                for m in rule.matchers {
                    if let hit = Self.matches(m, x, script: script, dirs: dirs) {
                        return PolicyMatch(id: rule.id, name: rule.name, action: action, reason: m.reason, command: hit)
                    }
                }
            }
        }
        guard let script, script.opaque else { return nil }
        for action in PolicyAction.allCases {
            for rule in active where rule.action == action {
                for m in rule.matchers where m.tools.contains(where: { Self.toolMatches($0, "Bash") }) {
                    if script.tooBig || (m.words ?? []).contains(where: { Self.mentions($0, x.subject) }) {
                        return PolicyMatch(id: rule.id, name: rule.name, action: .ask,
                                           reason: script.tooBig ? "too long to check" : "hard to read command",
                                           command: String(x.subject.prefix(300)))
                    }
                }
            }
        }
        return nil
    }

    public func covers(_ match: PolicyMatch, _ x: PolicyInput) -> Bool {
        guard x.tool == "Bash" else { return true }
        let script = ShellScript.parse(x.subject)
        guard !script.opaque, !script.commands.isEmpty,
              let rule = activeRules.first(where: { $0.id == match.id }) else { return false }
        let dirs = Self.dirs(script.commands, x)
        return script.commands.indices.allSatisfy { i in
            rule.matchers.contains { m in
                m.tools.contains { Self.toolMatches($0, "Bash") } && Self.commandHit(m, script.commands[i], x, dir: dirs[i])
            }
        }
    }

    static func dirs(_ commands: [ShellCommand], _ x: PolicyInput) -> [String?] {
        var here: String? = x.cwd.map { PathCheck.real($0) }
        var out: [String?] = []
        for c in commands {
            out.append(here)
            guard let w = c.words.first, w == "cd" || w == "pushd" else { continue }
            let arg = c.words.dropFirst().first { !$0.hasPrefix("-") }
            guard let arg else {
                here = PathCheck.real(x.home)
                continue
            }
            if arg == "-" {
                here = nil
            } else if arg.hasPrefix("/") || arg.hasPrefix("~") || arg.hasPrefix("$HOME") || arg.hasPrefix("${HOME}") {
                here = PathCheck.resolve(arg, cwd: nil, home: x.home)
            } else {
                here = here.flatMap { PathCheck.resolve(arg, cwd: $0, home: x.home) }
            }
        }
        return out
    }

    static func mentions(_ word: String, _ text: String) -> Bool {
        let pattern = #"(?<![A-Za-z0-9_.-])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![A-Za-z0-9_-])"#
        return re(pattern).map { found($0, text) } ?? false
    }

    static func re(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func found(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func commandHit(_ m: PolicyMatcher, _ c: ShellCommand, _ x: PolicyInput, dir: String?) -> Bool {
        if let pattern = m.script {
            guard let r = re(pattern), found(r, x.subject) else { return false }
        }
        if let pattern = m.command {
            guard let r = re(pattern), c.forms.contains(where: { found(r, $0) }) else { return false }
        }
        if let pattern = m.redirect {
            guard let r = re(pattern), c.redirects.contains(where: { found(r, $0) }) else { return false }
        }
        if m.outsideProject == true, !c.touchesOutside(x, dir: dir) { return false }
        return true
    }

    static func matches(_ m: PolicyMatcher, _ x: PolicyInput, script: ShellScript?, dirs: [String?]) -> String? {
        guard m.tools.contains(where: { toolMatches($0, x.tool) }) else { return nil }
        if let host = m.host {
            guard let h = x.input["url"]?.string.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
            let want = host.lowercased()
            guard h == want || h.hasSuffix("." + want) else { return nil }
        }
        if let pattern = m.path {
            guard let raw = x.filePath, let r = re(pattern) else { return nil }
            let resolved = PathCheck.resolve(raw, cwd: x.cwd, home: x.home) ?? raw
            guard found(r, resolved) || found(r, raw) else { return nil }
        }
        if let pattern = m.input {
            guard let r = re(pattern), found(r, x.subject) else { return nil }
        }
        if m.command != nil || m.redirect != nil || (x.tool == "Bash" && m.script != nil) {
            guard x.tool == "Bash", let script else { return nil }
            for (i, c) in script.commands.enumerated() where commandHit(m, c, x, dir: dirs[i]) {
                return c.raw.isEmpty ? c.normalized : c.raw
            }
            return nil
        }
        if m.outsideProject == true {
            guard let p = x.filePath, x.outside(p) else { return nil }
        }
        return x.subject
    }

    static func toolMatches(_ pattern: String, _ tool: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") { return tool.hasPrefix(String(pattern.dropLast())) }
        return pattern == tool
    }
}

enum PathCheck {
    static func resolve(_ raw: String, cwd: String?, home: String) -> String? {
        var p = raw
        if p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
        for v in ["${HOME}", "$HOME"] where p == v || p.hasPrefix(v + "/") { p = home + p.dropFirst(v.count) }
        if p.contains("$") || p.contains("`") || p.hasPrefix("~") { return nil }
        if !p.hasPrefix("/") {
            guard let cwd, !cwd.isEmpty else { return nil }
            p = cwd + "/" + p
        }
        return real(p)
    }

    static func real(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        if let r = realpath(std, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        let parent = (std as NSString).deletingLastPathComponent
        guard parent != std, !parent.isEmpty else { return std }
        return (real(parent) as NSString).appendingPathComponent((std as NSString).lastPathComponent)
    }

    static func under(_ resolved: String, _ root: String) -> Bool {
        let r = real(root)
        return resolved == r || resolved.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    static func isMemory(_ p: String, home: String) -> Bool {
        let projects = real(home + "/.claude/projects") + "/"
        guard p.hasPrefix(projects) else { return false }
        let rest = p.dropFirst(projects.count).split(separator: "/")
        return rest.count >= 3 && rest[1] == "memory"
    }

    static func dangerous(_ raw: String, _ x: PolicyInput, dir: String?) -> Bool {
        guard let p = resolve(raw, cwd: dir, home: x.home) else { return true }
        if let cwd = x.cwd, p == real(cwd), raw != ".", raw != "./" { return true }
        return p == "/" || p == real(x.home) || x.outside(p)
    }
}

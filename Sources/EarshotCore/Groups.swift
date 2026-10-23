import Foundation

public enum GroupColor: String, Codable, CaseIterable, Sendable {
    case blue, indigo, purple, pink, teal, mint, yellow, brown, gray
}

public struct SessionGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: GroupColor
    public var members: [String]
    public var folders: [String]
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, color: GroupColor, members: [String] = [], folders: [String] = [], collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.members = members
        self.folders = folders
        self.collapsed = collapsed
    }
}

public struct GroupStore: Codable, Equatable, Sendable {
    public static let presets: [(name: String, color: GroupColor)] = [
        ("Work", .blue), ("Study", .purple), ("Research", .teal), ("Open Source", .mint),
        ("Personal", .pink), ("Side Project", .indigo), ("Ops", .yellow), ("Misc", .gray),
    ]
    public static let maxMembers = 200

    public private(set) var groups: [SessionGroup] = []

    public init(groups: [SessionGroup] = []) {
        self.groups = groups
    }

    public static func keys(_ s: Session) -> [String] {
        [s.sessionID, s.id].compactMap { $0 }
    }

    public static func rememberable(_ cwd: String, home: String) -> Bool {
        let c = Self.normalize(cwd)
        return !c.isEmpty && c != "/" && c != Self.normalize(home)
    }

    public func group(for s: Session, home: String = NSHomeDirectory()) -> SessionGroup? {
        let k = Set(Self.keys(s))
        if let g = groups.first(where: { !k.isDisjoint(with: $0.members) }) { return g }
        let cwd = Self.normalize(s.cwd)
        guard Self.rememberable(cwd, home: home) else { return nil }
        return groups
            .compactMap { g in g.folders.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.map(\.count).max().map { (g, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    public func index(of id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    @discardableResult
    public mutating func create(name: String? = nil, color: GroupColor? = nil) -> UUID {
        let preset = nextPreset()
        let g = SessionGroup(name: Self.clean(name) ?? preset.name, color: color ?? preset.color)
        groups.append(g)
        return g.id
    }

    @discardableResult
    public mutating func create(with a: Session, _ b: Session, home: String = NSHomeDirectory()) -> UUID {
        let id = create()
        add(a, to: id, home: home)
        add(b, to: id, home: home)
        return id
    }

    public mutating func add(_ s: Session, to id: UUID, home: String = NSHomeDirectory()) {
        guard index(of: id) != nil else { return }
        detach(s, home: home)
        guard let i = index(of: id) else { return }
        for k in Self.keys(s) where !groups[i].members.contains(k) { groups[i].members.append(k) }
        if groups[i].members.count > Self.maxMembers { groups[i].members.removeFirst(groups[i].members.count - Self.maxMembers) }
        let cwd = Self.normalize(s.cwd)
        if Self.rememberable(cwd, home: home), !groups[i].folders.contains(cwd) { groups[i].folders.append(cwd) }
    }

    public mutating func remove(_ s: Session, home: String = NSHomeDirectory()) {
        detach(s, home: home)
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = index(of: id), let n = Self.clean(name) else { return }
        groups[i].name = n
    }

    public mutating func recolor(_ id: UUID, to color: GroupColor) {
        guard let i = index(of: id) else { return }
        groups[i].color = color
    }

    public mutating func toggleCollapsed(_ id: UUID) {
        guard let i = index(of: id) else { return }
        groups[i].collapsed.toggle()
    }

    public mutating func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    public mutating func move(_ id: UUID, to position: Int) {
        guard let i = index(of: id) else { return }
        let g = groups.remove(at: i)
        groups.insert(g, at: max(0, min(position, groups.count)))
    }

    public mutating func prune(live: [Session]) {
        let alive = Set(live.map(\.id))
        for i in groups.indices {
            groups[i].members.removeAll { $0.hasPrefix("pid:") && !alive.contains($0) }
        }
    }

    public func sections(_ sessions: [Session], home: String = NSHomeDirectory()) -> [(group: SessionGroup?, sessions: [Session])] {
        var byGroup: [UUID: [Session]] = [:]
        var loose: [Session] = []
        for s in sessions {
            if let g = group(for: s, home: home) { byGroup[g.id, default: []].append(s) } else { loose.append(s) }
        }
        var out: [(group: SessionGroup?, sessions: [Session])] = groups.map { ($0, byGroup[$0.id] ?? []) }
        if !loose.isEmpty { out.append((nil, loose)) }
        return out
    }

    private mutating func detach(_ s: Session, home: String) {
        let k = Set(Self.keys(s))
        let cwd = Self.normalize(s.cwd)
        let owner = group(for: s, home: home)?.id
        for i in groups.indices {
            groups[i].members.removeAll { k.contains($0) }
            if groups[i].id == owner { groups[i].folders.removeAll { $0 == cwd } }
        }
    }

    private func nextPreset() -> (name: String, color: GroupColor) {
        let used = Set(groups.map { $0.name.lowercased() })
        if let p = Self.presets.first(where: { !used.contains($0.name.lowercased()) }) { return p }
        let colors = GroupColor.allCases
        return ("Group \(groups.count + 1)", colors[groups.count % colors.count])
    }

    static func clean(_ name: String?) -> String? {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return String(n.prefix(32))
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

extension GroupStore {
    public static var defaultURL: URL { Paths.supportDir.appendingPathComponent("groups.json") }

    public static func load(from url: URL = defaultURL) -> GroupStore {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(GroupStore.self, from: d) else { return GroupStore() }
        return s
    }

    public func save(to url: URL = defaultURL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

import XCTest
@testable import EarshotCore

final class GroupStoreTests: XCTestCase {
    let home = "/Users/me"
    let t = Date(timeIntervalSince1970: 1_000)

    func session(_ pid: Int32, sid: String? = nil, cwd: String) -> Session {
        var s = Session(id: "pid:\(pid)", pid: pid, cwd: cwd, now: t)
        s.sessionID = sid
        return s
    }

    func testDropOnAnotherCreatesPresetGroup() {
        var g = GroupStore()
        let a = session(1, sid: "a", cwd: "/Users/me/site"), b = session(2, sid: "b", cwd: home)
        let id = g.create(with: a, b, home: home)
        XCTAssertEqual(g.groups.count, 1)
        XCTAssertEqual(g.groups[0].name, "Work")
        XCTAssertEqual(g.groups[0].color, .blue)
        XCTAssertEqual(g.group(for: a, home: home)?.id, id)
        XCTAssertEqual(g.group(for: b, home: home)?.id, id)
        XCTAssertEqual(g.groups[0].folders, ["/Users/me/site"])
        XCTAssertEqual(g.create(), g.groups[1].id)
        XCTAssertEqual(g.groups[1].name, "Study")
    }

    func testFolderRuleCatchesNewSessionsButNotHome() {
        var g = GroupStore()
        let id = g.create(name: "Study", color: .purple)
        g.add(session(1, cwd: "/Users/me/site/"), to: id, home: home)
        XCTAssertEqual(g.group(for: session(9, cwd: "/Users/me/site/os"), home: home)?.id, id)
        XCTAssertNil(g.group(for: session(9, cwd: "/Users/me/siteX"), home: home))
        g.add(session(2, cwd: home), to: id, home: home)
        XCTAssertNil(g.group(for: session(10, cwd: home), home: home))
    }

    func testDeepestFolderWins() {
        var g = GroupStore()
        let outer = g.create(name: "Open Source", color: .mint)
        let inner = g.create(name: "Research", color: .teal)
        g.add(session(1, cwd: "/Users/me/oss"), to: outer, home: home)
        g.add(session(2, cwd: "/Users/me/oss/pipeline"), to: inner, home: home)
        XCTAssertEqual(g.group(for: session(3, cwd: "/Users/me/oss/pipeline/x"), home: home)?.id, inner)
        XCTAssertEqual(g.group(for: session(4, cwd: "/Users/me/oss/mobile-app"), home: home)?.id, outer)
    }

    func testExplicitMembershipBeatsFolderAndMovingDetaches() {
        var g = GroupStore()
        let work = g.create(), study = g.create()
        let s = session(1, sid: "s", cwd: "/Users/me/site")
        g.add(s, to: work, home: home)
        g.add(s, to: study, home: home)
        XCTAssertEqual(g.group(for: s, home: home)?.id, study)
        XCTAssertFalse(g.groups[0].members.contains("s"))
        XCTAssertTrue(g.groups[0].folders.isEmpty)
        g.remove(s, home: home)
        XCTAssertNil(g.group(for: s, home: home))
    }

    func testRenameRecolorCollapseMoveDelete() {
        var g = GroupStore()
        let a = g.create(), b = g.create()
        g.rename(a, to: "   ")
        XCTAssertEqual(g.groups[0].name, "Work")
        g.rename(a, to: "  Acme  ")
        XCTAssertEqual(g.groups[0].name, "Acme")
        g.recolor(a, to: .pink)
        g.toggleCollapsed(a)
        XCTAssertEqual(g.groups[0].color, .pink)
        XCTAssertTrue(g.groups[0].collapsed)
        g.move(b, to: 0)
        XCTAssertEqual(g.groups.map(\.id), [b, a])
        g.delete(b)
        XCTAssertEqual(g.groups.map(\.id), [a])
    }

    func testSectionsKeepGroupOrderAndLooseLast() {
        var g = GroupStore()
        let work = g.create(), study = g.create()
        let s1 = session(1, cwd: "/p1"), s2 = session(2, cwd: "/p2"), s3 = session(3, cwd: "/p3")
        g.add(s2, to: study, home: home)
        g.add(s1, to: work, home: home)
        let secs = g.sections([s1, s2, s3], home: home)
        XCTAssertEqual(secs.map { $0.group?.id }, [work, study, nil])
        XCTAssertEqual(secs.map { $0.sessions.map(\.pid) }, [[1], [2], [3]])
    }

    func testPruneDropsDeadPidKeysOnly() {
        var g = GroupStore()
        let id = g.create()
        g.add(session(1, sid: "keep", cwd: "/x"), to: id, home: home)
        g.add(session(2, cwd: "/y"), to: id, home: home)
        g.prune(live: [session(2, cwd: "/y")])
        XCTAssertEqual(Set(g.groups[0].members), ["keep", "pid:2"])
    }

    func testPersistenceRoundTrip() throws {
        var g = GroupStore()
        let id = g.create(name: "Research", color: .teal)
        g.add(session(1, sid: "r", cwd: "/Users/me/papers"), to: id, home: home)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groups-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try g.save(to: url)
        XCTAssertEqual(GroupStore.load(from: url), g)
        XCTAssertEqual(GroupStore.load(from: url.appendingPathExtension("missing")), GroupStore())
    }
}

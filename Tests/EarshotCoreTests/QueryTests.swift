import Foundation
import XCTest
@testable import EarshotCore

final class QueryTests: XCTestCase {
    func testQueryReturnsSnapshotFromMain() throws {
        let dir = makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("q.sock")
        let server = SocketServer(path: path)
        defer { server.stop() }
        var store = SessionStore()
        let t0 = Date()
        store.ingest(WireMessage(kind: .event, pid: 77, tty: "ttys009", term: nil, payload: payload("PreToolUse")), now: t0)
        server.onQuery = {
            XCTAssertTrue(Thread.isMainThread)
            return try? JSONEncoder().encode(store.ordered(now: t0).map { SessionSnapshot($0, display: $0.display(now: t0), now: t0) })
        }
        try server.start()

        let got = expectation(description: "reply")
        var rows: [SessionSnapshot] = []
        DispatchQueue.global().async {
            let line = try! Wire.line(WireMessage(kind: .query, pid: 0, tty: nil, term: nil, payload: .null))
            let data = try? SocketClient.send(line, to: path, awaitReply: true)
            rows = data.flatMap { try? JSONDecoder().decode([SessionSnapshot].self, from: $0) } ?? []
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, "working")
        XCTAssertEqual(rows.first?.project, "proj")
        XCTAssertEqual(rows.first?.activity, "Bash ls -la")
    }

    func testTableRendering() {
        XCTAssertEqual(SessionTable.render([]), "no Claude sessions")
        XCTAssertEqual(SessionTable.duration(42), "42s")
        XCTAssertEqual(SessionTable.duration(125), "2m")
        XCTAssertEqual(SessionTable.duration(3600), "1h")
        XCTAssertEqual(SessionTable.duration(3720), "1h2m")
    }
}

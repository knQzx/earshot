import Darwin
import Foundation
import XCTest
@testable import EarshotCore

final class HookRunnerTests: XCTestCase {
    var dir: URL!
    var path: URL!

    let claude = Proc.Info(pid: 4242, ppid: 1, tty: "ttys009", comm: "claude", startedAt: Date())
    let headless = Proc.Info(pid: 4343, ppid: 1, tty: nil, comm: "claude", startedAt: Date())
    let env = ["TERM_PROGRAM": "iTerm.app"]

    override func setUp() {
        dir = makeSocketDir()
        path = dir.appendingPathComponent("s.sock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func stdin(_ name: String) -> Data {
        try! JSONEncoder().encode(payload(name))
    }

    func touchSocketFile() {
        FileManager.default.createFile(atPath: path.path, contents: Data())
    }

    func testNoSocketReturnsNilQuickly() {
        let t0 = Date()
        let out = HookRunner.run(stdin: stdin("PermissionRequest"), env: env, ancestor: claude, socket: path) { _, _, _ in
            XCTFail("must not connect")
            return nil
        }
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
    }

    func testDisabledDoesNothing() {
        touchSocketFile()
        let rec = dir.appendingPathComponent("rec.jsonl")
        let out = HookRunner.run(stdin: stdin("Stop"), env: ["EARSHOT_DISABLE": "1", "EARSHOT_RECORD": rec.path], ancestor: claude, socket: path) { _, _, _ in
            XCTFail("must not connect")
            return nil
        }
        XCTAssertNil(out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rec.path))
    }

    func testRecordAppendsRawLines() throws {
        let rec = dir.appendingPathComponent("rec.jsonl")
        let a = stdin("Stop"), b = stdin("PostToolUse") + Data("\n".utf8)
        _ = HookRunner.run(stdin: a, env: ["EARSHOT_RECORD": rec.path], ancestor: nil, socket: path)
        _ = HookRunner.run(stdin: b, env: ["EARSHOT_RECORD": rec.path], ancestor: nil, socket: path)
        let lines = try String(contentsOf: rec, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(Data(lines[0].utf8), a)
        XCTAssertEqual(lines[2], "")
    }

    func testBadStdinDoesNothing() {
        touchSocketFile()
        for bad in [Data(), Data("not json".utf8), Data("[1,2]".utf8)] {
            XCTAssertNil(HookRunner.run(stdin: bad, env: env, ancestor: claude, socket: path) { _, _, _ in
                XCTFail("must not connect")
                return nil
            })
        }
    }

    func testEventModeDoesNotWait() throws {
        touchSocketFile()
        var sent: WireMessage?
        let out = HookRunner.run(stdin: stdin("PostToolUse"), env: env, ancestor: claude, socket: path) { line, _, wait in
            XCTAssertFalse(wait)
            sent = try Wire.decode(WireMessage.self, line: line.dropLast())
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        XCTAssertNil(out)
        XCTAssertEqual(sent?.kind, .event)
        XCTAssertEqual(sent?.pid, 4242)
        XCTAssertEqual(sent?.tty, "ttys009")
        XCTAssertEqual(sent?.term, "iTerm.app")
        XCTAssertEqual(sent?.payload, payload("PostToolUse"))
    }

    func testEventModeAgainstSilentServerReturnsAtOnce() throws {
        let server = SocketServer(path: path)
        defer { server.stop() }
        try server.start()
        let t0 = Date()
        XCTAssertNil(HookRunner.run(stdin: stdin("PostToolUse"), env: env, ancestor: claude, socket: path))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }

    func testPermissionRequestWithoutTTYIsEvent() {
        touchSocketFile()
        var kind: WireKind?
        let out = HookRunner.run(stdin: stdin("PermissionRequest"), env: env, ancestor: headless, socket: path) { line, _, wait in
            XCTAssertFalse(wait)
            kind = try Wire.decode(WireMessage.self, line: line.dropLast()).kind
            return nil
        }
        XCTAssertNil(out)
        XCTAssertEqual(kind, .event)
    }

    func testNoAncestorSendsPidZero() {
        touchSocketFile()
        var sent: WireMessage?
        _ = HookRunner.run(stdin: stdin("PermissionRequest"), env: [:], ancestor: nil, socket: path) { line, _, _ in
            sent = try Wire.decode(WireMessage.self, line: line.dropLast())
            return nil
        }
        XCTAssertEqual(sent?.kind, .event)
        XCTAssertEqual(sent?.pid, 0)
        XCTAssertNil(sent?.tty)
        XCTAssertNil(sent?.term)
    }

    func testRequestRoundtripRendersAllow() throws {
        let server = SocketServer(path: path)
        defer { server.stop() }
        server.onMessage = { m, id in
            XCTAssertEqual(m.kind, .request)
            XCTAssertEqual(m.pid, 4242)
            XCTAssertEqual(m.tty, "ttys009")
            server.reply(id!, Reply(.allow))
        }
        try server.start()
        let input = stdin("PermissionRequest"), p = path!, info = claude, e = env
        let done = expectation(description: "hook")
        var out: Data?
        DispatchQueue.global().async {
            out = HookRunner.run(stdin: input, env: e, ancestor: info, socket: p)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(out)
        XCTAssertEqual(out, HookOutput.render(Reply(.allow), event: HookEvent(payload: payload("PermissionRequest"))))
    }

    func testRequestPassAndBrokenRepliesPrintNothing() {
        touchSocketFile()
        for answer in [#"{"decision":"pass"}"#, #"{"decision":"maybe"}"#, "garbage", ""] {
            let out = HookRunner.run(stdin: stdin("PermissionRequest"), env: env, ancestor: claude, socket: path) { _, _, wait in
                XCTAssertTrue(wait)
                return Data(answer.utf8)
            }
            XCTAssertNil(out, answer)
        }
        XCTAssertNil(HookRunner.run(stdin: stdin("PermissionRequest"), env: env, ancestor: claude, socket: path) { _, _, _ in
            throw SocketError.system("connect", ECONNREFUSED)
        })
    }

    func testRequestDenyRenders() {
        touchSocketFile()
        let out = HookRunner.run(stdin: stdin("PermissionRequest"), env: env, ancestor: claude, socket: path) { _, _, _ in
            Data(#"{"decision":"deny","message":"nope"}"#.utf8)
        }
        XCTAssertEqual(out, HookOutput.render(Reply(.deny, message: "nope"), event: HookEvent(payload: payload("PermissionRequest"))))
    }
}

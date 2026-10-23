import Darwin
import Foundation
import XCTest
@testable import EarshotCore

final class IPCServerTests: XCTestCase {
    var dir: URL!
    var path: URL!
    var server: SocketServer!

    override func setUp() {
        dir = makeSocketDir()
        path = dir.appendingPathComponent("s.sock")
        server = SocketServer(path: path)
    }

    override func tearDown() {
        server.stop()
        server = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testEventDeliveredOnMain() throws {
        let got = expectation(description: "event")
        server.onMessage = { m, id in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(id)
            XCTAssertEqual(m.kind, .event)
            XCTAssertEqual(m.pid, 4242)
            XCTAssertEqual(m.tty, "ttys001")
            XCTAssertEqual(m.payload["hook_event_name"]?.string, "PostToolUse")
            got.fulfill()
        }
        try server.start()
        XCTAssertNil(try SocketClient.send(wireLine(.event, payload("PostToolUse")), to: path, awaitReply: false))
        wait(for: [got], timeout: 5)
    }

    func testSocketPermissionsAndStopUnlinks() throws {
        let nested = dir.appendingPathComponent("sub/s.sock")
        let s = SocketServer(path: nested)
        try s.start()
        let sockMode = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: nested.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(sockMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        s.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
    }

    func testRequestReplyAllow() throws {
        server.onMessage = { [unowned self] m, id in
            XCTAssertEqual(m.kind, .request)
            XCTAssertNotNil(id)
            self.server.reply(id!, Reply(.allow))
        }
        try server.start()
        let done = expectation(description: "reply")
        let line = wireLine(.request, payload("PermissionRequest"))
        let p = path!
        DispatchQueue.global().async {
            let answer = try? SocketClient.send(line, to: p, awaitReply: true)
            XCTAssertEqual(answer.flatMap { try? Wire.decode(Reply.self, line: $0) }, Reply(.allow))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testPeerCloseBeforeReplyThenReplyIsNoop() throws {
        var requestID: UUID?
        let got = expectation(description: "request")
        let closed = expectation(description: "closed")
        let after = expectation(description: "event after")
        server.onMessage = { m, id in
            if m.kind == .request {
                requestID = id
                got.fulfill()
            } else {
                after.fulfill()
            }
        }
        server.onRequestClosed = { id in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(id, requestID)
            closed.fulfill()
        }
        try server.start()
        let fd = try rawConnect(path)
        XCTAssertTrue(UnixSocket.writeAll(fd, wireLine(.request, payload("PermissionRequest")), waitMs: 1000))
        wait(for: [got], timeout: 5)
        close(fd)
        wait(for: [closed], timeout: 5)
        server.reply(requestID!, Reply(.allow))
        server.reply(UUID(), Reply(.deny))
        _ = try SocketClient.send(wireLine(.event, payload("Stop")), to: path, awaitReply: false)
        wait(for: [after], timeout: 5)
    }

    func testStaleSocketIsReplaced() throws {
        let fd = try UnixSocket.make()
        let addr = try UnixSocket.address(path.path)
        XCTAssertEqual(UnixSocket.withSockaddr(addr) { Darwin.bind(fd, $0, $1) }, 0)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let got = expectation(description: "event")
        server.onMessage = { _, _ in got.fulfill() }
        try server.start()
        _ = try SocketClient.send(wireLine(.event, payload("Stop")), to: path, awaitReply: false)
        wait(for: [got], timeout: 5)
    }

    func testRegularFileAtPathIsNotRemoved() throws {
        FileManager.default.createFile(atPath: path.path, contents: Data("keep".utf8))
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? SocketError, .notASocket(path.path)) }
        XCTAssertEqual(FileManager.default.contents(atPath: path.path), Data("keep".utf8))
    }

    func testSecondLiveServerThrowsAlreadyRunning() throws {
        try server.start()
        let second = SocketServer(path: path)
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? SocketError, .alreadyRunning(path.path)) }
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let got = expectation(description: "first still serves")
        server.onMessage = { _, _ in got.fulfill() }
        _ = try SocketClient.send(wireLine(.event, payload("Stop")), to: path, awaitReply: false)
        wait(for: [got], timeout: 5)
    }

    func testPathTooLongThrows() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        XCTAssertThrowsError(try SocketServer(path: long).start()) { XCTAssertEqual($0 as? SocketError, .pathTooLong(long.path)) }
        XCTAssertThrowsError(try SocketClient.send(Data("{}\n".utf8), to: long, awaitReply: false))
    }

    func testLargePayload() throws {
        let big = String(repeating: "abcdefghij", count: 300_000)
        let got = expectation(description: "big")
        server.onMessage = { m, _ in
            XCTAssertEqual(m.payload["tool_response"]?.string?.utf8.count, big.utf8.count)
            got.fulfill()
        }
        try server.start()
        let line = wireLine(.event, payload("PostToolUse", extra: ["tool_response": .string(big)]))
        XCTAssertGreaterThan(line.count, 3_000_000)
        let p = path!
        DispatchQueue.global().async { _ = try? SocketClient.send(line, to: p, awaitReply: false) }
        wait(for: [got], timeout: 10)
    }

    func testGarbageAndWrongVersionAreDropped() throws {
        var count = 0
        let good = expectation(description: "good")
        server.onMessage = { m, _ in
            count += 1
            XCTAssertEqual(m.payload["hook_event_name"]?.string, "Stop")
            good.fulfill()
        }
        try server.start()
        for bad in [Data("garbage\n".utf8), Data("{\"v\":1}\n".utf8), wireLine(.event, payload("PreToolUse"), v: 2)] {
            let fd = try rawConnect(path)
            XCTAssertTrue(UnixSocket.writeAll(fd, bad, waitMs: 1000))
            XCTAssertEqual(readToEOF(fd), Data())
            close(fd)
        }
        _ = try SocketClient.send(wireLine(.event, payload("Stop")), to: path, awaitReply: false)
        wait(for: [good], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(count, 1)
    }

    func testOversizedLineClosesConnection() throws {
        server.onMessage = { _, _ in XCTFail("nothing should be delivered") }
        try server.start()
        let fd = try rawConnect(path)
        let p = path!
        let done = expectation(description: "closed")
        DispatchQueue.global().async {
            _ = UnixSocket.writeAll(fd, Data(repeating: 0x41, count: SocketServer.maxLine + 200_000), waitMs: 2000)
            _ = readToEOF(fd)
            close(fd)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.path))
    }

    func testStopClosesPendingRequests() throws {
        let got = expectation(description: "request")
        server.onMessage = { _, _ in got.fulfill() }
        try server.start()
        let fd = try rawConnect(path)
        XCTAssertTrue(UnixSocket.writeAll(fd, wireLine(.request, payload("PermissionRequest")), waitMs: 1000))
        wait(for: [got], timeout: 5)
        server.stop()
        XCTAssertEqual(readToEOF(fd), Data())
        close(fd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}

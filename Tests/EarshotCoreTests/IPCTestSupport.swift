import Darwin
import Foundation
import XCTest
@testable import EarshotCore

func makeSocketDir() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("es-" + UUID().uuidString.prefix(8))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func rawConnect(_ path: URL) throws -> Int32 {
    let addr = try UnixSocket.address(path.path)
    let fd = try UnixSocket.make()
    guard UnixSocket.connect(fd, addr) else {
        close(fd)
        throw SocketError.system("connect", errno)
    }
    return fd
}

func readToEOF(_ fd: Int32) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return out }
        out.append(contentsOf: buf[0..<n])
    }
}

func wireLine(_ kind: WireKind, _ payload: JSONValue, v: Int = Wire.version, tty: String? = "ttys001") -> Data {
    try! Wire.line(WireMessage(v: v, kind: kind, pid: 4242, tty: tty, term: "Apple_Terminal", payload: payload))
}

func payload(_ name: String, tool: String = "Bash", extra: [String: JSONValue] = [:]) -> JSONValue {
    var o: [String: JSONValue] = [
        "hook_event_name": .string(name),
        "session_id": .string("s-1"),
        "cwd": .string("/tmp/proj"),
        "tool_name": .string(tool),
        "tool_input": .object(["command": .string("ls -la")]),
    ]
    for (k, v) in extra { o[k] = v }
    return .object(o)
}

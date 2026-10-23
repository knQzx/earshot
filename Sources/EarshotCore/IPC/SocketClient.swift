import Darwin
import Foundation

public enum SocketClient {
    public static let maxReply = 1 << 20
    public static var acceptPeer: ((pid_t) -> Bool)?

    public static func send(_ line: Data, to socket: URL, awaitReply: Bool) throws -> Data? {
        let addr = try UnixSocket.address(socket.path)
        let fd = try UnixSocket.make()
        defer { close(fd) }
        guard UnixSocket.connect(fd, addr) else { throw SocketError.system("connect", errno) }
        if let accept = acceptPeer {
            let pid = peerPID(fd)
            guard pid > 0, accept(pid) else { throw SocketError.untrustedPeer(pid) }
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard UnixSocket.writeAll(fd, line, waitMs: 0) else { throw SocketError.system("write", errno) }
        return awaitReply ? readLine(fd) : nil
    }

    public static func peerPID(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return 0 }
        return pid
    }

    static func readLine(_ fd: Int32) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count <= maxReply {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
        }
        return out.isEmpty || out.count > maxReply ? nil : out
    }
}

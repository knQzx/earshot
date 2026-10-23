import Darwin
import Foundation

public enum SocketError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case alreadyRunning(String)
    case pathTooLong(String)
    case notASocket(String)
    case system(String, Int32)
    case untrustedPeer(Int32)

    public var description: String {
        switch self {
        case .alreadyRunning(let p): return "another Earshot is already listening on \(p)"
        case .pathTooLong(let p): return "socket path is longer than \(UnixSocket.maxPathBytes) bytes: \(p)"
        case .notASocket(let p): return "\(p) exists and is not a socket"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .untrustedPeer(let pid): return "the socket is held by process \(pid), which is not Earshot"
        }
    }

    public var errorDescription: String? { description }
}

enum UnixSocket {
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes else { throw SocketError.pathTooLong(path) }
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func withSockaddr<R>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var a = addr
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        setNoSigPipe(fd)
        return fd
    }

    static func connect(_ fd: Int32, _ addr: sockaddr_un) -> Bool {
        while true {
            let r = withSockaddr(addr) { Darwin.connect(fd, $0, $1) }
            if r == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func writeAll(_ fd: Int32, _ data: Data, waitMs: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 {
                    off += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && errno == EAGAIN {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, waitMs) <= 0 { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }
}

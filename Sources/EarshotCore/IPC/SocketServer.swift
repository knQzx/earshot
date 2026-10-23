import Darwin
import Foundation

public final class SocketServer {
    public static let maxLine = 16 << 20

    public var onMessage: ((WireMessage, UUID?) -> Void)?
    public var onRequestClosed: ((UUID) -> Void)?
    public var onQuery: (() -> Data?)?

    private let path: URL
    private let queue = DispatchQueue(label: "io.github.knqzx.earshot.socket")
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: DispatchSourceRead?
    private var boundInode: ino_t?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var pending: [UUID: Conn] = [:]
    private var scratch = [UInt8](repeating: 0, count: 64 << 10)

    private final class Conn {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var scanned = 0
        var requestID: UUID?

        init(fd: Int32) { self.fd = fd }
    }

    public init(path: URL = Paths.socket) {
        self.path = path
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        shutdown()
    }

    public func start() throws {
        try onQueue { try startLocked() }
    }

    public func stop() {
        onQueue { shutdown() }
    }

    public func reply(_ requestID: UUID, _ reply: Reply) {
        queue.async { [weak self] in
            guard let self, let c = self.pending.removeValue(forKey: requestID) else { return }
            if let line = try? Wire.line(reply) { _ = UnixSocket.writeAll(c.fd, line, waitMs: 1000) }
            self.drop(c)
        }
    }

    private func onQueue<R>(_ body: () throws -> R) rethrows -> R {
        DispatchQueue.getSpecific(key: queueKey) != nil ? try body() : try queue.sync(execute: body)
    }

    private func startLocked() throws {
        guard listener == nil else { return }
        let p = path.path
        let addr = try UnixSocket.address(p)
        let dir = path.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try clearStale(p, addr)

        let fd = try UnixSocket.make()
        let bound = UnixSocket.withSockaddr(addr) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw SocketError.system("bind", e)
        }
        if chmod(p, 0o600) != 0 || listen(fd, 64) != 0 {
            let e = errno
            close(fd)
            unlink(p)
            throw SocketError.system("listen", e)
        }
        UnixSocket.setNonBlocking(fd)
        var st = stat()
        boundInode = lstat(p, &st) == 0 ? st.st_ino : nil

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(fd) }
        src.setCancelHandler { close(fd) }
        listener = src
        src.resume()
    }

    private func clearStale(_ p: String, _ addr: sockaddr_un) throws {
        var st = stat()
        guard lstat(p, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw SocketError.notASocket(p) }
        let probe = try UnixSocket.make()
        let live = UnixSocket.connect(probe, addr)
        close(probe)
        if live { throw SocketError.alreadyRunning(p) }
        guard unlink(p) == 0 || errno == ENOENT else { throw SocketError.system("unlink", errno) }
    }

    private func shutdown() {
        listener?.cancel()
        listener = nil
        for c in conns.values { c.source?.cancel() }
        conns.removeAll()
        pending.removeAll()
        if let ino = boundInode {
            var st = stat()
            if lstat(path.path, &st) == 0, st.st_ino == ino { unlink(path.path) }
            boundInode = nil
        }
    }

    private func acceptAll(_ lfd: Int32) {
        while true {
            let fd = accept(lfd, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            UnixSocket.setNonBlocking(fd)
            UnixSocket.setNoSigPipe(fd)
            let c = Conn(fd: fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self, weak c] in
                guard let self, let c else { return }
                self.readable(c)
            }
            src.setCancelHandler { close(fd) }
            c.source = src
            conns[ObjectIdentifier(c)] = c
            src.resume()
        }
    }

    private func readable(_ c: Conn) {
        while conns[ObjectIdentifier(c)] != nil {
            let n = scratch.withUnsafeMutableBytes { Darwin.read(c.fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { return }
            if n <= 0 {
                peerGone(c)
                return
            }
            if c.requestID != nil { continue }
            scratch.withUnsafeBufferPointer { c.buffer.append($0.baseAddress!, count: n) }
            let tail = c.buffer[(c.buffer.startIndex + c.scanned)...]
            if let nl = tail.firstIndex(of: 0x0A) {
                let line = c.buffer[c.buffer.startIndex..<nl]
                c.buffer = Data()
                if line.count > Self.maxLine { drop(c) } else { handle(Data(line), from: c) }
            } else if c.buffer.count > Self.maxLine {
                drop(c)
            } else {
                c.scanned = c.buffer.count
            }
        }
    }

    private func handle(_ line: Data, from c: Conn) {
        guard let m = try? Wire.decode(WireMessage.self, line: line), m.v == Wire.version else {
            drop(c)
            return
        }
        switch m.kind {
        case .event, .debug:
            drop(c)
            DispatchQueue.main.async { [weak self] in self?.onMessage?(m, nil) }
        case .request:
            let id = UUID()
            c.requestID = id
            pending[id] = c
            DispatchQueue.main.async { [weak self] in self?.onMessage?(m, id) }
        case .query:
            c.requestID = UUID()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var out = self.onQuery?() ?? Data("[]".utf8)
                out.append(0x0A)
                self.queue.async {
                    guard self.conns[ObjectIdentifier(c)] != nil else { return }
                    _ = UnixSocket.writeAll(c.fd, out, waitMs: 1000)
                    self.drop(c)
                }
            }
        }
    }

    private func peerGone(_ c: Conn) {
        if let id = c.requestID, pending.removeValue(forKey: id) != nil {
            DispatchQueue.main.async { [weak self] in self?.onRequestClosed?(id) }
        }
        drop(c)
    }

    private func drop(_ c: Conn) {
        guard conns.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        if let id = c.requestID { pending.removeValue(forKey: id) }
        c.source?.cancel()
        c.source = nil
    }
}

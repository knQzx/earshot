import EarshotCore
import Foundation

final class ProcessScanner: ProcessScanning {
    private let queue = DispatchQueue(label: "io.github.knqzx.earshot.scan", qos: .utility)
    private let meta = ClaudeMetaReader()

    func scan(_ done: @escaping ([ClaudeProcess]) -> Void) {
        queue.async { [meta] in
            let procs = Proc.claudeProcesses().map { p -> ClaudeProcess in
                var p = p
                p.meta = meta.meta(pid: p.pid, processStart: p.startedAt)
                return p
            }
            meta.prune(keeping: Set(procs.compactMap { $0.meta?.sessionID }))
            DispatchQueue.main.async { done(procs) }
        }
    }

    func isAlive(_ pid: Int32) -> Bool {
        Proc.isAlive(pid)
    }
}

import EarshotCore
import Foundation

final class SampleScanner: ProcessScanning {
    func scan(_ done: @escaping ([ClaudeProcess]) -> Void) {
        done([])
    }

    func isAlive(_ pid: Int32) -> Bool {
        SampleAgent.all.contains { $0.pid == pid }
    }
}

final class SampleJumper: TerminalJumping {
    func jump(to session: Session, done: @escaping (JumpProblem?) -> Void) {
        print("[sample] jump to \(session.projectName) on \(session.tty ?? "?")")
        fflush(stdout)
        done(nil)
    }
}

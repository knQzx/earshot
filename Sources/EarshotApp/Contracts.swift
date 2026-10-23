import EarshotCore
import Foundation

protocol EventSource: AnyObject {
    var onMessage: ((WireMessage, UUID?) -> Void)? { get set }
    var onRequestClosed: ((UUID) -> Void)? { get set }
    func start() throws
    func stop()
    func reply(_ requestID: UUID, _ reply: Reply)
}

protocol ProcessScanning: AnyObject {
    func scan(_ done: @escaping ([ClaudeProcess]) -> Void)
    func isAlive(_ pid: Int32) -> Bool
}

struct JumpProblem: Equatable {
    var app: String
    var denied: Bool
}

protocol TerminalJumping: AnyObject {
    func jump(to session: Session, done: @escaping (JumpProblem?) -> Void)
}

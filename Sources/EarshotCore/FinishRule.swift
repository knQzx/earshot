import Foundation

public enum FinishRule {
    public static func fires(from previous: DisplayStatus, to current: DisplayStatus, session: Session) -> Bool {
        guard current == .waiting, session.unseen, session.sessionID != nil else { return false }
        switch previous {
        case .working, .stalled, .permission, .question: return true
        default: return false
        }
    }
}

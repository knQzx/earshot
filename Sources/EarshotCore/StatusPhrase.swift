import Foundation

public enum StatusPhrase {
    public static func parts(_ s: Session, display: DisplayStatus, now: Date) -> (label: String, time: String?) {
        let since = now.timeIntervalSince(display == .stalled ? s.lastEventAt : s.statusSince)
        let t = duration(since)
                switch display {
        case .permission: return ("Needs approval", t)
        case .question: return ("Needs an answer", t)
        case .waiting: return s.unseen ? ("Ready for review", t) : ("Idle", t)
        case .working: return ("Working", t)
        case .stalled: return ("No activity", t)
        case .idle: return s.activity == "interrupted" ? ("Interrupted", t) : ("Idle", t)
        case .error: return ("Stopped", nil)
        case .unknown: return ("No data yet", nil)
        }
    }

    public static func text(_ s: Session, display: DisplayStatus, now: Date) -> String {
        let since = now.timeIntervalSince(display == .stalled ? s.lastEventAt : s.statusSince)
        let d = duration(since)
                switch display {
        case .permission:
            return "Waiting for approval" + " · " + d
        case .question:
            return "Waiting for your answer" + " · " + d
        case .waiting:
            return s.unseen
                ? "Ready for review" + " · " + d
                : "Idle" + " · " + d
        case .working:
            return "Working" + " · " + d
        case .stalled:
            return "No activity" + " · " + d
        case .idle:
            if s.activity == "interrupted" { return "Interrupted" + " · " + d }
            return "Idle" + " · " + d
        case .error:
            let why = s.activity.map { ": " + $0 } ?? ""
            return "Stopped" + why
        case .unknown:
            return "No data yet"
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
                if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        if h < 24 {
            if r == 0 { return "\(h) h" }
            return "\(h) h \(r) min"
        }
        let days = h / 24
        return "\(days) d"
    }
}

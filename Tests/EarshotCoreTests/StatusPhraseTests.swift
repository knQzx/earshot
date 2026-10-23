import XCTest
@testable import EarshotCore

final class StatusPhraseTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 10_000)

    func make(_ status: SessionStatus, ago: TimeInterval, activity: String? = nil) -> Session {
        var s = Session(id: "pid:1", pid: 1, cwd: "/p", now: t0.addingTimeInterval(-ago))
        s.status = status
        s.activity = activity
        return s
    }

    func phrase(_ s: Session) -> String {
        StatusPhrase.text(s, display: s.display(now: t0), now: t0)
    }

    func testDurations() {
        XCTAssertEqual(StatusPhrase.duration(12), "just now")
        XCTAssertEqual(StatusPhrase.duration(5 * 60 + 10), "5 min")
        XCTAssertEqual(StatusPhrase.duration(3600), "1 h")
        XCTAssertEqual(StatusPhrase.duration(80 * 60), "1 h 20 min")
        XCTAssertEqual(StatusPhrase.duration(50 * 3600), "2 d")
    }

    func testWaitingIsReviewUntilSeenThenIdle() {
        var s = make(.waiting, ago: 180)
        XCTAssertEqual(phrase(s), "Ready for review · 3 min")
        s.seenAt = t0
        XCTAssertEqual(phrase(s), "Idle · 3 min")
        XCTAssertEqual(phrase(s), "Idle · 3 min")
    }

    func testAttentionAndStalled() {
        XCTAssertEqual(phrase(make(.permission, ago: 300)), "Waiting for approval · 5 min")
        XCTAssertEqual(phrase(make(.question, ago: 30)), "Waiting for your answer · just now")
        XCTAssertEqual(phrase(make(.working, ago: 420)), "No activity · 7 min")
        XCTAssertEqual(phrase(make(.working, ago: 120)), "Working · 2 min")
        XCTAssertEqual(phrase(make(.idle, ago: 60, activity: "interrupted")), "Interrupted · 1 min")
        XCTAssertEqual(phrase(make(.error, ago: 5, activity: "Rate limit reached")), "Stopped: Rate limit reached")
        XCTAssertEqual(phrase(make(.unknown, ago: 5)), "No data yet")
    }

    func testParts() {
        let p = StatusPhrase.parts(make(.permission, ago: 120), display: .permission, now: t0)
        XCTAssertEqual(p.label, "Needs approval")
        XCTAssertEqual(p.time, "2 min")
        var r = make(.waiting, ago: 30)
        XCTAssertEqual(StatusPhrase.parts(r, display: .waiting, now: t0).label, "Ready for review")
        r.seenAt = t0
        XCTAssertEqual(StatusPhrase.parts(r, display: .waiting, now: t0).label, "Idle")
        XCTAssertNil(StatusPhrase.parts(make(.unknown, ago: 1), display: .unknown, now: t0).time)
    }

    func testMarkSeenOnStore() {
        var store = SessionStore()
        let p: JSONValue = .object(["hook_event_name": .string("Stop"), "session_id": .string("x"), "cwd": .string("/p")])
        store.ingest(WireMessage(kind: .event, pid: 5, tty: "ttys001", term: nil, payload: p), now: t0)
        XCTAssertTrue(store.sessions["pid:5"]!.unseen)
        store.markSeen(id: "pid:5", now: t0.addingTimeInterval(1))
        XCTAssertFalse(store.sessions["pid:5"]!.unseen)
    }
}

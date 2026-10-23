import XCTest
@testable import EarshotCore

final class FinishRuleTests: XCTestCase {
    private func session(sid: String? = "s1", seenAt: Date? = nil) -> Session {
        let now = Date()
        var s = Session(id: "pid:1", pid: 1, cwd: "/tmp/project", now: now)
        s.sessionID = sid
        s.status = .waiting
        s.statusSince = now
        s.seenAt = seenAt
        return s
    }

    func testFiresWhenWorkSettles() {
        for prev in [DisplayStatus.working, .stalled, .permission, .question] {
            XCTAssertTrue(FinishRule.fires(from: prev, to: .waiting, session: session()), "\(prev)")
        }
    }

    func testIgnoresOtherTransitions() {
        XCTAssertFalse(FinishRule.fires(from: .idle, to: .waiting, session: session()))
        XCTAssertFalse(FinishRule.fires(from: .unknown, to: .waiting, session: session()))
        XCTAssertFalse(FinishRule.fires(from: .error, to: .waiting, session: session()))
        XCTAssertFalse(FinishRule.fires(from: .working, to: .idle, session: session()))
    }

    func testNeedsHooksAndUnseen() {
        XCTAssertFalse(FinishRule.fires(from: .working, to: .waiting, session: session(sid: nil)))
        XCTAssertFalse(FinishRule.fires(from: .working, to: .waiting, session: session(seenAt: Date().addingTimeInterval(60))))
    }
}

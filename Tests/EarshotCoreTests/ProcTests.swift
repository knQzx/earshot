import XCTest
@testable import EarshotCore

final class ProcTests: XCTestCase {
    func testSelfInfo() {
        let me = getpid()
        let i = Proc.info(me)
        XCTAssertEqual(i?.pid, me)
        XCTAssertNotNil(Proc.path(me))
        XCTAssertNotNil(Proc.cwd(me))
        XCTAssertFalse(Proc.args(me).isEmpty)
        XCTAssertTrue(Proc.isAlive(me))
        XCTAssertFalse(Proc.isClaude(me))
    }

    func testLiveScanPrints() {
        for p in Proc.claudeProcesses() { print("claude", p.pid, p.tty ?? "-", p.cwd) }
    }
}

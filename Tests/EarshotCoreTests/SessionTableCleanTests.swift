import XCTest
@testable import EarshotCore

final class SessionTableCleanTests: XCTestCase {
    func testStripsEscapesAndControls() {
        XCTAssertEqual(SessionTable.clean("a\u{1B}[31mred\u{1B}[0m b"), "ared b")
        XCTAssertEqual(SessionTable.clean("t\u{1B}]0;title\u{07}x"), "tx")
        XCTAssertEqual(SessionTable.clean("line1\nline2\tz"), "line1 line2 z")
        XCTAssertEqual(SessionTable.clean("bell\u{07}\u{9B}2Jok\u{85}"), "bellok")
        XCTAssertEqual(SessionTable.clean("плюс ünïcode ✓"), "плюс ünïcode ✓")
    }
}

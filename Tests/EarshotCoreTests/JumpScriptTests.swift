import XCTest
@testable import EarshotCore

final class JumpScriptTests: XCTestCase {
    func testTTYValidation() {
        XCTAssertEqual(JumpScript.normalizedTTY("ttys002"), "ttys002")
        XCTAssertEqual(JumpScript.normalizedTTY("/dev/ttys014"), "ttys014")
        XCTAssertEqual(JumpScript.normalizedTTY("tty1"), "tty1")
        for bad in [nil, "", "ttys", "pts/3", "ttys002 ", "ttys002\"\ndo shell script \"rm -rf ~", "/dev/../ttys002", "console", "ttyp1"] {
            XCTAssertNil(JumpScript.normalizedTTY(bad), String(describing: bad))
        }
    }

    func testScriptsEmbedOnlyValidTTY() throws {
        let t = try XCTUnwrap(JumpScript.terminal(tty: "ttys004"))
        XCTAssertTrue(t.contains("tell application id \"com.apple.Terminal\""))
        XCTAssertTrue(t.contains("if tty of t is \"/dev/ttys004\" then"))
        XCTAssertTrue(t.contains("set selected tab of w to tab n of w"))
        XCTAssertTrue(t.contains("activate"))
        let dry = try XCTUnwrap(JumpScript.terminal(tty: "/dev/ttys004", dryRun: true))
        XCTAssertFalse(dry.contains("set "+"selected"))
        XCTAssertFalse(dry.contains("activate"))
        XCTAssertFalse(dry.contains("set index"))
        XCTAssertNil(JumpScript.terminal(tty: "ttys004\" & quit"))

        let i = try XCTUnwrap(JumpScript.iTerm(tty: "ttys009"))
        XCTAssertTrue(i.contains("tell application id \"com.googlecode.iterm2\""))
        XCTAssertTrue(i.contains("if tty of s is \"/dev/ttys009\" then"))
        XCTAssertFalse(try XCTUnwrap(JumpScript.iTerm(tty: "ttys009", dryRun: true)).contains("activate"))
        XCTAssertNil(JumpScript.iTerm(tty: "x"))
    }

    func testTmuxPaneLookup() {
        let listing = """
        /dev/ttys010 $0 @0 %0
        /dev/ttys011 $0 @1 %3
        /dev/ttys012 $2 @4 %7
        garbage line
        """
        XCTAssertEqual(JumpScript.tmuxPane(listing: listing, tty: "ttys011"), .init(session: "$0", window: "@1", pane: "%3"))
        XCTAssertEqual(JumpScript.tmuxPane(listing: listing, tty: "/dev/ttys012")?.pane, "%7")
        XCTAssertNil(JumpScript.tmuxPane(listing: listing, tty: "ttys013"))
        XCTAssertNil(JumpScript.tmuxPane(listing: listing, tty: "../x"))
    }

    func testTmuxClientChoice() throws {
        let clients = JumpScript.tmuxClients(listing: """
        /dev/ttys001 $0 1700000100 501
        /dev/ttys002 $2 1700000050 502
        /dev/ttys003 $2 1700000090 503
        bad
        """)
        XCTAssertEqual(clients.count, 3)
        let same = try XCTUnwrap(JumpScript.bestClient(clients, session: "$2"))
        XCTAssertEqual(same.client.tty, "ttys003")
        XCTAssertEqual(same.client.pid, 503)
        XCTAssertFalse(same.needsSwitch)
        let other = try XCTUnwrap(JumpScript.bestClient(clients, session: "$9"))
        XCTAssertEqual(other.client.tty, "ttys001")
        XCTAssertTrue(other.needsSwitch)
        XCTAssertNil(JumpScript.bestClient([], session: "$0"))
    }

    func testTmuxSocketArgs() {
        XCTAssertEqual(JumpScript.tmuxSocketArgs(serverArgs: ["tmux", "new", "-s", "work"]), [])
        XCTAssertEqual(JumpScript.tmuxSocketArgs(serverArgs: ["tmux", "-L", "work", "new"]), ["-L", "work"])
        XCTAssertEqual(JumpScript.tmuxSocketArgs(serverArgs: ["/opt/homebrew/bin/tmux", "-f", "/x.conf", "-S", "/tmp/s", "attach"]), ["-S", "/tmp/s"])
        XCTAssertEqual(JumpScript.tmuxSocketArgs(serverArgs: ["tmux", "new", "-L", "late"]), [])
    }
}

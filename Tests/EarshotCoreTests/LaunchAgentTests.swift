import XCTest
@testable import EarshotCore

final class LaunchAgentTests: XCTestCase {
    var dir: URL!
    let exe = "/Users/dev/Applications/Earshot.app/Contents/MacOS/Earshot"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-agents-\(UUID().uuidString)/LaunchAgents")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    func testEnableWritesPlist() throws {
        let agent = LaunchAgent(directory: dir, executable: exe)
        XCTAssertFalse(agent.isEnabled)
        try agent.setEnabled(true)
        XCTAssertTrue(agent.isEnabled)
        XCTAssertEqual(agent.plistURL.lastPathComponent, "io.github.knqzx.earshot.plist")
        let data = try Data(contentsOf: agent.plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, "io.github.knqzx.earshot")
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], [exe])
        XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist?["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist?.count, 4)
        try agent.setEnabled(true)
        XCTAssertTrue(agent.isEnabled)
    }

    func testOtherBundleIsNotEnabled() throws {
        try LaunchAgent(directory: dir, executable: "/Applications/Earshot.app/Contents/MacOS/Earshot").setEnabled(true)
        let agent = LaunchAgent(directory: dir, executable: exe)
        XCTAssertFalse(agent.isEnabled)
        try agent.setEnabled(true)
        XCTAssertTrue(agent.isEnabled)
    }

    func testDisableRemovesPlist() throws {
        let agent = LaunchAgent(directory: dir, executable: exe)
        try agent.setEnabled(false)
        try agent.setEnabled(true)
        try agent.setEnabled(false)
        XCTAssertFalse(agent.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plistURL.path))
    }

    func testGarbagePlistIsNotEnabled() throws {
        let agent = LaunchAgent(directory: dir, executable: exe)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: agent.plistURL)
        XCTAssertFalse(agent.isEnabled)
    }
}

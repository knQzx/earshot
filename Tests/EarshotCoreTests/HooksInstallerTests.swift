import XCTest
@testable import EarshotCore

final class HooksInstallerTests: XCTestCase {
    let hook = "/Users/dev/Applications/Earshot.app/Contents/MacOS/earshot-hook"
    var dir: URL!
    var url: URL!
    var backup: URL { dir.appendingPathComponent("settings.json.earshot-backup") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ text: String) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func groups(_ event: String) throws -> [[String: Any]] {
        (try json()["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    func commands(_ event: String) throws -> [String] {
        try groups(event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func status(_ cmd: String? = nil) -> HookInstallState {
        HooksInstaller.status(hookCommand: cmd ?? hook, settingsURL: url)
    }

    func dirListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    let thirdParty = """
    {
      "model": "opus",
      "env": {"ANTHROPIC_LOG": "debug"},
      "permissions": {"allow": ["Bash(git status)", "Read(/Users/dev/**)"], "defaultMode": "default"},
      "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"},
      "alwaysThinkingEnabled": true,
      "cleanupPeriodDays": 30,
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/guard.sh", "timeout": 5}]}
        ],
        "Stop": [
          {"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}
        ],
        "SubagentStop": [
          {"matcher": "*", "hooks": [{"type": "command", "command": "say done"}]}
        ]
      }
    }
    """

    func testInstallIntoMissingFile() throws {
        XCTAssertEqual(status(), .notInstalled)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)
        XCTAssertEqual(try dirListing(), ["settings.json"])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for event in HooksInstaller.events {
            let g = try groups(event)
            XCTAssertEqual(g.count, 1, event)
            XCTAssertEqual(g[0]["matcher"] as? String, "*")
            let h = (g[0]["hooks"] as? [[String: Any]])?.first
            XCTAssertEqual(h?["type"] as? String, "command")
            XCTAssertEqual(h?["command"] as? String, "\"\(hook)\"")
            XCTAssertEqual((h?["timeout"] as? NSNumber)?.intValue, ["PermissionRequest", "PreToolUse"].contains(event) ? 86400 : 10)
        }
    }

    func testInstallCreatesMissingDirectory() throws {
        url = dir.appendingPathComponent("nested/config/settings.json")
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)
    }

    func testOutputFormatting() throws {
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("/Users/dev/Applications/Earshot.app/Contents/MacOS/earshot-hook"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.hasPrefix("{\n  \"hooks\""))
        XCTAssertTrue(text.hasSuffix("}\n"))
        let n = text.range(of: "\"Notification\"")!.lowerBound
        let p = text.range(of: "\"PermissionRequest\"")!.lowerBound
        XCTAssertLessThan(n, p)
    }

    func testPreservesUnrelatedKeysAndThirdPartyHooks() throws {
        try write(thirdParty)
        let before = try json()
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        let after = try json()
        for k in ["model", "env", "permissions", "statusLine", "alwaysThinkingEnabled", "cleanupPeriodDays"] {
            XCTAssertEqual(after[k] as? NSObject, before[k] as? NSObject, k)
        }
        XCTAssertEqual(after["alwaysThinkingEnabled"] as? Bool, true)
        XCTAssertEqual(try commands("PreToolUse"), ["/usr/local/bin/guard.sh", "\"\(hook)\""])
        XCTAssertEqual(try groups("PreToolUse")[0]["matcher"] as? String, "Bash")
        XCTAssertEqual(try commands("Stop"), ["afplay /System/Library/Sounds/Glass.aiff", "\"\(hook)\""])
        XCTAssertNil(try groups("Stop")[0]["matcher"])
        XCTAssertEqual(try commands("SubagentStop"), ["say done"])
        XCTAssertEqual(status(), .installed)
    }

    func testIdempotentInstall() throws {
        try write(thirdParty)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        let first = try Data(contentsOf: url)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(try Data(contentsOf: url), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(try commands("PreToolUse").filter { $0.contains("earshot-hook") }.count, 1)
    }

    func testStatusTransitions() throws {
        XCTAssertEqual(status(), .notInstalled)
        try write(thirdParty)
        XCTAssertEqual(status(), .notInstalled)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)

        let moved = "/Applications/Earshot.app/Contents/MacOS/earshot-hook"
        XCTAssertEqual(status(moved), .outdated)
        try HooksInstaller.install(hookCommand: moved, settingsURL: url)
        XCTAssertEqual(status(moved), .installed)
        XCTAssertEqual(status(), .outdated)
        XCTAssertEqual(try commands("Stop").filter { $0.contains("earshot-hook") }, ["\"\(moved)\""])
    }

    func testOutdatedWhenEventMissingOrChanged() throws {
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        var root = try json()
        var hooks = root["hooks"] as! [String: Any]
        hooks["StopFailure"] = nil
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertEqual(status(), .outdated)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)

        try write(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "86400", with: "600"))
        XCTAssertEqual(status(), .outdated)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)
    }

    func testOutdatedWhenDuplicatedOrStrayEvent() throws {
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        var root = try json()
        var hooks = root["hooks"] as! [String: Any]
        hooks["SubagentStop"] = [["matcher": "*", "hooks": [["type": "command", "command": "\"\(hook)\"", "timeout": 10]]]]
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertEqual(status(), .outdated)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)
        XCTAssertTrue(try groups("SubagentStop").isEmpty)

        var stop = try groups("Stop")
        stop.append(stop[0])
        root = try json()
        hooks = root["hooks"] as! [String: Any]
        hooks["Stop"] = stop
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertEqual(status(), .outdated)
    }

    func testOldStyleEntryIsReplaced() throws {
        try write("""
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "/old/place/earshot-hook --legacy"},
          {"type": "command", "command": "say bye"}
        ]}]}}
        """)
        XCTAssertEqual(status(), .outdated)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(try commands("Stop"), ["say bye", "\"\(hook)\""])
        XCTAssertEqual(status(), .installed)
    }

    func testUninstallCleansUpFully() throws {
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        try HooksInstaller.uninstall(settingsURL: url)
        XCTAssertEqual(status(), .notInstalled)
        XCTAssertTrue(try json().isEmpty)
    }

    func testUninstallKeepsThirdParty() throws {
        try write(thirdParty)
        let before = try json()
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        try HooksInstaller.uninstall(settingsURL: url)
        XCTAssertEqual(try json() as NSDictionary, before as NSDictionary)
        XCTAssertEqual(status(), .notInstalled)
    }

    func testUninstallMixedGroupKeepsOtherHandler() throws {
        try write("""
        {"hooks": {"Notification": [{"matcher": "*", "hooks": [
          {"type": "command", "command": "\\"\(hook)\\"", "timeout": 10},
          {"type": "command", "command": "terminal-notifier -message hi"}
        ]}], "Stop": [{"hooks": [{"type": "command", "command": "\\"\(hook)\\""}]}]}, "theme": "dark"}
        """)
        try HooksInstaller.uninstall(settingsURL: url)
        let root = try json()
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual(try commands("Notification"), ["terminal-notifier -message hi"])
        XCTAssertEqual(try groups("Notification")[0]["matcher"] as? String, "*")
        XCTAssertNil((root["hooks"] as? [String: Any])?["Stop"])
    }

    func testUninstallWithoutOurHooksDoesNotWrite() throws {
        try write(thirdParty)
        let before = try Data(contentsOf: url)
        try HooksInstaller.uninstall(settingsURL: url)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try dirListing(), ["settings.json"])

        let missing = dir.appendingPathComponent("absent/settings.json")
        try HooksInstaller.uninstall(settingsURL: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testInvalidJSONThrowsAndLeavesFileUntouched() throws {
        let broken = "{\n  \"model\": \"opus\",\n  // comment\n  \"hooks\": {}\n}\n"
        try write(broken)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try HooksInstaller.install(hookCommand: hook, settingsURL: url)) { err in
            XCTAssertEqual(err as? HooksInstallerError, .invalidSettings("not valid JSON"))
        }
        XCTAssertThrowsError(try HooksInstaller.uninstall(settingsURL: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try dirListing(), ["settings.json"])
        XCTAssertEqual(status(), .notInstalled)
    }

    func testWrongShapesThrow() throws {
        for text in ["[1, 2]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {\"command\": \"x\"}}}"] {
            try write(text)
            XCTAssertThrowsError(try HooksInstaller.install(hookCommand: hook, settingsURL: url), text)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        }
    }

    func testEmptyFileTreatedAsEmptyObject() throws {
        try write("  \n")
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(status(), .installed)
    }

    func testBackupCreatedOnce() throws {
        try write(thirdParty)
        let original = try Data(contentsOf: url)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        try HooksInstaller.uninstall(settingsURL: url)
        try HooksInstaller.install(hookCommand: "/elsewhere/earshot-hook", settingsURL: url)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try dirListing(), ["settings.json", "settings.json.earshot-backup"])
    }

    func testKeepsFilePermissions() throws {
        try write(thirdParty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testSymlinkedSettingsStayLinked() throws {
        let real = dir.appendingPathComponent("dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try thirdParty.data(using: .utf8)!.write(to: real)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), real.path)
        XCTAssertEqual(status(), .installed)
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("earshot-hook"))
    }

    func testNumbersAndUnicodeSurvive() throws {
        try write(#"{"cleanupPeriodDays": 30, "ratio": 0.25, "big": 9007199254740993, "flag": false, "name": "Кирилл ✓", "nothing": null}"#)
        try HooksInstaller.install(hookCommand: hook, settingsURL: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"cleanupPeriodDays\" : 30"))
        XCTAssertTrue(text.contains("\"ratio\" : 0.25"))
        XCTAssertTrue(text.contains("\"big\" : 9007199254740993"))
        XCTAssertTrue(text.contains("\"flag\" : false"))
        XCTAssertTrue(text.contains("\"name\" : \"Кирилл ✓\""))
        XCTAssertTrue(text.contains("\"nothing\" : null"))
    }

    func testCommandQuoting() {
        XCTAssertEqual(HooksInstaller.command(for: "/Applications/My Apps/Earshot.app/Contents/MacOS/earshot-hook"),
                       "\"/Applications/My Apps/Earshot.app/Contents/MacOS/earshot-hook\"")
        XCTAssertEqual(HooksInstaller.command(for: "/Users/a$b/\"q\"/earshot-hook"), #""/Users/a\$b/\"q\"/earshot-hook""#)
        XCTAssertEqual(HooksInstaller.command(for: "\"/already/quoted/earshot-hook\""), "\"/already/quoted/earshot-hook\"")
    }
}

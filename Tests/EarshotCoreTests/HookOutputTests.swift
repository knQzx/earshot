import Foundation
import XCTest
@testable import EarshotCore

final class HookOutputTests: XCTestCase {
    let suggestions: JSONValue = .array([.object([
        "type": .string("addRules"),
        "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("mkdir -p x")])]),
        "behavior": .string("allow"),
        "destination": .string("localSettings"),
    ])])

    func event(_ name: String = "PermissionRequest", suggestions: JSONValue? = nil) -> HookEvent {
        var extra: [String: JSONValue] = [:]
        if let suggestions { extra["permission_suggestions"] = suggestions }
        return HookEvent(payload: payload(name, extra: extra))
    }

    func parsed(_ d: Data?) -> JSONValue? {
        d.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    func expected(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testAllow() {
        XCTAssertEqual(parsed(HookOutput.render(Reply(.allow), event: event(suggestions: suggestions))),
                       expected(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#))
    }

    func testAlwaysWithSuggestions() {
        XCTAssertEqual(parsed(HookOutput.render(Reply(.always), event: event(suggestions: suggestions))),
                       expected(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"mkdir -p x"}],"behavior":"allow","destination":"localSettings"}]}}}"#))
    }

    func testAlwaysWithoutSuggestionsIsAllow() {
        let allow = HookOutput.render(Reply(.allow), event: event())
        XCTAssertEqual(HookOutput.render(Reply(.always), event: event()), allow)
        XCTAssertEqual(HookOutput.render(Reply(.always), event: event(suggestions: .array([]))), allow)
        XCTAssertEqual(HookOutput.render(Reply(.always), event: event(suggestions: .null)), allow)
    }

    func testDenyDefaultMessage() {
        let want = expected(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Earshot"}}}"#)
        XCTAssertEqual(parsed(HookOutput.render(Reply(.deny), event: event())), want)
        XCTAssertEqual(parsed(HookOutput.render(Reply(.deny, message: ""), event: event())), want)
    }

    func testDenyCustomMessage() {
        XCTAssertEqual(parsed(HookOutput.render(Reply(.deny, message: "not now"), event: event())),
                       expected(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"not now"}}}"#))
    }

    func testPassPrintsNothing() {
        XCTAssertNil(HookOutput.render(.pass, event: event(suggestions: suggestions)))
    }

    func testOtherEventsPrintNothing() {
        for name in ["PreToolUse", "PostToolUse", "Notification", "Stop", ""] {
            for d in [Decision.allow, .always, .deny, .pass] {
                XCTAssertNil(HookOutput.render(Reply(d), event: event(name)), name)
            }
        }
    }

    func testOutputIsSingleLine() {
        let d = HookOutput.render(Reply(.always), event: event(suggestions: suggestions))!
        XCTAssertFalse(d.contains(0x0A))
    }
}

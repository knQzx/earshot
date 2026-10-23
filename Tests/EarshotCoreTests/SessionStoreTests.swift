import XCTest
@testable import EarshotCore

enum Fixture {
    static func payload(_ name: String, _ overrides: [String: JSONValue] = [:]) -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              case .object(var o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            fatalError("missing fixture \(name)")
        }
        for (k, v) in overrides { o[k] = v }
        return .object(o)
    }
}

final class SessionStoreTests: XCTestCase {
    let pid: Int32 = 4242
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var store = SessionStore()

    var key: String { SessionStore.key(pid: pid, sessionID: nil) }
    var session: Session { store.sessions[key]! }

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @discardableResult
    func send(_ fixture: String, at s: TimeInterval = 0, pid: Int32? = nil, request: UUID? = nil, _ overrides: [String: JSONValue] = [:]) -> [StoreEffect] {
        let m = WireMessage(
            kind: request == nil ? .event : .request,
            pid: pid ?? self.pid, tty: "ttys004", term: "Apple_Terminal",
            payload: Fixture.payload(fixture, overrides))
        return store.ingest(m, requestID: request, now: at(s))
    }

    func ask(_ fixture: String = "permission_request_bash", at s: TimeInterval = 0, pid: Int32? = nil, _ overrides: [String: JSONValue] = [:]) -> UUID {
        let id = UUID()
        XCTAssertEqual(send(fixture, at: s, pid: pid, request: id, overrides), [])
        return id
    }

    func testSessionStartCreatesIdleRow() {
        send("session_start")
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.title, "Earshot notch app")
        XCTAssertEqual(session.cwd, "/Users/dev/src/earshot")
        XCTAssertEqual(session.projectName, "earshot")
        XCTAssertEqual(session.tty, "ttys004")
        XCTAssertEqual(session.term, "Apple_Terminal")
        XCTAssertEqual(session.sessionID, "3f2b9c1e-7a44-4d0b-9e2f-5c1a8d6e4b70")
        XCTAssertEqual(session.id, "pid:4242")
    }

    func testSessionStartCompactKeepsWorking() {
        send("user_prompt_submit")
        send("session_start", at: 5, ["source": .string("compact")])
        XCTAssertEqual(session.status, .working)
    }

    func testUserPromptTitleFromPromptFirstLine() {
        send("user_prompt_submit")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.title, "Build the release binary and tell me how big it is")
        send("user_prompt_submit", at: 1, ["prompt": .string("second prompt")])
        XCTAssertEqual(session.title, "Build the release binary and tell me how big it is")
    }

    func testUserPromptPrefersSessionTitle() {
        send("user_prompt_submit", ["session_title": .string("Release build size")])
        XCTAssertEqual(session.title, "Release build size")
    }

    func testPreToolUseWorkingWithActivity() {
        send("user_prompt_submit")
        send("pre_tool_use_bash", at: 1)
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.activity, "Bash mkdir -p build/out && swift build -c release")
        send("pre_tool_use_mcp_notion", at: 2)
        XCTAssertEqual(session.activity, "notion · notion-search")
    }

    func testPreToolUseAskUserQuestionIsQuestion() {
        send("pre_tool_use_ask_user_question")
        XCTAssertEqual(session.status, .question)
        XCTAssertEqual(session.activity, "Question: Which terminal should Earshot support first?")
        send("post_tool_use_bash", at: 3, ["tool_name": .string("AskUserQuestion"), "tool_input": Fixture.payload("pre_tool_use_ask_user_question")["tool_input"]!])
        XCTAssertEqual(session.status, .working)
    }

    func testPermissionRequestCreatesPending() {
        send("pre_tool_use_bash")
        let id = ask(at: 1)
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.pending.map(\.id), [id])
        let r = session.pending[0]
        XCTAssertEqual(r.toolName, "Bash")
        XCTAssertEqual(r.summary.short, "Bash mkdir -p build/out && swift build -c release")
        XCTAssertTrue(r.canAlways)
        XCTAssertEqual(r.suggestions?.array?.first?["destination"]?.string, "localSettings")
        XCTAssertEqual(r.createdAt, at(1))
        XCTAssertEqual(store.pendingQueue.map(\.request.id), [id])
    }

    func testPermissionRequestWithoutSuggestionsCannotAlways() {
        _ = ask("permission_request_bash", ["permission_suggestions": .array([])])
        XCTAssertFalse(session.pending[0].canAlways)
    }

    func testLatePermissionNotificationDoesNotCancel() {
        let id = ask()
        let fx = send("notification_permission_prompt", at: 6)
        XCTAssertEqual(fx, [])
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.pending.map(\.id), [id])
        XCTAssertEqual(session.activity, "Bash mkdir -p build/out && swift build -c release")
    }

    func testMatchingPostToolUseCancelsWithPass() {
        let id = ask()
        let fx = send("post_tool_use_bash", at: 2)
        XCTAssertEqual(fx, [.reply(id, .pass)])
        XCTAssertTrue(session.pending.isEmpty)
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.activity)
    }

    func testParallelPostToolUseDoesNotCancel() {
        let id = ask()
        let fx = send("post_tool_use_edit", at: 2)
        XCTAssertEqual(fx, [])
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.pending.map(\.id), [id])
    }

    func testPostToolUseWithDifferentInputDoesNotCancel() {
        _ = ask()
        let other: JSONValue = .object(["command": .string("ls")])
        XCTAssertEqual(send("post_tool_use_bash", at: 2, ["tool_input": other]), [])
        XCTAssertEqual(session.pending.count, 1)
    }

    func testPreToolUseOfParallelToolKeepsPermission() {
        _ = ask()
        send("pre_tool_use_edit", at: 1)
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.activity, "Bash mkdir -p build/out && swift build -c release")
    }

    func testIdenticalRequestsCancelOneAtATime() {
        let a = ask(at: 0)
        let b = ask(at: 1)
        XCTAssertEqual(send("post_tool_use_bash", at: 2), [.reply(a, .pass)])
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(send("post_tool_use_bash", at: 3), [.reply(b, .pass)])
        XCTAssertEqual(session.status, .working)
    }

    func testFailureAndDeniedEventsCancel() {
        let a = ask()
        XCTAssertEqual(send("post_tool_use_bash", at: 1, ["hook_event_name": .string("PostToolUseFailure"), "error": .string("exit 1")]), [.reply(a, .pass)])
        let b = ask(at: 2)
        XCTAssertEqual(send("post_tool_use_bash", at: 3, ["hook_event_name": .string("PermissionDenied"), "reason": .string("classifier")]), [.reply(b, .pass)])
    }

    func testRequestClosedMeansInterrupted() {
        let id = ask()
        store.requestClosed(id, now: at(3))
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.activity, "interrupted")
        XCTAssertTrue(session.pending.isEmpty)
        XCTAssertEqual(session.statusSince, at(3))
        store.requestClosed(UUID(), now: at(4))
        XCTAssertEqual(session.statusSince, at(3))
    }

    func testRequestClosedWithOtherPendingKeepsPermission() {
        let a = ask()
        _ = ask("permission_request_edit", at: 1)
        store.requestClosed(a, now: at(2))
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.pending.count, 1)
    }

    func testStopCancelsAllPending() {
        let a = ask()
        let b = ask("permission_request_edit", at: 1)
        let fx = send("stop", at: 2)
        XCTAssertEqual(Set(fx.map(\.requestID)), [a, b])
        XCTAssertTrue(fx.allSatisfy { $0.reply == .pass })
        XCTAssertEqual(session.status, .waiting)
        XCTAssertNil(session.activity)
        XCTAssertEqual(session.lastMessage, "The release binary is 1.4 MB.")
    }

    func testUserPromptSubmitCancelsAllPending() {
        let a = ask()
        let b = ask("permission_request_edit", at: 1)
        let fx = send("user_prompt_submit", at: 2)
        XCTAssertEqual(fx, [.reply(a, .pass), .reply(b, .pass)])
        XCTAssertEqual(session.status, .working)
        XCTAssertTrue(store.pendingQueue.isEmpty)
    }

    func testStopFailureSetsErrorAndCancels() {
        let a = ask()
        XCTAssertEqual(send("stop_failure", at: 1), [.reply(a, .pass)])
        XCTAssertEqual(session.status, .error)
        XCTAssertEqual(session.activity, "Rate limit reached")
        send("stop_failure", at: 2, ["error": .string("unknown")])
        XCTAssertEqual(session.activity, "429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Number of request tokens has exceeded your per-minute rate limit\"}}")
        send("stop_failure", at: 3, ["error": .null, "error_details": .null])
        XCTAssertEqual(session.activity, "API error")
        send("notification_idle_prompt", at: 60)
        XCTAssertEqual(session.status, .error)
        send("user_prompt_submit", at: 61)
        XCTAssertEqual(session.status, .working)
    }

    func testSessionEndRemovesAndPasses() {
        let a = ask()
        let b = ask("permission_request_edit", at: 1)
        let fx = send("session_end", at: 2)
        XCTAssertEqual(fx, [.reply(a, .pass), .reply(b, .pass)])
        XCTAssertNil(store.sessions[key])
        XCTAssertTrue(store.pendingQueue.isEmpty)
    }

    func testSessionEndDoesNotComeBackFromScanner() {
        send("session_start")
        send("session_end", at: 1)
        let proc = ClaudeProcess(pid: pid, tty: "ttys004", cwd: "/x", startedAt: at(-100))
        store.sync(processes: [proc], isAlive: { _ in true }, now: at(2))
        XCTAssertNil(store.sessions[key])
        send("session_start", at: 3, ["source": .string("resume")])
        XCTAssertNotNil(store.sessions[key])
    }

    func testEndedPidForgottenOnceDead() {
        send("session_end")
        store.sync(processes: [], isAlive: { _ in false }, now: at(1))
        let proc = ClaudeProcess(pid: pid, tty: "ttys004", cwd: "/x", startedAt: at(0))
        store.sync(processes: [proc], isAlive: { _ in true }, now: at(2))
        XCTAssertEqual(session.status, .unknown)
    }

    func testClearKeepsRowResetsTitleAndPassesPending() {
        let proc = ClaudeProcess(pid: pid, tty: "ttys004", cwd: "/Users/dev/src/earshot", startedAt: at(-500))
        store.sync(processes: [proc], isAlive: { _ in true }, now: at(0))
        send("session_start", at: 1)
        send("stop", at: 2)
        let a = ask(at: 3)
        let fx = send("session_end_clear", at: 4)
        XCTAssertEqual(fx, [.reply(a, .pass)])
        send("session_start_clear", at: 4)
        XCTAssertEqual(session.sessionID, "9d0e6a5b-1c2f-4e8a-b3d7-6f4c2a1e8b93")
        XCTAssertNil(session.title)
        XCTAssertNil(session.lastMessage)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.startedAt, at(-500))
        send("user_prompt_submit", at: 5, ["session_id": .string("9d0e6a5b-1c2f-4e8a-b3d7-6f4c2a1e8b93"), "prompt": .string("fresh start")])
        XCTAssertEqual(session.title, "fresh start")
    }

    func testNewSessionIDSamePidPassesPendingWithoutSessionEnd() {
        send("user_prompt_submit")
        let a = ask(at: 1)
        let fx = send("session_start_clear", at: 2)
        XCTAssertEqual(fx, [.reply(a, .pass)])
        XCTAssertNil(session.title)
        XCTAssertTrue(session.pending.isEmpty)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testStalledAfterStallAfter() {
        send("pre_tool_use_bash")
        XCTAssertEqual(session.display(now: at(SessionStore.stallAfter - 1)), .working)
        XCTAssertEqual(session.display(now: at(SessionStore.stallAfter + 1)), .stalled)
        XCTAssertEqual(session.display(now: at(60), stallAfter: 30), .stalled)
        send("post_tool_use_bash", at: SessionStore.stallAfter + 2)
        XCTAssertEqual(session.display(now: at(SessionStore.stallAfter + 3)), .working)
        send("stop", at: 400)
        XCTAssertEqual(session.display(now: at(4000)), .waiting)
    }

    func testSyncAddsUnknownAndRemovesDead() {
        let procs = [
            ClaudeProcess(pid: 10, tty: "ttys001", cwd: "/a", startedAt: at(-50)),
            ClaudeProcess(pid: 11, tty: "ttys002", cwd: "/b", startedAt: at(-40)),
        ]
        XCTAssertEqual(store.sync(processes: procs, isAlive: { _ in true }, now: at(0)), [])
        XCTAssertEqual(store.sessions["pid:10"]?.status, .unknown)
        XCTAssertEqual(store.sessions["pid:10"]?.tty, "ttys001")
        XCTAssertEqual(store.sessions["pid:10"]?.startedAt, at(-50))
        XCTAssertEqual(store.sessions["pid:11"]?.cwd, "/b")

        let id = ask(at: 1, pid: 11)
        let fx = store.sync(processes: [procs[0]], isAlive: { $0 == 10 }, now: at(3))
        XCTAssertEqual(fx, [.reply(id, .pass)])
        XCTAssertNil(store.sessions["pid:11"])
        XCTAssertNotNil(store.sessions["pid:10"])
    }

    func testSyncKeepsAliveSessionMissingFromScan() {
        send("session_start")
        store.sync(processes: [], isAlive: { _ in true }, now: at(1))
        XCTAssertNotNil(store.sessions[key])
    }

    func testSyncDoesNotOverwriteHookData() {
        send("session_start")
        let proc = ClaudeProcess(pid: pid, tty: "ttys009", cwd: "/elsewhere", startedAt: at(-10))
        store.sync(processes: [proc], isAlive: { _ in true }, now: at(1))
        XCTAssertEqual(session.tty, "ttys004")
        XCTAssertEqual(session.cwd, "/Users/dev/src/earshot")
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.startedAt, at(-10))
    }

    func testPidlessSessionKeyedBySessionIDAndExpires() {
        send("session_start", pid: 0)
        let k = SessionStore.key(pid: 0, sessionID: "3f2b9c1e-7a44-4d0b-9e2f-5c1a8d6e4b70")
        XCTAssertEqual(k, "sid:3f2b9c1e-7a44-4d0b-9e2f-5c1a8d6e4b70")
        XCTAssertNotNil(store.sessions[k])
        store.sync(processes: [], isAlive: { _ in false }, now: at(60))
        XCTAssertNotNil(store.sessions[k])
        store.sync(processes: [], isAlive: { _ in false }, now: at(SessionStore.orphanTTL + 1))
        XCTAssertNil(store.sessions[k])
    }

    func testOrderingByUrgency() {
        let order: [(Int32, String, [String: JSONValue])] = [
            (1, "user_prompt_submit", [:]),
            (2, "stop", [:]),
            (3, "notification_elicitation_dialog", [:]),
            (4, "stop_failure", [:]),
            (5, "session_start", [:]),
            (6, "permission_request_bash", [:]),
            (7, "pre_tool_use_bash", [:]),
        ]
        for (p, f, o) in order {
            if f.hasPrefix("permission_request") { _ = ask(f, at: Double(p), pid: p, o) } else { send(f, at: Double(p), pid: p, o) }
        }
        store.sync(processes: [ClaudeProcess(pid: 8, tty: nil, cwd: "/z", startedAt: at(8))], isAlive: { _ in true }, now: at(8))
        let now = at(7 + SessionStore.stallAfter - 1)
        XCTAssertEqual(store.ordered(now: now).map(\.pid), [6, 3, 4, 2, 1, 7, 5, 8])
        XCTAssertEqual(store.ordered(now: now).map { $0.display(now: now) }, [.permission, .question, .error, .waiting, .stalled, .working, .idle, .unknown])
    }

    func testOrderingTiesByStartTime() {
        send("stop", at: 5, pid: 21)
        send("stop", at: 1, pid: 22)
        XCTAssertEqual(store.ordered(now: at(10)).map(\.pid), [22, 21])
    }

    func testPendingQueueAcrossSessionsInArrivalOrder() {
        let a = ask(at: 2, pid: 31)
        let b = ask(at: 1, pid: 32)
        let c = ask("permission_request_edit", at: 3, pid: 31)
        XCTAssertEqual(store.pendingQueue.map(\.request.id), [b, a, c])
        XCTAssertEqual(store.pendingQueue.map(\.session.pid), [32, 31, 31])
    }

    func testResolveRepliesAndMovesToWorking() {
        let a = ask()
        let b = ask("permission_request_edit", at: 1)
        let allow = Reply(.allow)
        XCTAssertEqual(store.resolve(requestID: a, reply: allow, now: at(2)), [.reply(a, allow)])
        XCTAssertEqual(session.status, .permission)
        let deny = Reply(.deny, message: "Denied from Earshot")
        XCTAssertEqual(store.resolve(requestID: b, reply: deny, now: at(3)), [.reply(b, deny)])
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.activity)
        XCTAssertEqual(store.resolve(requestID: b, reply: deny, now: at(4)), [])
    }

    func testResolveWithPassLeavesTerminalInCharge() {
        let a = ask()
        XCTAssertEqual(store.resolve(requestID: a, reply: .pass, now: at(1)), [.reply(a, .pass)])
        XCTAssertEqual(session.status, .permission)
        XCTAssertTrue(session.pending.isEmpty)
    }

    func testLatePermissionNoticeAfterResolveIgnored() {
        let a = ask()
        store.resolve(requestID: a, reply: Reply(.allow), now: at(2))
        send("notification_permission_prompt", at: 6)
        XCTAssertEqual(session.status, .working)
        send("notification_permission_prompt", at: 30)
        XCTAssertEqual(session.status, .permission)
    }

    func testLatePermissionNoticeAfterTerminalAnswerIgnored() {
        _ = ask()
        send("post_tool_use_bash", at: 3)
        send("notification_permission_prompt", at: 6)
        XCTAssertEqual(session.status, .working)
    }

    func testPermissionNoticeWithoutHookRequestShowsPermission() {
        send("pre_tool_use_bash")
        send("notification_permission_prompt", at: 6)
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.activity, "Claude needs your permission to use Bash")
        XCTAssertTrue(session.pending.isEmpty)
    }

    func testAskUserQuestionPermissionRequestIsPassedAsQuestion() {
        send("pre_tool_use_ask_user_question")
        let id = UUID()
        XCTAssertEqual(send("permission_request_ask_user_question", at: 1, request: id), [.reply(id, .pass)])
        XCTAssertEqual(session.status, .question)
        XCTAssertTrue(session.pending.isEmpty)
        send("notification_permission_prompt", at: 7)
        XCTAssertEqual(session.status, .question)
    }

    func testRequestForNonPermissionEventIsPassed() {
        let id = UUID()
        XCTAssertEqual(send("pre_tool_use_bash", request: id), [.reply(id, .pass)])
        XCTAssertTrue(store.pendingQueue.isEmpty)
        let end = UUID()
        XCTAssertEqual(send("session_end", at: 1, request: end), [.reply(end, .pass)])
    }

    func testPermissionRequestEventWithoutIDOnlySetsStatus() {
        send("permission_request_bash")
        XCTAssertEqual(session.status, .permission)
        XCTAssertTrue(session.pending.isEmpty)
    }

    func testIdlePromptWaitsUnlessUserIsNeeded() {
        send("user_prompt_submit")
        send("notification_idle_prompt", at: 1)
        XCTAssertEqual(session.status, .waiting)
        _ = ask(at: 2)
        send("notification_idle_prompt", at: 3)
        XCTAssertEqual(session.status, .permission)
    }

    func testElicitationIsQuestionUntilComplete() {
        send("pre_tool_use_mcp_notion")
        send("notification_elicitation_dialog", at: 1)
        XCTAssertEqual(session.status, .question)
        XCTAssertEqual(session.activity, "notion needs more information: pick a workspace")
        send("notification_idle_prompt", at: 2)
        XCTAssertEqual(session.status, .question)
        send("notification_elicitation_dialog", at: 3, ["notification_type": .string("elicitation_complete")])
        XCTAssertEqual(session.status, .working)
    }

    func testStatusSinceOnlyChangesOnTransition() {
        send("user_prompt_submit", at: 0)
        send("pre_tool_use_bash", at: 5)
        XCTAssertEqual(session.statusSince, at(0))
        XCTAssertEqual(session.lastEventAt, at(5))
        send("stop", at: 9)
        XCTAssertEqual(session.statusSince, at(9))
    }

    func testRemoveByIDPassesPending() {
        let a = ask()
        XCTAssertEqual(store.remove(id: key), [.reply(a, .pass)])
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.remove(id: key), [])
    }
}

private extension StoreEffect {
    var requestID: UUID { if case .reply(let id, _) = self { return id }; fatalError() }
    var reply: Reply { if case .reply(_, let r) = self { return r }; fatalError() }
}

final class SessionMetaTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var store = SessionStore()
    let sid = "3f2b9c1e-7a44-4d0b-9e2f-5c1a8d6e4b70"

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func sync(_ meta: ClaudeMeta?, at s: TimeInterval = 0, pid: Int32 = 50) {
        let p = ClaudeProcess(pid: pid, tty: "ttys001", cwd: "/Users/dev/src/earshot", startedAt: at(-100), meta: meta)
        store.sync(processes: [p], isAlive: { _ in true }, now: at(s))
    }

    var session: Session { store.sessions["pid:50"]! }

    func event(_ fixture: String, at s: TimeInterval, _ overrides: [String: JSONValue] = [:]) {
        let m = WireMessage(kind: .event, pid: 50, tty: "ttys001", term: nil, payload: Fixture.payload(fixture, overrides))
        store.ingest(m, now: at(s))
    }

    func testTitlePriority() {
        var s = Session(id: "x", pid: 1, cwd: "/a", now: t0)
        XCTAssertNil(s.title)
        s.title = "from hook"
        XCTAssertEqual(s.hookTitle, "from hook")
        XCTAssertEqual(s.title, "from hook")
        s.metaName = "earshot-14"
        s.metaNameSource = "derived"
        XCTAssertEqual(s.title, "from hook")
        s.metaNameSource = "auto"
        XCTAssertEqual(s.title, "earshot-14")
        s.aiTitle = "AI title"
        XCTAssertEqual(s.title, "AI title")
        s.metaName = "My rename"
        s.metaNameSource = "user"
        XCTAssertEqual(s.title, "My rename")
        s.metaName = ""
        XCTAssertEqual(s.title, "AI title")
    }

    func testSyncAppliesMetaToUnknownSession() {
        sync(ClaudeMeta(sessionID: sid, name: "ресурсный-тезис", nameSource: "auto", status: "busy",
                        statusUpdatedAt: at(-40), aiTitle: "Resource thesis"), at: 0)
        XCTAssertEqual(session.sessionID, sid)
        XCTAssertEqual(session.title, "Resource thesis")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.statusSince, at(-40))
        XCTAssertEqual(session.display(now: at(SessionStore.stallAfter + 10)), .stalled)
        sync(ClaudeMeta(sessionID: sid, status: "busy", statusUpdatedAt: at(-40)), at: SessionStore.stallAfter + 5)
        XCTAssertEqual(session.display(now: at(SessionStore.stallAfter + 10)), .working)
        XCTAssertEqual(session.title, "Resource thesis")

        sync(ClaudeMeta(sessionID: sid, status: "idle", statusUpdatedAt: at(400)), at: 410)
        XCTAssertEqual(session.status, .waiting)
        XCTAssertEqual(session.statusSince, at(400))
        XCTAssertFalse(session.unseen)
    }

    func testUnknownStatusHintLeavesUnknown() {
        sync(ClaudeMeta(sessionID: sid, status: "starting"))
        XCTAssertEqual(session.status, .unknown)
        sync(nil)
        XCTAssertEqual(session.status, .unknown)
    }

    func testHookStatusNeverOverridden() {
        event("user_prompt_submit", at: 0)
        sync(ClaudeMeta(sessionID: sid, status: "idle", statusUpdatedAt: at(1), aiTitle: "AI"), at: 2)
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.title, "AI")
        event("stop", at: 3)
        sync(ClaudeMeta(sessionID: sid, status: "busy", statusUpdatedAt: at(4)), at: 5)
        XCTAssertEqual(session.status, .waiting)
        XCTAssertTrue(session.unseen)
    }

    func testHookedSessionIgnoresMetaForOtherSessionID() {
        event("user_prompt_submit", at: 0)
        sync(ClaudeMeta(sessionID: "old-session", name: "Stale", nameSource: "user", aiTitle: "Stale AI"), at: 1)
        XCTAssertEqual(session.sessionID, sid)
        XCTAssertEqual(session.title, "Build the release binary and tell me how big it is")
    }

    func testMetaOnlySessionFollowsClear() {
        sync(ClaudeMeta(sessionID: sid, status: "idle", aiTitle: "Before clear"))
        XCTAssertEqual(session.title, "Before clear")
        sync(ClaudeMeta(sessionID: "new-session", name: "x-1", nameSource: "derived", status: "idle"), at: 5)
        XCTAssertEqual(session.sessionID, "new-session")
        XCTAssertNil(session.title)
    }

    func testHookClearForgetsMetaTitles() {
        sync(ClaudeMeta(sessionID: sid, name: "Renamed", nameSource: "user", aiTitle: "AI"))
        event("session_start", at: 1)
        XCTAssertEqual(session.title, "Renamed")
        event("session_start_clear", at: 2)
        XCTAssertNil(session.title)
    }

    func testPromptTitleStillSetWhenAITitleExists() {
        sync(ClaudeMeta(sessionID: sid, aiTitle: "AI"))
        event("user_prompt_submit", at: 1)
        XCTAssertEqual(session.hookTitle, "Build the release binary and tell me how big it is")
        XCTAssertEqual(session.title, "AI")
    }

    func testHomeDirectoryProjectName() {
        XCTAssertEqual(Session(id: "a", pid: 1, cwd: NSHomeDirectory(), now: t0).projectName, "~")
        XCTAssertEqual(Session(id: "a", pid: 1, cwd: NSHomeDirectory() + "/", now: t0).projectName, "~")
        XCTAssertEqual(Session(id: "a", pid: 1, cwd: NSHomeDirectory() + "/src/earshot", now: t0).projectName, "earshot")
        XCTAssertEqual(Session(id: "a", pid: 1, cwd: "", now: t0).projectName, "")
    }
}

final class SessionNameTests: XCTestCase {
    func testTitleIsTheNameAndPathIsTheDetail() {
        let now = Date()
        let home = NSHomeDirectory()
        var s = Session(id: "pid:1", pid: 1, cwd: home, now: now)
        XCTAssertEqual(s.name, "~")
        XCTAssertNil(s.detail)
        s.title = "Control Tower and Sentinel meeting"
        XCTAssertEqual(s.name, "Control Tower and Sentinel meeting")
        XCTAssertEqual(s.detail, "~")
        XCTAssertEqual(s.chipName, "Control Tower and Senti…")
        var p = Session(id: "pid:2", pid: 2, cwd: home + "/code/web-app", now: now)
        XCTAssertEqual(p.name, "web-app")
        XCTAssertNil(p.detail)
        p.title = "Fix checkout race"
        XCTAssertEqual(p.name, "Fix checkout race")
        XCTAssertEqual(p.detail, "~/code/web-app")
        p.title = "   "
        XCTAssertEqual(p.name, "web-app")
        XCTAssertNil(p.detail)
    }

    func testLongPathsAreShortened() {
        var s = Session(id: "pid:3", pid: 3, cwd: "/Volumes/External/projects/clients/acme/very-long-repository-name", now: Date())
        s.title = "Deploy"
        XCTAssertEqual(s.detail, "…/acme/very-long-repository-name")
    }
}

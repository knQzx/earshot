import XCTest
@testable import EarshotCore

final class ToolSummaryTests: XCTestCase {
    func summary(_ fixture: String) -> ToolSummary {
        let e = HookEvent(payload: Fixture.payload(fixture))
        return ToolSummary(tool: e.toolName ?? "?", input: e.toolInput, mcpServer: e.mcpServer)
    }

    func testBash() {
        let s = summary("pre_tool_use_bash")
        XCTAssertEqual(s.short, "Bash mkdir -p build/out && swift build -c release")
        XCTAssertEqual(s.detail, "Create the output folder and build release\nmkdir -p build/out && swift build -c release")
        XCTAssertNil(s.server)
    }

    func testBashMultilineAndEmpty() {
        let s = ToolSummary(tool: "Bash", input: .object(["command": .string("\n  cd /tmp\r\nls -la")]))
        XCTAssertEqual(s.short, "Bash cd /tmp")
        XCTAssertEqual(s.detail, "\n  cd /tmp\r\nls -la")
        XCTAssertEqual(ToolSummary(tool: "Bash", input: nil).short, "Bash")
    }

    func testEdit() {
        let s = summary("pre_tool_use_edit")
        XCTAssertEqual(s.short, "Edit SessionStore.swift")
        XCTAssertEqual(s.detail, "/Users/dev/src/earshot/Sources/EarshotCore/SessionStore.swift")
        let nb = ToolSummary(tool: "NotebookEdit", input: .object(["notebook_path": .string("/x/analysis.ipynb")]))
        XCTAssertEqual(nb.short, "NotebookEdit analysis.ipynb")
    }

    func testMCPNaming() {
        let s = summary("pre_tool_use_mcp_notion")
        XCTAssertEqual(s.server, "notion")
        XCTAssertEqual(s.short, "notion · notion-search")
        XCTAssertEqual(s.detail, #"{"query":"Earshot launch checklist","query_type":"internal"}"#)

        let derived = ToolSummary(tool: "mcp__github__create_pull_request", input: nil)
        XCTAssertEqual(derived.server, "github")
        XCTAssertEqual(derived.short, "github · create_pull_request")
        XCTAssertEqual(derived.detail, "")

        let underscored = ToolSummary(tool: "mcp__claude_ai__Gmail__search_threads", input: nil, mcpServer: "claude_ai__Gmail")
        XCTAssertEqual(underscored.server, "claude_ai__Gmail")
        XCTAssertEqual(underscored.short, "claude_ai__Gmail · search_threads")

        XCTAssertEqual(ToolSummary(tool: "mcp__solo", input: nil).short, "solo")
    }

    func testWebFetchHost() {
        let s = ToolSummary(tool: "WebFetch", input: .object(["url": .string("https://docs.claude.com/en/docs/claude-code/hooks"), "prompt": .string("x")]))
        XCTAssertEqual(s.short, "WebFetch docs.claude.com")
        XCTAssertEqual(s.detail, "https://docs.claude.com/en/docs/claude-code/hooks")
        XCTAssertEqual(ToolSummary(tool: "WebFetch", input: .object(["url": .string("not a url")])).short, "WebFetch not a url")
    }

    func testLongInputClipping() {
        let long = String(repeating: "a", count: 5000)
        let bash = ToolSummary(tool: "Bash", input: .object(["command": .string(long)]))
        XCTAssertEqual(bash.short.count, 80)
        XCTAssertTrue(bash.short.hasSuffix("…"))
        XCTAssertEqual(bash.detail.count, 2000)
        XCTAssertTrue(bash.detail.hasSuffix("…"))

        let mcp = ToolSummary(tool: "mcp__notion__" + String(repeating: "x", count: 200), input: .object(["q": .string(long)]))
        XCTAssertEqual(mcp.short.count, 80)
        XCTAssertEqual(mcp.detail.count, 400)

        let other = ToolSummary(tool: "Mystery", input: .object(["blob": .string(long)]))
        XCTAssertEqual(other.short, "Mystery")
        XCTAssertEqual(other.detail.count, 400)
    }

    func testAskUserQuestion() {
        let s = summary("pre_tool_use_ask_user_question")
        XCTAssertEqual(s.short, "Question: Which terminal should Earshot support first?")
        XCTAssertEqual(s.detail, "Which terminal should Earshot support first?")
        let two = ToolSummary(tool: "AskUserQuestion", input: .object(["questions": .array([
            .object(["question": .string("First?")]), .object(["question": .string("Second?")]),
        ])]))
        XCTAssertEqual(two.detail, "First?\nSecond?")
        XCTAssertEqual(ToolSummary(tool: "AskUserQuestion", input: nil).short, "Question")
    }

    func testSearchAndAgentTools() {
        XCTAssertEqual(ToolSummary(tool: "Grep", input: .object(["pattern": .string("TODO"), "path": .string("Sources")])).detail, "TODO  in  Sources")
        XCTAssertEqual(ToolSummary(tool: "WebSearch", input: .object(["query": .string("swift 6")])).short, "WebSearch swift 6")
        XCTAssertEqual(ToolSummary(tool: "Task", input: .object(["description": .string("Scan repo")])).short, "Agent Scan repo")
    }

    func testFirstLineAndClip() {
        XCTAssertEqual(ToolSummary.firstLine("\n\n   \n  hello  \nworld"), "hello")
        XCTAssertEqual(ToolSummary.firstLine("one\r\ntwo"), "one")
        XCTAssertEqual(ToolSummary.firstLine(""), "")
        XCTAssertEqual(ToolSummary.clip("abcdef", 4), "abc…")
        XCTAssertEqual(ToolSummary.clip("abcd", 4), "abcd")
        XCTAssertEqual(ToolSummary.clip("abc", 0), "")
    }
}

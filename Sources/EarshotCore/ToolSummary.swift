import Foundation

public struct ToolSummary: Equatable, Sendable {
    public var tool: String
    public var short: String
    public var detail: String
    public var server: String?

    public init(tool: String, input: JSONValue?, mcpServer: String? = nil) {
        self.tool = tool
        let i = input ?? .null
        func s(_ k: String) -> String? { i[k]?.string }
        func base(_ p: String?) -> String { p.map { ($0 as NSString).lastPathComponent } ?? "" }
        func titled(_ head: String, _ rest: String) -> String { rest.isEmpty ? head : "\(head) \(rest)" }

        server = nil
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let srv: String, name: String
            if let m = mcpServer, !m.isEmpty, rest.hasPrefix(m + "__") {
                srv = m
                name = String(rest.dropFirst(m.count + 2))
            } else {
                let parts = rest.components(separatedBy: "__")
                srv = mcpServer.flatMap { $0.isEmpty ? nil : $0 } ?? parts.first ?? ""
                name = parts.dropFirst().joined(separator: "__")
            }
            server = srv
            short = name.isEmpty ? srv : "\(srv) · \(name)"
            detail = i.isEmptyOrNull ? "" : ToolSummary.clip(i.canonical, 400)
        } else {
            switch tool {
            case "Bash":
                let cmd = s("command") ?? ""
                short = titled("Bash", ToolSummary.firstLine(cmd))
                detail = s("description").map { "\($0)\n\(cmd)" } ?? cmd
            case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
                let p = s("file_path") ?? s("notebook_path")
                short = titled(tool, base(p))
                detail = p ?? ""
            case "Grep", "Glob":
                short = titled(tool, s("pattern") ?? "")
                detail = [s("pattern"), s("path")].compactMap { $0 }.joined(separator: "  in  ")
            case "WebFetch":
                let url = s("url") ?? ""
                short = titled("WebFetch", URL(string: url)?.host ?? url)
                detail = url
            case "WebSearch":
                short = titled("WebSearch", s("query") ?? "")
                detail = s("query") ?? ""
            case "Task", "Agent":
                short = titled("Agent", s("description") ?? "")
                detail = s("prompt").map { ToolSummary.clip($0, 400) } ?? ""
            case "AskUserQuestion":
                let qs = i["questions"]?.array ?? []
                let q = ToolSummary.firstLine(qs.first?["question"]?.string ?? "")
                short = q.isEmpty ? "Question" : "Question: " + q
                detail = qs.compactMap { $0["question"]?.string }.joined(separator: "\n")
            default:
                short = tool
                detail = i.isEmptyOrNull ? "" : ToolSummary.clip(i.canonical, 400)
            }
        }
        short = ToolSummary.clip(short, 80)
        detail = ToolSummary.clip(detail, 2000)
    }

    public static func firstLine(_ s: String) -> String {
        for line in s.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    public static func clip(_ s: String, _ n: Int) -> String {
        guard n > 0 else { return "" }
        return s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

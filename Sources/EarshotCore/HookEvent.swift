import Foundation

public struct HookEvent: Equatable, Sendable {
    public var name: String
    public var sessionID: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var prompt: String?
    public var message: String?
    public var notificationType: String?
    public var lastAssistantMessage: String?
    public var error: String?
    public var errorDetails: String?
    public var reason: String?
    public var source: String?
    public var sessionTitle: String?
    public var permissionSuggestions: JSONValue?
    public var mcpServer: String?
    public var scratchpadDir: String?

    public init(payload p: JSONValue) {
        name = p["hook_event_name"]?.string ?? ""
        sessionID = p["session_id"]?.string
        cwd = p["cwd"]?.string
        transcriptPath = p["transcript_path"]?.string
        toolName = p["tool_name"]?.string
        toolInput = p["tool_input"]
        prompt = p["prompt"]?.string
        message = p["message"]?.string
        notificationType = p["notification_type"]?.string
        lastAssistantMessage = p["last_assistant_message"]?.string
        error = HookEvent.text(p["error"]) ?? HookEvent.text(p["error_message"])
        errorDetails = HookEvent.text(p["error_details"])
        reason = p["reason"]?.string
        source = p["source"]?.string
        sessionTitle = p["session_title"]?.string
        permissionSuggestions = p["permission_suggestions"]
        mcpServer = p["mcp_server"]?.string
        scratchpadDir = p["scratchpad_dir"]?.string
    }

    private static func text(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        if let s = v.string { return s }
        if let m = v["message"]?.string { return m }
        if v.isEmptyOrNull { return nil }
        return v.canonical
    }
}

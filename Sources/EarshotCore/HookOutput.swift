import Foundation

public enum HookOutput {
    public static let defaultDenyMessage = "Denied from Earshot"

    public static func render(_ reply: Reply, event: HookEvent, policy: PolicyMatch? = nil) -> Data? {
        if event.name == "PreToolUse", let policy { return render(reply, policy: policy) }
        guard event.name == "PermissionRequest" else { return nil }
        var decision: [String: JSONValue]
        switch reply.decision {
        case .pass:
            return nil
        case .allow:
            decision = ["behavior": .string("allow")]
        case .always:
            decision = ["behavior": .string("allow")]
            if let s = event.permissionSuggestions, case .array(let a) = s, !a.isEmpty {
                decision["updatedPermissions"] = s
            }
        case .deny:
            let msg = reply.message.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDenyMessage
            decision = ["behavior": .string("deny"), "message": .string(msg)]
        }
        let out: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? enc.encode(out)
    }

    public static func render(policy m: PolicyMatch) -> Data? {
        preToolUse(m.action.hookDecision, m.action == .deny ? "Blocked by Earshot policy: \(m.label)" : "Earshot policy: \(m.label)")
    }

    static func render(_ reply: Reply, policy m: PolicyMatch) -> Data? {
        switch reply.decision {
        case .allow, .always: return preToolUse("allow", "Approved in Earshot")
        case .deny: return preToolUse("deny", "Denied in Earshot (\(m.label))")
        case .pass: return preToolUse("ask", "Earshot policy: \(m.label)")
        }
    }

    static func preToolUse(_ decision: String, _ reason: String) -> Data? {
        let out: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string(decision),
                "permissionDecisionReason": .string(reason),
            ]),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? enc.encode(out)
    }
}

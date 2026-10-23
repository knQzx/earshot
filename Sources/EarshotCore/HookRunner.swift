import Darwin
import Foundation

public enum HookRunner {
    public typealias Transport = (_ line: Data, _ socket: URL, _ awaitReply: Bool) throws -> Data?

    public static func run(
        stdin: Data,
        env: [String: String],
        ancestor: @autoclosure () -> Proc.Info?,
        socket: URL,
        policyURL: URL? = nil,
        transport: Transport = SocketClient.send
    ) -> Data? {
        let disabled = env["EARSHOT_DISABLE"] == "1"
        if !disabled, let rec = env["EARSHOT_RECORD"], !rec.isEmpty { record(stdin, to: rec) }
        let live = !disabled && access(socket.path, F_OK) == 0
        guard live || policyURL != nil else { return nil }
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: stdin), case .object = payload else { return nil }

        let event = HookEvent(payload: payload)
        let input = event.name == "PreToolUse" ? PolicyInput(event: event) : nil
        let policy = input == nil ? nil : policyURL.map { PolicyStore.effective(at: $0).policy }
        let match = input.flatMap { x in policy?.evaluate(x) }
        let policyOut = match.flatMap(HookOutput.render(policy:))
        guard live else { return policyOut }

        let proc = ancestor()
        let term = env["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 }
        let gate = match?.action == .ask
        let isRequest = (event.name == "PermissionRequest" || gate) && proc?.tty != nil
        let msg = WireMessage(kind: isRequest ? .request : .event, pid: proc?.pid ?? 0, tty: proc?.tty, term: term, payload: payload, policy: match)

        guard let line = try? Wire.line(msg),
              let answer = (try? transport(line, socket, isRequest)) ?? nil,
              isRequest,
              let reply = try? Wire.decode(Reply.self, line: answer)
        else { return policyOut }
        if let match, gate, reply.decision == .allow || reply.decision == .always,
           let input, let policy, !policy.covers(match, input) {
            return nil
        }
        return HookOutput.render(reply, event: event, policy: match) ?? policyOut
    }

    static func record(_ stdin: Data, to path: String) {
        var data = stdin
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { return }
        data.append(0x0A)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = UnixSocket.writeAll(fd, data, waitMs: 0)
        close(fd)
    }
}

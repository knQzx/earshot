import Darwin
import Foundation

public enum PeerTrust {
    public static func earshotApp(hookPath: String, env: [String: String]) -> (pid_t) -> Bool {
        let expected = real((hookPath as NSString).deletingLastPathComponent + "/Earshot")
        let explicit = isDebug && !(env["EARSHOT_SOCKET"] ?? "").isEmpty
        return { pid in
            if explicit { return true }
            guard let path = Proc.path(pid) else { return false }
            return real(path) == expected
        }
    }

    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func real(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }
}

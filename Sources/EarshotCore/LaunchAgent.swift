import Foundation

public struct LaunchAgent: Sendable {
    public static let label = "io.github.knqzx.earshot"

    public var directory: URL
    public var executable: String

    public init(directory: URL, executable: String) {
        self.directory = directory
        self.executable = executable
    }

    public static var userAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public var plistURL: URL {
        directory.appendingPathComponent(Self.label + ".plist")
    }

    public var plist: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
    }

    public var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = obj["ProgramArguments"] as? [String] else { return false }
        return args.first == executable
    }

    public func setEnabled(_ on: Bool) throws {
        let fm = FileManager.default
        guard on else {
            if fm.fileExists(atPath: plistURL.path) { try fm.removeItem(at: plistURL) }
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }
}

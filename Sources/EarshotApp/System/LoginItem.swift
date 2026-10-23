import EarshotCore
import Foundation

enum LoginItem {
    static var agent: LaunchAgent {
        LaunchAgent(
            directory: LaunchAgent.userAgentsDirectory,
            executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0])
    }

    static var isEnabled: Bool { agent.isEnabled }

    static func setEnabled(_ on: Bool) throws {
        try agent.setEnabled(on)
    }
}

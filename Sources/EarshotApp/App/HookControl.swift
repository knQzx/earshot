import EarshotCore
import Foundation

struct HookControl {
    var status: () -> HookInstallState
    var install: () throws -> Void
    var uninstall: () throws -> Void

    static var hookCommand: String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle.appendingPathComponent("Contents/MacOS/earshot-hook").path
        }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("earshot-hook").path
    }

    static func live() -> HookControl {
        let cmd = hookCommand
        return HookControl(
            status: { HooksInstaller.status(hookCommand: cmd) },
            install: { try HooksInstaller.install(hookCommand: cmd) },
            uninstall: { try HooksInstaller.uninstall() })
    }

    static func simulated(_ initial: HookInstallState) -> HookControl {
        final class Box { var state: HookInstallState; init(_ s: HookInstallState) { state = s } }
        let box = Box(initial)
        return HookControl(
            status: { box.state },
            install: { box.state = .installed },
            uninstall: { box.state = .notInstalled })
    }
}

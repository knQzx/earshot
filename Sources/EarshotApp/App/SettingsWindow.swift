import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var policy: PolicySettings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            PolicyView(policy: policy)
                .frame(width: 560, height: 640)
                .tabItem { Label("Policy", systemImage: "hand.raised") }
        }
    }

    private var general: some View {
        Form {
            Section {
                Picker("Show on", selection: $prefs.screen) {
                    Text("Built-in display with notch").tag(ScreenChoice.automatic)
                    Text("Main display").tag(ScreenChoice.main)
                }
                Picker("Island style", selection: $prefs.islandStyle) {
                    Text("Glass").tag(IslandStyle.glass)
                    Text("Black").tag(IslandStyle.black)
                }
                .disabled(!IslandGlass<Rectangle>.supported)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            try LoginItem.setEnabled(on)
                        } catch {
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
            }
            Section {
                Toggle("Open on hover", isOn: $prefs.openOnHover)
                Toggle("Notify when a session finishes", isOn: $prefs.notifyFinished)
                Toggle("Open the panel on new requests", isOn: $prefs.autoOpen)
                Toggle("Play sounds", isOn: $prefs.sounds)
                Stepper("No activity after \(prefs.stallMinutes) min", value: $prefs.stallMinutes, in: 1...60)
            } footer: {
                Text("Toggle the panel with ⌃⌥C")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}

@MainActor
final class SettingsWindow {
    private let prefs: Preferences
    private let policy: PolicySettings
    private var window: NSWindow?

    init(prefs: Preferences, policy: PolicySettings) {
        self.prefs = prefs
        self.policy = policy
    }

    func show() {
        policy.reload()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(prefs: prefs, policy: policy))
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Earshot Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

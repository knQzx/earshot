import AppKit

@MainActor
final class Sounds {
    private let prefs: Preferences
    private var lastPlayed = Date.distantPast

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    func sessionWaiting() { play("Tink", volume: 0.25) }

    func permissionRequested() { play("Purr", volume: 0.35) }

    private func play(_ name: String, volume: Float) {
        guard prefs.sounds, Date().timeIntervalSince(lastPlayed) > 0.8, let sound = NSSound(named: name) else { return }
        lastPlayed = Date()
        sound.volume = volume
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

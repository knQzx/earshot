import Combine
import Foundation

enum IslandStyle: String, CaseIterable {
    case glass
    case black
}

enum ScreenChoice: String, CaseIterable {
    case automatic
    case main
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var screen: ScreenChoice { didSet { defaults.set(screen.rawValue, forKey: "screen") } }
    @Published var autoOpen: Bool { didSet { defaults.set(autoOpen, forKey: "autoOpen") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var stallMinutes: Int { didSet { defaults.set(stallMinutes, forKey: "stallMinutes") } }
    @Published var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    @Published var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    @Published var islandStyle: IslandStyle { didSet { defaults.set(islandStyle.rawValue, forKey: "islandStyle") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["screen": ScreenChoice.automatic.rawValue, "autoOpen": false, "openOnHover": true, "notifyFinished": true, "sounds": true, "stallMinutes": 5,
                                     "islandStyle": IslandStyle.black.rawValue])
        screen = ScreenChoice(rawValue: defaults.string(forKey: "screen") ?? "") ?? .automatic
        autoOpen = defaults.bool(forKey: "autoOpen")
        sounds = defaults.bool(forKey: "sounds")
        openOnHover = defaults.bool(forKey: "openOnHover")
        notifyFinished = defaults.bool(forKey: "notifyFinished")
        stallMinutes = min(60, max(1, defaults.integer(forKey: "stallMinutes")))
        islandStyle = IslandStyle(rawValue: defaults.string(forKey: "islandStyle") ?? "") ?? .black
    }
}

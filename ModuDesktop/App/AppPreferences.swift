import Foundation
import Observation

@MainActor @Observable
final class AppPreferences {
    let defaults: UserDefaults
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var globalShortcut: GlobalShortcut? {
        didSet {
            if let globalShortcut, let data = try? JSONEncoder().encode(globalShortcut) { defaults.set(data, forKey: "globalShortcut") }
            // Keep a stored value so clearing does not restore the default on the next launch.
            else { defaults.set(Data(), forKey: "globalShortcut") }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        language = defaults.string(forKey: "language") ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
        if defaults.object(forKey: "globalShortcut") == nil { globalShortcut = .default }
        else if let data = defaults.data(forKey: "globalShortcut"), let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data), shortcut.isValid { globalShortcut = shortcut }
        else { globalShortcut = nil }
    }

    func t(_ english: String, _ chinese: String) -> String { language == "zh" ? chinese : english }
}

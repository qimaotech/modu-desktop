import Foundation
import Observation

@MainActor @Observable
final class AppPreferences {
    let defaults: UserDefaults
    var language: String { didSet { defaults.set(language, forKey: "language") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        language = defaults.string(forKey: "language") ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
    }

    func t(_ english: String, _ chinese: String) -> String { language == "zh" ? chinese : english }
}

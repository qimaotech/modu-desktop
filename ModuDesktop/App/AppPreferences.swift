import Foundation
import Observation

@MainActor @Observable
final class AppPreferences {
    let defaults: UserDefaults
    var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: "appLanguage") } }
    let activeLocale: AppLocale
    private let preferredLanguages: [String]
    var text: InterfaceText { InterfaceText(locale: activeLocale) }
    var languageChangeRequiresRestart: Bool { appLanguage.resolve(preferredLanguages: preferredLanguages) != activeLocale }
    var globalShortcut: GlobalShortcut? {
        didSet {
            if let globalShortcut, let data = try? JSONEncoder().encode(globalShortcut) { defaults.set(data, forKey: "globalShortcut") }
            // Keep a stored value so clearing does not restore the default on the next launch.
            else { defaults.set(Data(), forKey: "globalShortcut") }
        }
    }

    init(defaults: UserDefaults, preferredLanguages: [String] = AppLocalization.systemPreferredLanguages) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        self.appLanguage = appLanguage
        activeLocale = appLanguage.resolve(preferredLanguages: preferredLanguages)
        if defaults.object(forKey: "globalShortcut") == nil { globalShortcut = .default }
        else if let data = defaults.data(forKey: "globalShortcut"), let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data), shortcut.isValid { globalShortcut = shortcut }
        else { globalShortcut = nil }
    }

}

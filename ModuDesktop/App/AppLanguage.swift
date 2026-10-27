import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh_CN"
    case english = "en_US"

    func resolve(preferredLanguages: [String]) -> AppLocale {
        switch self {
        case .simplifiedChinese: .simplifiedChinese
        case .english: .english
        case .system:
            Locale(identifier: preferredLanguages.first ?? "en").language.languageCode?.identifier == "zh" ? .simplifiedChinese : .english
        }
    }
}

enum AppLocale: String, Sendable {
    case simplifiedChinese = "zh_CN"
    case english = "en_US"

    var locale: Locale { Locale(identifier: rawValue) }
    var resourceIdentifier: String { self == .simplifiedChinese ? "zh-Hans-CN" : "en-US" }
}

enum AppLocalization {
    // Capture the system preference before applying the process-local override.
    nonisolated static let systemPreferredLanguages = Locale.preferredLanguages

    static func configure(_ locale: AppLocale, defaults: UserDefaults = .standard) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = locale == .english ? [locale.resourceIdentifier] : [locale.resourceIdentifier, AppLocale.english.resourceIdentifier]
        arguments["AppleLocale"] = locale.rawValue
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}

@main
enum ModuDesktopLauncher {
    static func main() {
        let preferredLanguages = AppLocalization.systemPreferredLanguages
        let defaults = AppModel.launchDefaults()
        let preference = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        #if DEBUG
        let locale = ProcessInfo.processInfo.arguments.contains("--mock") ? AppLocale.english : preference.resolve(preferredLanguages: preferredLanguages)
        #else
        let locale = preference.resolve(preferredLanguages: preferredLanguages)
        #endif
        AppLocalization.configure(locale)
        ModuDesktopApp.main()
    }
}

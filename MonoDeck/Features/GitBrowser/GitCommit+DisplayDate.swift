import Foundation
import MonoDeckCore

@MainActor extension GitCommit {
    private static let displayDateParser = ISO8601DateFormatter()

    func displayDate(locale: AppLocale, timeZone: TimeZone = .current) -> String {
        guard let value = Self.displayDateParser.date(from: date) else { return date }
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale.locale, timeZone: timeZone))
    }
}

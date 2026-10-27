import Foundation
import ModuCore

extension GitCommit {
    func displayDate(locale: AppLocale, timeZone: TimeZone = .current) -> String {
        guard let value = ISO8601DateFormatter().date(from: date) else { return date }
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale.locale, timeZone: timeZone))
    }
}

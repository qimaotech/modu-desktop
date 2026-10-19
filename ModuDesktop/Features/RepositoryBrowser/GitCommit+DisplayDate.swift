import Foundation
import ModuCore

extension GitCommit {
    func displayDate(language: String) -> String {
        guard let value = ISO8601DateFormatter().date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "zh" ? "zh_CN" : "en_US")
        formatter.dateFormat = language == "zh" ? "yyyy年M月d日 HH:mm" : "MMM d, yyyy 'at' HH:mm"
        return formatter.string(from: value)
    }
}

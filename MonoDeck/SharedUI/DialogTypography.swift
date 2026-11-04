import SwiftUI

enum DialogTypography {
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: bodySize, weight: .regular)
    static let auxiliary = Font.system(size: 11, weight: .regular)
    static let path = auxiliary.monospaced()
    static let bodySize: CGFloat = 13
}

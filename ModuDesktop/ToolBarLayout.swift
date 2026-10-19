import AppKit
import ModuCore

struct ToolBarLayout {
    static let labelFontSize: CGFloat = 14
    static let iconWidth: CGFloat = 24
    static let labelSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let menuButtonWidth: CGFloat = 26
    static let dividerWidth: CGFloat = 1

    let columns: Int
    let rows: Int
    let buttonWidth: CGFloat
    let spacing: CGFloat

    init(buttonCount: Int, availableWidth: CGFloat?, minimumButtonWidth: CGFloat) {
        guard buttonCount > 0 else {
            columns = 0; rows = 0; buttonWidth = max(180, minimumButtonWidth); spacing = 16
            return
        }
        guard let availableWidth else {
            columns = buttonCount; rows = 1; buttonWidth = max(180, minimumButtonWidth); spacing = 16
            return
        }
        let width = max(0, availableWidth)
        let fittingColumns = max(1, Int((width + 8) / (minimumButtonWidth + 8)))
        columns = buttonCount == 4 && fittingColumns == 3 ? 2 : min(buttonCount, fittingColumns)
        rows = (buttonCount + columns - 1) / columns
        let count = CGFloat(columns)
        let gaps = CGFloat(columns - 1)
        if columns == 1 {
            spacing = 0
        } else if width > count * 220 + gaps * 16 {
            spacing = min(20, (width - count * 220) / gaps)
        } else {
            spacing = min(16, max(8, (width - count * 180) / gaps))
        }
        buttonWidth = max(minimumButtonWidth, min(220, (width - gaps * spacing) / count))
    }

    static func minimumButtonWidth(for tools: [ExternalTool]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let nameWidth = tools.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let contentWidth = iconWidth + labelSpacing + ceil(nameWidth) + 2 * horizontalPadding
        return max(130, contentWidth + dividerWidth + menuButtonWidth)
    }
}

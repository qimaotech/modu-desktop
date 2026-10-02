import AppKit
import ModuCore

struct ToolBarLayout {
    let columns: Int
    let rows: Int
    let buttonWidth: CGFloat
    let spacing: CGFloat

    init(buttonCount: Int, availableWidth: CGFloat?, minimumButtonWidth: CGFloat) {
        guard buttonCount > 0 else {
            columns = 0; rows = 0; buttonWidth = 180; spacing = 16
            return
        }
        guard let availableWidth else {
            columns = buttonCount; rows = 1; buttonWidth = 180; spacing = 16
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
        buttonWidth = min(220, max(minimumButtonWidth, (width - gaps * spacing) / count))
    }

    static func minimumButtonWidth(for tools: [ExternalTool]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let nameWidth = tools.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(130, ceil(nameWidth) + 73)
    }
}

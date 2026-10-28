import SwiftUI
import AppKit
import ModuCore

struct ToolBarView: View {
    var tools: [ExternalTool]
    var preferredToolIDs: [String: String]
    var directory: URL?
    var gitUnavailable: Bool
    var text: InterfaceText
    var open: (ExternalTool) -> Void
    var category: String?
    var availableWidth: CGFloat?
    var fixedButtonWidth: CGFloat?
    private var selectedTools: [ExternalTool] {
        (category.map { [$0] } ?? ["Git GUI", "Terminal", "Editor", "Agent"]).compactMap { category in
            let available = tools.filter { $0.category == category }
            return available.first { $0.id == preferredToolIDs[category] } ?? available.first
        }
    }

    var body: some View {
        let selectedTools = self.selectedTools
        let layout = ToolBarLayout(buttonCount: selectedTools.count, availableWidth: availableWidth,
                                   minimumButtonWidth: ToolBarLayout.minimumButtonWidth(for: selectedTools))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<layout.rows, id: \.self) { row in
                HStack(spacing: layout.spacing) {
                    ForEach(Array(selectedTools.dropFirst(row * layout.columns).prefix(layout.columns))) { tool in
                        button(tool: tool, width: fixedButtonWidth ?? layout.buttonWidth)
                    }
                }
            }
        }.fixedSize(horizontal: category != nil, vertical: true)
    }

    private func button(tool: ExternalTool, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { open(tool) } label: {
                HStack(spacing: ToolBarLayout.labelSpacing) {
                    Image("ToolIcons/\(tool.icon)").resizable().scaledToFit()
                        .frame(width: ToolBarLayout.iconWidth, height: ToolBarLayout.iconWidth)
                    Text(tool.name).font(.system(size: ToolBarLayout.labelFontSize, weight: .medium)).lineLimit(1)
                }.padding(.horizontal, ToolBarLayout.horizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverPlainButtonStyle(shape: Rectangle()))
            Rectangle().fill(DesignStyle.border).frame(width: ToolBarLayout.dividerWidth, height: 36)
            ToolMenuButton(tools: tools.filter { $0.category == tool.category }, width: width,
                           label: text.string(.uiChooseTool) + " " + text.statusText(tool.category),
                           open: { open($0) })
                .frame(width: ToolBarLayout.menuButtonWidth, height: 36)
                .modifier(ButtonHoverBackground(shape: Rectangle()))
        }
        .frame(width: width, height: 36)
        .background(DesignStyle.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignStyle.border, lineWidth: 1))
        .disabled(directory.map { !FileManager.default.isReadableFile(atPath: $0.path) } ?? true || (tool.category == "Git GUI" && gitUnavailable))
    }
}

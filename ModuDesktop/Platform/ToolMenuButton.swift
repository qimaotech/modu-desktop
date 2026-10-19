import SwiftUI
import AppKit
import ModuCore

struct ToolMenuButton: NSViewRepresentable {
    let tools: [ExternalTool]
    let width: CGFloat
    let label: String
    let open: (ExternalTool) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.buttonHovered) private var hovered

    func makeNSView(context: Context) -> ToolMenuControl { ToolMenuControl() }
    static func dismantleNSView(_ button: ToolMenuControl, coordinator: ()) { button.dismissMenu() }
    func updateNSView(_ button: ToolMenuControl, context: Context) {
        button.tools = tools
        button.menuWidth = width
        button.open = open
        button.isEnabled = enabled
        button.contentTintColor = hovered ? .black : .labelColor
        if !enabled { button.dismissMenu() }
        button.setAccessibilityLabel(label)
    }
}

final class ToolMenuControl: NSButton, NSMenuDelegate {
    var tools: [ExternalTool] = []
    var menuWidth: CGFloat = 180
    var open: (ExternalTool) -> Void = { _ in }
    private var presentedMenu: NSMenu?

    init() {
        super.init(frame: .zero)
        title = ""
        image = NSImage(named: "DesignIcons/Chevron")?.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(showTools)
        setAccessibilityRole(.menuButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }

    func menuOrigin(for menu: NSMenu) -> NSPoint {
        let rowsHeight = menu.items.compactMap { $0.view?.frame.height }.reduce(0, +)
        // AppKit anchors the menu content, excluding the padding above the first row.
        let topPadding = (menu.size.height - rowsHeight) / 2
        let offset = 4 + topPadding
        return NSPoint(x: bounds.maxX - menuWidth, y: isFlipped ? bounds.maxY + offset : bounds.minY - offset)
    }

    @objc private func showTools() {
        guard isEnabled, !tools.isEmpty else { return }
        let menu = makeMenu()
        presentedMenu = menu
        window?.makeFirstResponder(self)
        defer {
            presentedMenu = nil
            window?.makeFirstResponder(self)
        }
        menu.popUp(positioning: nil, at: menuOrigin(for: menu), in: self)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.minimumWidth = menuWidth
        menu.delegate = self
        for tool in tools {
            let item = NSMenuItem(title: tool.name, action: #selector(chooseTool(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool
            item.view = ToolMenuRow(tool: tool, width: menuWidth)
            menu.addItem(item)
        }
        return menu
    }

    func dismissMenu() { presentedMenu?.cancelTracking() }

    @objc private func chooseTool(_ item: NSMenuItem) {
        if let tool = item.representedObject as? ExternalTool { open(tool) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for candidate in menu.items {
            (candidate.view as? ToolMenuRow)?.highlighted = candidate === item
        }
    }
}

private final class ToolMenuRow: NSView {
    let tool: ExternalTool
    var highlighted = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { true }

    init(tool: ExternalTool, width: CGFloat) {
        self.tool = tool
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 8, yRadius: 8).fill()
        }
        NSImage(named: "ToolIcons/\(tool.icon)")?.draw(in: NSRect(x: 16, y: 7, width: 24, height: 24),
                                                      from: .zero, operation: .sourceOver, fraction: 1,
                                                      respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: tool.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: highlighted ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        label.draw(in: NSRect(x: 48, y: (bounds.height - label.size().height) / 2,
                             width: max(0, bounds.width - 64), height: label.size().height))
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

import SwiftUI
import AppKit

struct GitSplitView<Upper: View, Lower: View>: View {
    var upper: Upper
    var lower: Lower
    let defaults: UserDefaults
    var body: some View { NativeSplitView(first: upper, second: lower, vertical: false, defaults: defaults) }
}

struct WorkspaceSplitView<Sidebar: View, Detail: View>: View {
    var sidebar: Sidebar
    var detail: Detail
    var body: some View { NativeSplitView(first: sidebar, second: detail, vertical: true, defaults: nil) }
}

private struct NativeSplitView<First: View, Second: View>: NSViewRepresentable {
    var first: First
    var second: Second
    let vertical: Bool
    let defaults: UserDefaults?

    func makeNSView(context: Context) -> ModuSplitView {
        let split = ModuSplitView()
        split.isVertical = vertical; split.defaults = defaults
        split.dividerStyle = .thin
        let first = NSHostingView(rootView: first), second = NSHostingView(rootView: second)
        // NSSplitView owns the pane frames; hosting-view intrinsic constraints must not reset them.
        first.sizingOptions = []; second.sizingOptions = []
        split.addArrangedSubview(first); split.addArrangedSubview(second)
        // NSSplitView forwards sidebar action queries to its delegate; it must not delegate to itself.
        split.delegate = context.coordinator
        return split
    }

    func updateNSView(_ split: ModuSplitView, context: Context) {
        (split.arrangedSubviews[0] as? NSHostingView<First>)?.rootView = first
        (split.arrangedSubviews[1] as? NSHostingView<Second>)?.rootView = second
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.isVertical ? 240 : 136 }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.isVertical ? min(480, splitView.bounds.width - 660) : splitView.bounds.height - 148 }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            (notification.object as? ModuSplitView)?.saveDividerPosition()
        }
    }
}

final class ModuSplitView: NSSplitView {
    var defaults: UserDefaults?
    private var positioned = false
    private var resizing = false
    override var dividerThickness: CGFloat { isVertical ? 1 : 12 }

    override func drawDivider(in rect: NSRect) {
        if isVertical { NSColor.separatorColor.setFill(); rect.fill() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2, bounds.width > 0, bounds.height > 0 else { return }
        let total = isVertical ? bounds.width : bounds.height
        let previous = isVertical ? oldSize.width : oldSize.height
        let current = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let preferred: CGFloat
        if !positioned || previous <= 0 {
            preferred = isVertical ? (total < 1100 ? 240 : 338) : defaults?.object(forKey: "gitSplitRatio").map { total * (($0 as? Double) ?? 0.6) } ?? total - 148
        } else {
            preferred = isVertical ? current + (total - previous) * 98 / 300 : current * total / previous
        }
        let size = constrained(preferred)
        resizing = true
        if isVertical {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: size, height: bounds.height)
            arrangedSubviews[1].frame = NSRect(x: size + dividerThickness, y: 0, width: max(0, total - size - dividerThickness), height: bounds.height)
        } else {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: size)
            arrangedSubviews[1].frame = NSRect(x: 0, y: size + dividerThickness, width: bounds.width, height: max(0, total - size - dividerThickness))
        }
        positioned = true; resizing = false
    }

    fileprivate func saveDividerPosition() {
        guard !isVertical, positioned, !resizing, bounds.height > 0, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        defaults?.set(arrangedSubviews[0].frame.height / bounds.height, forKey: "gitSplitRatio")
    }

    private func constrained(_ value: CGFloat) -> CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        return min(max(0, total - dividerThickness), max(isVertical ? 240 : 136, min(isVertical ? 480 : total - 148, min(total - (isVertical ? 660 : 148), value))))
    }
}

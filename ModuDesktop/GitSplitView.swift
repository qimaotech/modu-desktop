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
        let first = context.coordinator.first, second = context.coordinator.second
        // NSSplitView owns the pane frames; hosting-view intrinsic constraints must not reset them.
        first.sizingOptions = []; second.sizingOptions = []
        split.addArrangedSubview(first.view); split.addArrangedSubview(second.view)
        if !vertical {
            split.contentHeights = { width in
                let proposal = NSSize(width: width, height: .greatestFiniteMagnitude)
                return (first.sizeThatFits(in: proposal).height, second.sizeThatFits(in: proposal).height)
            }
        }
        // NSSplitView forwards sidebar action queries to its delegate; it must not delegate to itself.
        split.delegate = context.coordinator
        return split
    }

    func updateNSView(_ split: ModuSplitView, context: Context) {
        context.coordinator.first.rootView = first
        context.coordinator.second.rootView = second
        split.resizeSubviews(withOldSize: split.bounds.size)
    }

    func makeCoordinator() -> Coordinator { Coordinator(first: first, second: second) }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let first: NSHostingController<First>
        let second: NSHostingController<Second>

        init(first: First, second: Second) {
            self.first = NSHostingController(rootView: first)
            self.second = NSHostingController(rootView: second)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            splitView.isVertical ? 240 : (splitView as? ModuSplitView)?.dividerRange.lowerBound ?? proposedMinimumPosition
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            splitView.isVertical ? min(480, splitView.bounds.width - 660) : (splitView as? ModuSplitView)?.dividerRange.upperBound ?? proposedMaximumPosition
        }
        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            if let split = splitView as? ModuSplitView, !split.isVertical, !split.canResize { return .zero }
            return proposedEffectiveRect
        }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            (notification.object as? ModuSplitView)?.saveDividerPosition()
        }
    }
}

final class ModuSplitView: NSSplitView {
    var defaults: UserDefaults?
    var contentHeights: ((CGFloat) -> (upper: CGFloat, lower: CGFloat))?
    private(set) var dividerRange: ClosedRange<CGFloat> = 0...0
    var canResize: Bool { dividerRange.lowerBound < dividerRange.upperBound }
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
        let size: CGFloat
        let lowerHeight: CGFloat
        if let contentHeights, !isVertical {
            let heights = contentHeights(bounds.width)
            let available = max(0, total - dividerThickness)
            if heights.upper + heights.lower <= available {
                size = heights.upper
                lowerHeight = heights.lower
                dividerRange = size...size
            } else {
                let upperMinimum = min(64, heights.upper), lowerMinimum = min(64, heights.lower)
                let minimumScale = min(1, available / max(1, upperMinimum + lowerMinimum))
                let minimum = max(upperMinimum * minimumScale, available - heights.lower)
                let maximum = max(minimum, min(heights.upper, available - lowerMinimum * minimumScale))
                dividerRange = minimum...maximum
                let preferred = defaults?.object(forKey: "gitSplitRatio").map { total * (($0 as? Double) ?? 0.6) } ?? total - 124
                size = min(maximum, max(minimum, preferred))
                lowerHeight = available - size
            }
            window?.invalidateCursorRects(for: self)
        } else {
            let preferred = !positioned || previous <= 0 ? (total < 1100 ? 240 : 338) : current + (total - previous) * 98 / 300
            size = constrained(preferred)
            lowerHeight = max(0, total - size - dividerThickness)
        }
        resizing = true
        if isVertical {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: size, height: bounds.height)
            arrangedSubviews[1].frame = NSRect(x: size + dividerThickness, y: 0, width: max(0, total - size - dividerThickness), height: bounds.height)
        } else {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: size)
            arrangedSubviews[1].frame = NSRect(x: 0, y: size + dividerThickness, width: bounds.width, height: lowerHeight)
        }
        positioned = true; resizing = false
    }

    fileprivate func saveDividerPosition() {
        guard !isVertical, canResize, positioned, !resizing, bounds.height > 0, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        defaults?.set(arrangedSubviews[0].frame.height / bounds.height, forKey: "gitSplitRatio")
    }

    private func constrained(_ value: CGFloat) -> CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        return min(max(0, total - dividerThickness), max(isVertical ? 240 : 112, min(isVertical ? 480 : total - 124, min(total - (isVertical ? 660 : 124), value))))
    }
}

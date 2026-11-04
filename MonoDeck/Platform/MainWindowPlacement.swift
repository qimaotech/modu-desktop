import AppKit
import SwiftUI

@MainActor enum MainWindowPlacement {
    static let minimumSize = CGSize(width: 900, height: 600)

    static func initial(defaults: UserDefaults, defaultVisibleRect: CGRect) -> WindowPlacement {
        guard let frame = savedFrame(defaults: defaults) else { return WindowPlacement() }
        let visibleRects = NSScreen.screens.map { placementRect(for: $0.visibleFrame) }
        let restored = constrainedFrame(frame, visibleRects: visibleRects, defaultVisibleRect: defaultVisibleRect)
        return WindowPlacement(restored.origin, size: restored.size)
    }

    static func save(_ window: NSWindow, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(placementRect(for: window.frame)) else { return }
        defaults.set(data, forKey: "mainWindowPlacement")
        defaults.removeObject(forKey: "mainWindowFrame")
    }

    private static func constrainedFrame(_ frame: CGRect, visibleRects: [CGRect], defaultVisibleRect: CGRect) -> CGRect {
        let visible = visibleRects.filter { $0.intersects(frame) }.max {
            intersectionArea($0, frame) < intersectionArea($1, frame)
        } ?? defaultVisibleRect
        let size = CGSize(width: min(visible.width, max(minimumSize.width, frame.width)),
                          height: min(visible.height, max(minimumSize.height, frame.height)))
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func savedFrame(defaults: UserDefaults) -> CGRect? {
        if let data = defaults.data(forKey: "mainWindowPlacement"), let frame = try? JSONDecoder().decode(CGRect.self, from: data),
           frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite, frame.width > 0, frame.height > 0 {
            return frame
        }
        guard let descriptor = defaults.string(forKey: "mainWindowFrame") else { return nil }
        // Let AppKit decode its opaque legacy descriptor before creating the actual scene window.
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "mainWindowFrameMigration")
        window.setFrame(from: descriptor)
        guard window.frame.width > 0, window.frame.height > 0 else { return nil }
        return placementRect(for: window.frame)
    }

    private static func placementRect(for frame: CGRect) -> CGRect {
        // WindowPlacement uses a top-left origin; AppKit uses the bottom-left of the primary display.
        CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

import AppKit
import Testing
@testable import MonoDeck

@MainActor struct SplitViewTests {
    @Test func sidebarDragSavesOnlyTheFinalWidthAndRestoresIt() throws {
        let suite = "MonoDeckTests.SplitView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(300.0, forKey: "sidebarWidth")
        let split = makeSplit(defaults: defaults, vertical: true)
        #expect(split.arrangedSubviews[0].frame.width == 300)

        for width in [320.0, 400.0] {
            split.setPosition(width, ofDividerAt: 0)
            split.rememberDividerPosition()
            split.resizeSubviews(withOldSize: split.bounds.size)
            #expect(abs(split.arrangedSubviews[0].frame.width - width) < 0.001)
            #expect(defaults.double(forKey: "sidebarWidth") == 300)
        }
        split.saveDividerPosition()
        #expect(defaults.double(forKey: "sidebarWidth") == 400)
        #expect(makeSplit(defaults: defaults, vertical: true).arrangedSubviews[0].frame.width == 400)
    }

    @Test func gitDividerKeepsUnsavedRatioDuringLayoutAndPreservesItWhenContentFits() throws {
        let suite = "MonoDeckTests.SplitView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.6, forKey: "gitSplitRatio")
        let split = makeSplit(defaults: defaults, vertical: false)
        split.setPosition(270, ofDividerAt: 0)
        split.rememberDividerPosition()
        split.setFrameSize(NSSize(width: 900, height: 600))
        split.resizeSubviews(withOldSize: split.bounds.size)
        #expect(split.arrangedSubviews[0].frame.height == 270)
        #expect(defaults.double(forKey: "gitSplitRatio") == 0.6)
        split.saveDividerPosition()
        #expect(defaults.double(forKey: "gitSplitRatio") == 0.45)
        #expect(makeSplit(defaults: defaults, vertical: false).arrangedSubviews[0].frame.height == 270)

        split.contentHeights = { _ in (32, 56) }
        split.resizeSubviews(withOldSize: split.bounds.size)
        #expect(!split.canResize)
        split.rememberDividerPosition()
        split.saveDividerPosition()
        #expect(defaults.double(forKey: "gitSplitRatio") == 0.45)
        split.contentHeights = { _ in (1_000, 1_000) }
        split.resizeSubviews(withOldSize: split.bounds.size)
        #expect(split.arrangedSubviews[0].frame.height == 270)
    }

    private func makeSplit(defaults: UserDefaults, vertical: Bool) -> MonoDeckSplitView {
        let split = MonoDeckSplitView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        split.isVertical = vertical
        split.defaults = defaults
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        if !vertical { split.contentHeights = { _ in (1_000, 1_000) } }
        split.resizeSubviews(withOldSize: .zero)
        return split
    }
}

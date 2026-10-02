import AppKit
import SwiftUI
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct ToolBarLayoutTests {
    @Test func toolbarFillsAvailableWidthUntilButtonsAndSpacingReachTheirLimits() {
        let cases: [(width: CGFloat, button: CGFloat, spacing: CGFloat)] = [
            (664, 160, 8), (700, 169, 8), (744, 180, 8), (756, 180, 12),
            (768, 180, 16), (814, 191.5, 16), (928, 220, 16), (934, 220, 18),
            (940, 220, 20), (1200, 220, 20)
        ]
        for item in cases {
            let layout = ToolBarLayout(buttonCount: 4, availableWidth: item.width, minimumButtonWidth: 160)
            #expect(layout.columns == 4 && layout.rows == 1)
            #expect(layout.buttonWidth == item.button && layout.spacing == item.spacing)
            #expect(layout.buttonWidth * 4 + layout.spacing * 3 == min(item.width, 940))
        }
    }

    @Test func fourToolsWrapIntoTwoColumnsBeforeUsingOneColumn() {
        for width: CGFloat in [663, 600, 400, 328] {
            let layout = ToolBarLayout(buttonCount: 4, availableWidth: width, minimumButtonWidth: 160)
            #expect(layout.columns == 2 && layout.rows == 2)
            #expect((160...220).contains(layout.buttonWidth) && (8...20).contains(layout.spacing))
            #expect(layout.buttonWidth * 2 + layout.spacing <= width)
        }
        for width: CGFloat in [327, 220, 160] {
            let layout = ToolBarLayout(buttonCount: 4, availableWidth: width, minimumButtonWidth: 160)
            #expect(layout.columns == 1 && layout.rows == 4 && layout.spacing == 0)
            #expect(layout.buttonWidth == min(width, 220))
        }
    }

    @Test func missingToolsDoNotReserveColumnsAndStartPageKeepsFixedWidth() {
        let empty = ToolBarLayout(buttonCount: 0, availableWidth: 814, minimumButtonWidth: 160)
        #expect(empty.columns == 0 && empty.rows == 0)
        let three = ToolBarLayout(buttonCount: 3, availableWidth: 512, minimumButtonWidth: 160)
        #expect(three.columns == 3 && three.rows == 1)
        #expect(three.buttonWidth * 3 + three.spacing * 2 == 512)
        let wrapped = ToolBarLayout(buttonCount: 3, availableWidth: 480, minimumButtonWidth: 160)
        #expect(wrapped.columns == 2 && wrapped.rows == 2 && wrapped.buttonWidth == 220)
        let start = ToolBarLayout(buttonCount: 1, availableWidth: nil, minimumButtonWidth: 160)
        #expect(start.columns == 1 && start.rows == 1 && start.buttonWidth == 180)
    }

    @Test func minimumWidthReservesEverySwitchableToolName() {
        let minimum = ToolBarLayout.minimumButtonWidth(for: ExternalTool.builtIn)
        #expect((130...180).contains(minimum))
        for tool in ExternalTool.builtIn {
            let textWidth = (tool.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]).width
            #expect(minimum - 73 >= textWidth)
        }
        #expect(ToolBarLayout.minimumButtonWidth(for: []) == 130)
        let shortNames = ExternalTool.builtIn.filter { ["codex", "fork", "cursor", "warp"].contains($0.id) }
        let shortMinimum = ToolBarLayout.minimumButtonWidth(for: shortNames)
        #expect(shortMinimum == 130)
        let narrow = ToolBarLayout(buttonCount: 4, availableWidth: 544, minimumButtonWidth: shortMinimum)
        #expect(narrow.columns == 4 && narrow.buttonWidth == 130 && narrow.spacing == 8)
        let wrapped = ToolBarLayout(buttonCount: 4, availableWidth: 543, minimumButtonWidth: shortMinimum)
        #expect(wrapped.columns == 2 && wrapped.rows == 2)
    }

    @Test func detailToolbarResizesWrapsAndKeepsMenusAligned() async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-toolbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: directory.lastPathComponent) }
        let tools = ExternalTools(applicationURL: { _ in directory.appending(path: "Tool.app") }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, toolService: tools)
        model.workspace = WorkspaceRecord(root: directory.path)
        model.tools = ExternalTool.builtIn
        let host = NSHostingView(rootView: RepositoryDetailView(model: model))
        let minimum = ToolBarLayout.minimumButtonWidth(for: model.tools)

        for width: CGFloat in [814, 700, 600, 300, 1000, 814] {
            host.frame = NSRect(x: 0, y: 0, width: width + 48, height: 400)
            host.layoutSubtreeIfNeeded()
            let buttons = menuButtons(in: host).sorted { first, second in
                let a = host.convert(first.bounds, from: first), b = host.convert(second.bounds, from: second)
                if abs(a.minY - b.minY) > 1 { return host.isFlipped ? a.minY < b.minY : a.minY > b.minY }
                return a.minX < b.minX
            }
            let layout = ToolBarLayout(buttonCount: 4, availableWidth: width, minimumButtonWidth: minimum)
            #expect(buttons.compactMap { $0.tools.first?.category } == ["Agent", "Git GUI", "Editor", "Terminal"])
            for (index, button) in buttons.enumerated() {
                let frame = host.convert(button.bounds, from: button)
                let expectedX = 24 + CGFloat(index % layout.columns) * (layout.buttonWidth + layout.spacing) + layout.buttonWidth - 26
                let expectedY = host.isFlipped ? 24 + CGFloat(index / layout.columns) * 48 : 400 - 24 - 36 - CGFloat(index / layout.columns) * 48
                #expect(abs(frame.minX - expectedX) < 1 && abs(frame.minY - expectedY) < 1)
                #expect(button.frame.size == NSSize(width: 26, height: 36))
                #expect(button.menuWidth == layout.buttonWidth)
                let menu = button.makeMenu()
                #expect(abs(menu.size.width - layout.buttonWidth) < 1)
                #expect(abs(frame.minX + button.menuOrigin(for: menu).x - (expectedX + 26 - layout.buttonWidth)) < 1)
            }
        }

        let previousWidths = menuButtons(in: host).map(\.menuWidth)
        model.openTool(try #require(model.tools.first { $0.id == "claude" }))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.preferredToolIDs["Agent"] == nil, model.message == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.preferredToolIDs["Agent"] == "claude" && model.message == nil)
        host.rootView = RepositoryDetailView(model: model)
        host.layoutSubtreeIfNeeded()
        #expect(menuButtons(in: host).map(\.menuWidth) == previousWidths)
        model.tools.removeAll { $0.category == "Git GUI" }
        host.frame.size.width = 648
        host.rootView = RepositoryDetailView(model: model)
        host.layoutSubtreeIfNeeded()
        let remaining = menuButtons(in: host)
        #expect(remaining.count == 3 && remaining.allSatisfy { $0.tools.first?.category != "Git GUI" })
        #expect(remaining.allSatisfy { abs($0.menuWidth * 3 + 32 - 600) < 1 })
        model.tools = ExternalTool.builtIn.filter { ["codex", "fork", "cursor", "warp"].contains($0.id) }
        host.frame.size.width = 592
        host.rootView = RepositoryDetailView(model: model)
        host.layoutSubtreeIfNeeded()
        let compact = menuButtons(in: host)
        #expect(compact.count == 4 && compact.allSatisfy { $0.menuWidth == 130 })
        #expect(compact.allSatisfy { abs(host.convert($0.bounds, from: $0).minY - host.convert(compact[0].bounds, from: compact[0]).minY) < 1 })
        model.tools = []
        host.rootView = RepositoryDetailView(model: model)
        host.layoutSubtreeIfNeeded()
        #expect(menuButtons(in: host).isEmpty)
    }

    private func menuButtons(in view: NSView) -> [ToolMenuControl] {
        ((view as? ToolMenuControl).map { [$0] } ?? []) + view.subviews.flatMap { menuButtons(in: $0) }
    }
}

import AppKit
import SwiftUI
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct RepositoryUpdatePresentationTests {
    @Test(arguments: ["en", "zh"])
    func mixedResultsOnlyShowUpdatedAndFailedRepositories(_ language: String) throws {
        let suite = "ModuUpdateResults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        var items = sampleItems()
        items.append(ItemResult(.repository("dirty"), status: "skipped"))
        items.append(ItemResult(.repository("cancelled"), status: "cancelled"))
        items.append(.notProcessed(.repository("pending")))
        var warning = ItemResult(.repository("warning"))
        warning.data = ["warning-code": "test-warning"]
        items.append(warning)
        items[0].data?["warning-code"] = "test-warning"
        for status in ["partial-success", "cancelled", "failed"] {
            let result = OperationResult(command: "repo.update", workspace: "/workspace", status: status, items: items)
            #expect(model.resultDisplayItems(result).map(\.resource) == [.repository("pixiu-frontend"), .repository("pixiu-ad-backend"), .repository("pixiu-worker")])
            #expect(model.resultSummaryText(result) == model.t("Updated 2 · Failed 1", "已更新 2 · 失败 1"))
            #expect(result.items.count == items.count)
        }
    }

    @Test(arguments: ["en", "zh"])
    func rowsKeepDistinctStatusesAndOnlyExposeExceptionalEffects(_ language: String) throws {
        let suite = "ModuUpdateRows.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        let cases: [(String, String?, RepositoryUpdateResultStatus, String, String, String)] = [
            ("success", "updated", .updated, "checkmark.circle", "Updated", "已更新"),
            ("failed", nil, .failed, "exclamationmark.circle", "Failed", "失败")
        ]
        for (status, disposition, expected, symbol, english, chinese) in cases {
            var item = ItemResult(.repository("pixiu-frontend"), status: status)
            if let disposition { item.data = ["disposition": disposition] }
            item.effects = [.init("update-refs", "/workspace/repositories/pixiu-frontend")]
            let row = RepositoryUpdateResultRow(model: model, item: item, workspace: "/workspace")
            #expect(row.repositoryName == "pixiu-frontend")
            #expect(row.fullPath == "/workspace/repositories/pixiu-frontend")
            #expect(row.status == expected && row.statusLabel == model.t(english, chinese))
            #expect(row.visibleEffects.isEmpty == (status == "success"))
            #expect(row.status.symbolName == symbol)
            #expect(NSImage(systemSymbolName: row.status.symbolName, accessibilityDescription: nil) != nil)
        }
        var warning = ItemResult(.repository("warning"))
        warning.data = ["disposition": "updated", "warning-code": "test-warning"]
        let row = RepositoryUpdateResultRow(model: model, item: warning, workspace: nil)
        #expect(row.status == .updated && row.statusLabel == model.t("Updated", "已更新"))
    }

    @Test(arguments: ["en", "zh"], [NSAppearance.Name.aqua, .darkAqua])
    func resultSheetKeepsItsWidthAndScrollsLongLists(_ language: String, _ appearance: NSAppearance.Name) throws {
        let suite = "ModuUpdateLayout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        for count in [5, 50] {
            var items = sampleItems()
            if count > items.count {
                items += (items.count..<count).map { index in
                    var item = ItemResult(.repository("repository-\(index)"))
                    item.data = ["disposition": "updated"]
                    return item
                }
            }
            let result = OperationResult(command: "repo.update", workspace: "/workspace", status: "partial-success", items: items)
            let host = NSHostingView(rootView: ResultView(model: model, result: result, dismiss: {}))
            host.appearance = NSAppearance(named: appearance)
            host.setFrameSize(host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == 460 && host.frame.height > 0 && host.frame.height <= 560)
            let visibleItems = model.resultDisplayItems(result)
            #expect(visibleItems.count == count - 2)
            let visibleResult = OperationResult(command: result.command, workspace: result.workspace, status: result.status, items: visibleItems)
            let visibleHost = NSHostingView(rootView: ResultView(model: model, result: visibleResult, dismiss: {}))
            visibleHost.appearance = host.appearance
            visibleHost.setFrameSize(visibleHost.fittingSize)
            let visibleWindow = NSWindow(contentRect: visibleHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            visibleWindow.isReleasedWhenClosed = false
            visibleWindow.contentView = visibleHost
            defer { visibleWindow.close() }
            visibleHost.layoutSubtreeIfNeeded()
            #expect(host.fittingSize == visibleHost.fittingSize)
            let scroll = try #require(scrollViews(in: host).first)
            #expect(scroll.frame.height > 0 && scroll.frame.height <= 360)
            if count == 50 {
                let document = try #require(scroll.documentView)
                #expect(document.frame.height > scroll.frame.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.maxY - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(scroll.contentView.bounds.minY > 0)
                #expect(scroll.documentVisibleRect.maxY >= document.frame.maxY - 1)
            } else {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "update-results-\(language)-\(appearance.rawValue).png")
            }
        }
    }

    @Test(arguments: ["en", "zh"])
    func compactDetailsUsesExplicitCollapsedAndExpandedLayout(_ language: String) throws {
        let suite = "ModuUpdateDetails.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        var heights: [CGFloat] = []
        for expanded in [false, true, false] {
            let content = DisclosureGroup(isExpanded: .constant(expanded)) {
                Text("/workspace/repositories/pixiu-frontend").font(.caption)
            } label: {
                Text(model.t("Details", "详细信息"))
            }
            .disclosureGroupStyle(RepositoryResultDetailsStyle(identifier: "details", expandedLabel: model.t("Expanded", "已展开"), collapsedLabel: model.t("Collapsed", "已折叠")))
            .font(.callout).frame(width: 412)
            let host = NSHostingView(rootView: content)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            heights.append(host.fittingSize.height)
        }
        #expect(heights[0] == 15)
        #expect(heights[1] > heights[0])
        #expect(heights[2] == heights[0])
    }

    private func sampleItems() -> [ItemResult] {
        var items = ["pixiu-frontend", "pixiu-ad-backend", "pixiu-ad-server", "pixiu-toolkit"].enumerated().map { index, name in
            var item = ItemResult(.repository(name))
            item.data = ["disposition": index < 2 ? "updated" : "up-to-date"]
            item.effects = [.init("update-refs", "/workspace/\(item.resource.path)"), .init("fast-forward", "/workspace/\(item.resource.path)")]
            return item
        }
        var failed = ItemResult(.repository("pixiu-worker"), status: "failed", error: ModuError("git-failed", "Could not fast-forward."))
        failed.effects = [.init("update-refs", "/workspace/\(failed.resource.path)")]
        items.append(failed)
        return items
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

}

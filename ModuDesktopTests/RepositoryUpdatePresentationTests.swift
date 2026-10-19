import AppKit
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
        items.append(ItemResult(.repository("dirty"), status: .skipped))
        items.append(ItemResult(.repository("cancelled"), status: .cancelled))
        items.append(.notProcessed(.repository("pending")))
        var warning = ItemResult(.repository("warning"))
        warning.data = ["warning-code": "test-warning"]
        items.append(warning)
        items[0].data?["warning-code"] = "test-warning"
        for status in ["partial-success", "cancelled", "failed"] {
            let result = OperationResult(command: "repo.update", workspace: "/workspace", status: OperationStatus(rawValue: status)!, items: items)
            #expect(model.presentation.text.resultDisplayItems(result).map(\.resource) == [.repository("pixiu-frontend"), .repository("pixiu-ad-backend"), .repository("pixiu-worker")])
            #expect(model.presentation.text.resultSummaryText(result) == model.t("Updated 2 · Failed 1", "已更新 2 · 失败 1"))
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
            var item = ItemResult(.repository("pixiu-frontend"), status: OperationStatus(rawValue: status)!)
            if let disposition { item.data = ["disposition": disposition] }
            item.effects = [.init("update-refs", "/workspace/repositories/pixiu-frontend")]
            let row = RepositoryUpdateResultRow(text: model.presentation.text, item: item, workspace: "/workspace")
            #expect(row.repositoryName == "pixiu-frontend")
            #expect(row.fullPath == "/workspace/repositories/pixiu-frontend")
            #expect(row.status == expected && row.statusLabel == model.t(english, chinese))
            #expect(row.visibleEffects.isEmpty == (status == "success"))
            #expect(row.status.symbolName == symbol)
            #expect(NSImage(systemSymbolName: row.status.symbolName, accessibilityDescription: nil) != nil)
        }
        var warning = ItemResult(.repository("warning"))
        warning.data = ["disposition": "updated", "warning-code": "test-warning"]
        let row = RepositoryUpdateResultRow(text: model.presentation.text, item: warning, workspace: nil)
        #expect(row.status == .updated && row.statusLabel == model.t("Updated", "已更新"))
    }

    private func sampleItems() -> [ItemResult] {
        var items = ["pixiu-frontend", "pixiu-ad-backend", "pixiu-ad-server", "pixiu-toolkit"].enumerated().map { index, name in
            var item = ItemResult(.repository(name))
            item.data = ["disposition": index < 2 ? "updated" : "up-to-date"]
            item.effects = [.init("update-refs", "/workspace/\(item.resource.path)"), .init("fast-forward", "/workspace/\(item.resource.path)")]
            return item
        }
        var failed = ItemResult(.repository("pixiu-worker"), status: .failed, error: ModuError("git-failed", "Could not fast-forward."))
        failed.effects = [.init("update-refs", "/workspace/\(failed.resource.path)")]
        items.append(failed)
        return items
    }

}

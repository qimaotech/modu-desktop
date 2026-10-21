import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct PresentationTests {
    @Test func repositoryAdditionFailureKeepsFormAndClearsDetailsWithTheError() async throws {
        try await withModel { model in
            let record = model.workspace.record
            model.management.sheet = .add
            let raw = "Git ls-remote failed (128). ERROR: Repository not found."
            model.management.run { _, root, _ in
                .init(command: "repo.add", workspace: root.path, status: .failed, items: [ItemResult(.repository("missing"), status: .failed, error: ModuError("git-failed", raw))])
            }
            await (try #require(model.operation)).value
            #expect(model.management.sheet == .add && model.presentation.result == nil && !model.busy)
            #expect(model.management.formError != nil && model.management.formErrorDetails == raw)
            #expect(model.workspace.record == record)
            model.management.formError = nil
            #expect(model.management.formErrorDetails == nil)
        }
    }

    @Test func successfulCreationPreservesWarningsAndTheirEffects() async throws {
        try await withModel { model in
            for warning in ["branch-behind-base", "branch-comparison-unavailable", "none"] {
                model.management.sheet = .create
                var item = ItemResult(.member("feature", "repo"))
                item.effects = [.init("create-worktree", item.resource.path)]
                if warning != "none" {
                    item.data = ["warning-code": warning, "reused-branch": "feature", "comparison-base": "origin/main"]
                    item.message = "Reused branch needs attention."
                }
                let outcome = OperationResult(command: "worktree.create", workspace: try #require(model.workspace.record).root, items: [item])
                model.management.run { _, _, _ in outcome }
                await (try #require(model.operation)).value
                #expect(model.management.sheet == nil && !model.busy && model.presentation.completionMessage == nil)
                #expect((model.presentation.result != nil) == (warning != "none"))
                if let result = model.presentation.result {
                    #expect(result.status == .success && result.exitCode == 0)
                    #expect(result.items.first?.data == item.data && result.items.first?.message == item.message)
                    #expect(result.items.first?.effects == item.effects)
                    #expect(model.presentation.text.resultDisplayItems(result).map(\.resource) == [item.resource])
                }
                model.presentation.dismissResult()
            }
        }
    }

    @Test func cancellingDeletionPreservesContentAndCleansUpAfterDismissal() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        for kind in ["repository", "group", "member", "edit"] {
            if kind == "edit" {
                model.management.sheet = .edit
                model.management.edit("feature", members: [])
                await model.management.editPreviewTask?.value
            } else {
                let request: DeleteRequest = kind == "repository" ? .repository("repo") : kind == "group" ? .group("feature") : .member(group: "feature", repo: "repo")
                model.management.prepareDelete(request)
                await model.management.deletePreviewTask?.value
            }
            try #require(model.management.canConfirmDelete)
            let resources = model.management.deletion.map(\.resource)
            if kind == "edit" {
                model.management.sheet = .edit
                #expect(model.management.pendingEdit?.0 == "feature" && model.management.pendingEdit?.1 == [])
                #expect(model.management.deletion.map(\.resource) == resources)
                model.management.sheet = .delete
            }
            model.management.sheet = nil
            #expect(!model.management.canConfirmDelete)
            #expect(!model.busy && model.operation == nil && model.management.progressPresentation == nil)
            #expect(model.management.deletion.map(\.resource) == resources && model.management.deletionResources == resources)
            if kind == "edit" {
                #expect(model.management.pendingEdit?.0 == "feature" && model.management.pendingEdit?.1 == [])
            } else { #expect(model.management.deleteRequest != nil && model.management.pendingEdit == nil) }
            model.management.finishDismissal()
            #expect(model.management.deleteRequest == nil && model.management.pendingEdit == nil && model.management.deletion.isEmpty && model.management.deletionResources.isEmpty)
            #expect(model.management.deletionPresentation.resources == resources && model.management.deletionPresentation.targets.map(\.resource) == resources)
            #expect(model.management.deletionPresentation.editingGroup == (kind == "edit"))
            model.management.confirmDelete()
            #expect(model.operation == nil && model.workspace.record == record)
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(PathSafety.exists(record.repositoryURL("repo")) && PathSafety.exists(record.groupURL("feature")) && PathSafety.exists(record.memberURL("feature", "repo")))
        }
    }

    @Test(arguments: ["partial-success", "cancelled"])
    func repositoryImportRetainsCompletedEffectsAndUnprocessedItems(_ status: String) async throws {
        try await withModel { model in
            model.management.sheet = .add
            model.management.run { _, root, _ in
                var added = ItemResult(.repository("added"))
                added.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)]
                let remaining = status == "cancelled" ? ItemResult.notProcessed(.repository("remaining")) : ItemResult(.repository("remaining"), status: .failed)
                return OperationResult(command: "repo.import-yaml", workspace: root.path, status: OperationStatus(rawValue: status)!, items: [added, remaining])
            }
            await (try #require(model.operation)).value
            let result = try #require(model.presentation.result)
            #expect(!model.busy && model.management.sheet == nil && result.status.rawValue == status)
            #expect(result.items.map(\.resource) == [.repository("added"), .repository("remaining")])
            #expect(result.items.first?.effects.count == 1)
            #expect(result.items.last?.status.rawValue == (status == "cancelled" ? "skipped" : "failed"))
            #expect(result.items.last?.reasonCode == (status == "cancelled" ? "not-processed" : nil))
            #expect(model.management.progressPresentation != nil)
        }
    }

    @Test func settingsImportDismissesOnlySuccessOrCancellationWithoutEffects() async throws {
        try await withModel { model in
            for (status, effects, quitting, presentsResult) in [
                ("success", true, false, false), ("failed", false, false, true),
                ("partial-success", true, false, true), ("skipped", false, false, true),
                ("cancelled", false, false, false), ("cancelled", true, false, true),
                ("success", true, true, true)
            ] {
                model.presentation.quitPending = quitting; model.presentation.resultHost = .settings
                model.management.run { _, root, _ in
                    var item = ItemResult(.repository("repo"), status: OperationStatus(rawValue: status)!)
                    if effects { item.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)] }
                    return OperationResult(command: "workspace.import", workspace: root.path, status: OperationStatus(rawValue: status)!, items: [item])
                }
                #expect(model.busy && model.presentation.resultHost == .settings)
                let operation = try #require(model.operation)
                await operation.value
                #expect(!model.busy)
                #expect((model.presentation.result != nil) == presentsResult)
                #expect(model.presentation.resultHost == (presentsResult ? .settings : .main))
                #expect(model.presentation.completionMessage == nil)
                model.presentation.quitPending = false
                model.presentation.dismissResult()
            }
        }
    }

    @Test func repositoryUpdateKeepsChangedAndFailedResults() async throws {
        try await withModel { model in
            for (status, dispositions) in [
                ("success", ["updated", "up-to-date"]),
                ("success", ["up-to-date"]),
                ("partial-success", ["updated", "failed"]),
                ("cancelled", ["updated", "cancelled", "not-processed"]),
                ("cancelled", ["cancelled", "not-processed"])
            ] {
                model.management.run { _, root, _ in
                    let items = dispositions.enumerated().map { index, disposition in
                        let resource = Resource.repository("repo-\(index)")
                        if disposition == "not-processed" { return ItemResult.notProcessed(resource) }
                        if ["failed", "cancelled"].contains(disposition) { return ItemResult(resource, status: OperationStatus(rawValue: disposition)!) }
                        var item = ItemResult(resource)
                        item.data = ["disposition": disposition]
                        return item
                    }
                    return OperationResult(command: "repo.update", workspace: root.path, status: OperationStatus(rawValue: status)!, items: items)
                }
                await (try #require(model.operation)).value
                let visible = dispositions.indices.filter { ["updated", "failed"].contains(dispositions[$0]) }
                #expect(!model.busy && model.progress == nil && model.presentation.completionMessage == nil)
                #expect((model.presentation.result != nil) == !visible.isEmpty)
                if let result = model.presentation.result {
                    #expect(result.items.count == dispositions.count)
                    #expect(model.presentation.text.resultDisplayItems(result).map(\.resource) == visible.map { .repository("repo-\($0)") })
                }
                model.presentation.dismissResult()
            }
        }
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = WorkspaceService(store: .init(support: directory.appending(path: "support")))
        let record = WorkspaceRecord(root: PathSafety.canonical(directory).path)
        try service.store.save(record)
        let model = AppModel(defaults: defaults, service: service)
        model.workspace.record = record
        // Result handling needs no saved launch preference or Git reload; real operations are tested separately.
        try await body(model)
    }
}

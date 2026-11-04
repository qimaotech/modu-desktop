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
            model.management.sheet = .create
            var item = ItemResult(.member("feature", "repo"))
            item.effects = [.init("create-worktree", item.resource.path)]
            item.data = ["warning-code": "branch-behind-base", "reused-branch": "feature", "comparison-base": "origin/main"]
            item.message = "Reused branch needs attention."
            let outcome = OperationResult(command: "worktree.create", workspace: try #require(model.workspace.record).root, items: [item])
            model.management.run { _, _, _ in outcome }
            await (try #require(model.operation)).value
            #expect(model.management.sheet == nil && !model.busy && model.presentation.completionMessage == nil)
            let result = try #require(model.presentation.result)
            #expect(result.status == .success && result.exitCode == 0)
            #expect(result.items.first?.data == item.data && result.items.first?.message == item.message)
            #expect(result.items.first?.effects == item.effects)
        }
    }

    @Test func cancellingDeletionPreservesContentAndCleansUpAfterDismissal() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        try await fixture.prepareGroup("feature", repositories: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        for editing in [false, true] {
            if editing {
                model.management.sheet = .edit
                model.management.edit("feature", members: [])
                await model.management.editPreviewTask?.value
            } else {
                model.management.prepareDelete(.repository("repo"))
                await model.management.deletePreviewTask?.value
            }
            try #require(model.management.canConfirmDelete)
            model.management.sheet = nil
            #expect(!model.management.canConfirmDelete)
            #expect(!model.busy && model.operation == nil && model.management.progressPresentation == nil)
            model.management.finishDismissal()
            #expect(model.management.deleteRequest == nil && model.management.pendingEdit == nil && model.management.deletion.isEmpty && model.management.deletionResources.isEmpty)
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
                ("partial-success", true, false, true),
                ("cancelled", false, false, false), ("cancelled", true, false, true),
                ("success", true, true, true)
            ] {
                model.presentation.quitPending = false; model.presentation.resultHost = .settings
                model.management.run { _, root, _ in
                    var item = ItemResult(.repository("repo"), status: OperationStatus(rawValue: status)!)
                    if effects { item.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)] }
                    return OperationResult(command: "workspace.import", workspace: root.path, status: OperationStatus(rawValue: status)!, items: [item])
                }
                #expect(model.busy && model.presentation.resultHost == .settings)
                model.presentation.quitPending = quitting
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

    @Test(arguments: ["message", "sheet", "result", "sheet-dismissal", "background"])
    func detailFailuresWaitForPresentationWithoutOverwritingOtherUI(_ blocker: String) async throws {
        try await withModel { model in
            try await failMissingRepository(model)
            let failure = try #require(model.workspace.details.pendingFailure)
            switch blocker {
            case "message": model.presentation.presentMessage("Existing message", title: "Existing title")
            case "sheet": model.management.sheet = .add
            case "result": model.presentation.result = .init(command: "repo.update", workspace: failure.workspace)
            case "sheet-dismissal": model.presentation.mainSheetVisible = true
            default: model.workspace.setActive(false)
            }
            #expect(model.detailFailurePresentationID == nil)
            model.presentDetailFailureIfPossible()
            #expect(model.workspace.details.pendingFailure?.id == failure.id)
            #expect(model.presentation.message == (blocker == "message" ? "Existing message" : nil))
            switch blocker {
            case "message": model.dismissMessage()
            case "sheet": model.management.sheet = nil
            case "result": model.presentation.dismissResult()
            case "sheet-dismissal": model.presentation.mainSheetVisible = false
            default: model.workspace.setActive(true, refresh: false)
            }
            #expect(model.detailFailurePresentationID == failure.id)
            model.presentDetailFailureIfPossible()
            #expect(model.presentation.message != nil)
            #expect(model.presentation.messageHost == .main && model.workspace.details.pendingFailure == nil)
        }
    }

    @Test(arguments: ["selection", "workspace", "cancellation"])
    func delayedDetailFailureIsDiscardedWhenContextEnds(_ change: String) async throws {
        try await withModel { model in
            try await failMissingRepository(model)
            let failure = try #require(model.workspace.details.pendingFailure)
            model.presentation.presentMessage("Existing message", title: "Existing title")
            switch change {
            case "selection":
                model.workspace.selection = nil
                model.workspace.selection = failure.resource
            case "workspace":
                var record = try #require(model.workspace.record)
                record.root += "/other-workspace"
                model.workspace.record = record
                model.workspace.selection = failure.resource
            default: model.workspace.details.pause()
            }
            model.dismissMessage()
            model.presentDetailFailureIfPossible()
            #expect(model.workspace.details.pendingFailure == nil && model.presentation.message == nil)
            if change != "cancellation" {
                await model.workspace.details.detailTask?.value
                let next = try #require(model.workspace.details.pendingFailure)
                #expect(next.id != failure.id && next.generation != failure.generation)
                model.presentDetailFailureIfPossible()
                #expect(model.presentation.message != nil)
            }
        }
    }

    private func failMissingRepository(_ model: AppModel) async throws {
        var record = try #require(model.workspace.record)
        record.repositories = [Repository(url: "https://modu-test.invalid/repo.git")]
        model.workspace.record = record
        model.workspace.selection = .repository("repo")
        await model.workspace.details.detailTask?.value
        #expect(model.workspace.details.failureForPresentation != nil)
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
        do {
            try await body(model)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }
}

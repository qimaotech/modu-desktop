import Foundation
import Testing
import Observation
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct PresentationTests {
    @Test func repositoryAdditionFailureKeepsFormAndClearsDetailsWithTheError() async throws {
        try await withModel { model in
            let record = model.workspace
            model.sheet = .add
            let raw = "Git ls-remote failed (128). ERROR: Repository not found."
            model.run { _, root, _ in
                .init(command: "repo.add", workspace: root.path, status: "failed", items: [ItemResult(.repository("missing"), status: "failed", error: ModuError("git-failed", raw))])
            }
            await (try #require(model.operation)).value
            #expect(model.sheet == .add && model.result == nil && !model.busy)
            #expect(model.formError != nil && model.formErrorDetails == raw)
            #expect(model.workspace == record)
            model.formError = nil
            #expect(model.formErrorDetails == nil)
        }
    }

    @Test func successfulCreationPreservesWarningsAndTheirEffects() async throws {
        try await withModel { model in
            for warning in ["branch-behind-base", "branch-comparison-unavailable", "none"] {
                model.sheet = .create
                var item = ItemResult(.member("feature", "repo"))
                item.effects = [.init("create-worktree", item.resource.path)]
                if warning != "none" {
                    item.data = ["warning-code": warning, "reused-branch": "feature", "comparison-base": "origin/main"]
                    item.message = "Reused branch needs attention."
                }
                let outcome = OperationResult(command: "worktree.create", workspace: try #require(model.workspace).root, items: [item])
                model.run { _, _, _ in outcome }
                await (try #require(model.operation)).value
                #expect(model.sheet == nil && !model.busy && model.completionMessage == nil)
                #expect((model.result != nil) == (warning != "none"))
                if let result = model.result {
                    #expect(result.status == "success" && result.exitCode == 0)
                    #expect(result.items.first?.data == item.data && result.items.first?.message == item.message)
                    #expect(result.items.first?.effects == item.effects)
                    #expect(model.resultDisplayItems(result).map(\.resource) == [item.resource])
                }
                model.dismissResult()
            }
        }
    }

    @Test func cancellingDeletionPreservesContentAndCleansUpAfterDismissal() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = record
        for kind in ["repository", "group", "member", "edit"] {
            if kind == "edit" {
                model.sheet = .edit
                model.edit("feature", members: [])
                await model.editPreviewTask?.value
            } else {
                let request: DeleteRequest = kind == "repository" ? .repository("repo") : kind == "group" ? .group("feature") : .member(group: "feature", repo: "repo")
                model.prepareDelete(request)
                await model.deletePreviewTask?.value
            }
            try #require(model.canConfirmDelete)
            let resources = model.deletion.map(\.resource)
            if kind == "edit" {
                model.sheet = .edit
                #expect(model.pendingEdit?.0 == "feature" && model.pendingEdit?.1 == [])
                #expect(model.deletion.map(\.resource) == resources)
                model.sheet = .delete
            }
            model.sheet = nil
            #expect(!model.canConfirmDelete)
            #expect(!model.busy && model.operation == nil && model.managementProgress == nil)
            #expect(model.deletion.map(\.resource) == resources && model.deletionResources == resources)
            if kind == "edit" {
                #expect(model.pendingEdit?.0 == "feature" && model.pendingEdit?.1 == [])
            } else { #expect(model.deleteRequest != nil && model.pendingEdit == nil) }
            model.finishManagementDismissal()
            #expect(model.deleteRequest == nil && model.pendingEdit == nil && model.deletion.isEmpty && model.deletionResources.isEmpty)
            #expect(model.deletionPresentation.resources == resources && model.deletionPresentation.targets.map(\.resource) == resources)
            #expect(model.deletionPresentation.editingGroup == (kind == "edit"))
            model.confirmDelete()
            #expect(model.operation == nil && model.workspace == record)
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(PathSafety.exists(record.repositoryURL("repo")) && PathSafety.exists(record.groupURL("feature")) && PathSafety.exists(record.memberURL("feature", "repo")))
        }
    }

    @Test func repositoryDeletionKeepsProgressThroughDismissalAndReopensConfirmation() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.prepareDelete(.repository("repo"))
        await model.deletePreviewTask?.value
        try #require(model.canConfirmDelete)
        model.confirmDelete()
        await (try #require(model.operation)).value
        await model.detailPreloadTask?.value
        #expect(!model.busy && model.sheet == nil && model.result == nil)
        #expect(model.workspace?.repositories.isEmpty == true && model.workspace?.groups["feature"]?.repositories == [])
        let presentation = try #require(model.managementProgress)
        #expect(presentation.progress?.target == "repositories/repo" && presentation.progress?.phase == "Deleted")
        model.sheet = nil
        model.finishManagementDismissal()
        #expect(model.deleteRequest == nil && model.pendingEdit == nil && model.deletion.isEmpty)
        #expect(model.managementProgress != nil)
        model.prepareDelete(.group("feature"))
        #expect(model.sheet == .delete && model.managementProgress == nil)
        await model.deletePreviewTask?.value
        #expect(model.canConfirmDelete && model.deletionResources == [.group("feature")])
        model.sheet = nil
    }

    @Test func worktreeCreationKeepsProgressThroughDismissalAndReopensAsForm() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .create
        model.create("feature", members: ["repo"])
        #expect(model.busy && model.managementProgress != nil)
        withObservationTracking {
            _ = model.busy
        } onChange: {
            MainActor.assumeIsolated {
                #expect(model.sheet == nil && model.result == nil && model.managementProgress != nil)
            }
        }
        await (try #require(model.operation)).value
        #expect(!model.busy && model.progress == nil)
        #expect(model.selection == .group("feature") && model.expandedGroups.contains("feature"))
        let presentation = try #require(model.managementProgress)
        #expect(presentation.progress?.target == "worktrees/feature/repo")
        #expect(model.managementProgress != nil)
        model.sheet = .create
        #expect(model.managementProgress == nil)
        model.sheet = nil
        await model.detailPreloadTask?.value
    }

    @Test func worktreeCreationFailureRestoresFormForRetry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        _ = try await fixture.service.git.run(["branch", "feature", "HEAD~1"], at: fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .create
        model.create("feature", members: ["repo"])
        await (try #require(model.operation)).value
        #expect(!model.busy && model.managementProgress == nil && model.formError != nil)
        #expect(model.sheet == .create && model.result == nil)
        _ = try await fixture.service.git.run(["branch", "-d", "feature"], at: fixture.root)
        model.create("feature", members: ["repo"])
        #expect(model.busy && model.managementProgress != nil && model.formError == nil)
        #expect(model.managementProgress != nil)
        await (try #require(model.operation)).value
        #expect(!model.busy && model.sheet == nil && model.result == nil)
        model.sheet = .create
        #expect(model.managementProgress == nil)
        #expect(model.sheet == .create)
        model.sheet = nil
        await model.detailPreloadTask?.value
    }

    @Test func worktreeCreationCancellationWithoutEffectsKeepsProgressDuringDismissal() async throws {
        try await withModel { model in
            let record = model.workspace
            model.sheet = .create
            model.run { _, root, _ in .init(command: "worktree.create", workspace: root.path, status: "cancelled") }
            await (try #require(model.operation)).value
            #expect(!model.busy && model.sheet == nil && model.result == nil && model.managementProgress != nil)
            #expect(model.workspace == record)
            model.sheet = .create
            #expect(model.managementProgress == nil)
        }
    }

    @Test func repositoryImportTransitionsDirectlyToItsCompletionState() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try fixture.service.store.load(fixture.root)
        for outcome in ["success", "skipped", "invalid"] {
            let before = try #require(model.workspace)
            model.sheet = .add
            model.importRepositories(outcome == "invalid" ? "{invalid YAML" : "url: \(fixture.remoteURL)", filename: "repositories.yaml")
            #expect(model.busy)
            await (try #require(model.operation)).value
            await model.detailPreloadTask?.value
            #expect(!model.busy && model.importFileName == nil)
            #expect(model.sheet == (outcome == "invalid" ? .add : nil))
            #expect(model.result?.status == (outcome == "skipped" ? "skipped" : nil))
            #expect((model.formError != nil) == (outcome == "invalid"))
            #expect((model.managementProgress != nil) == (outcome != "invalid"))
            if outcome == "success" {
                #expect(model.selection == .repository("repo") && model.workspace?.repositories.count == 1)
                #expect(PathSafety.exists(fixture.root.appending(path: "repositories/repo/.git")))
            } else { #expect(model.workspace == before) }
            #expect(try fixture.service.store.load(fixture.root) == model.workspace)
            model.dismissResult()
            model.sheet = nil
        }
    }

    @Test(arguments: ["partial-success", "cancelled"])
    func repositoryImportRetainsCompletedEffectsAndUnprocessedItems(_ status: String) async throws {
        try await withModel { model in
            model.sheet = .add
            model.run { _, root, _ in
                var added = ItemResult(.repository("added"))
                added.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)]
                let remaining = status == "cancelled" ? ItemResult.notProcessed(.repository("remaining")) : ItemResult(.repository("remaining"), status: "failed")
                return OperationResult(command: "repo.import-yaml", workspace: root.path, status: status, items: [added, remaining])
            }
            await (try #require(model.operation)).value
            let result = try #require(model.result)
            #expect(!model.busy && model.sheet == nil && result.status == status)
            #expect(result.items.map(\.resource) == [.repository("added"), .repository("remaining")])
            #expect(result.items.first?.effects.count == 1)
            #expect(result.items.last?.status == (status == "cancelled" ? "skipped" : "failed"))
            #expect(result.items.last?.reasonCode == (status == "cancelled" ? "not-processed" : nil))
            #expect(model.managementProgress != nil)
        }
    }

    @Test func editPreviewFailureDoesNotChangeTheWorkspace() async throws {
        try await withModel { model in
            let before = try #require(model.workspace)
            model.sheet = .edit
            model.edit("missing-group", members: [])
            await model.editPreviewTask?.value
            #expect(model.formError != nil && model.sheet == .edit)
            #expect(model.result == nil && model.pendingEdit == nil && !model.busy)
            #expect(model.workspace == before)
            #expect(try model.service.store.load(before.rootURL) == before)
        }
    }

    @Test(arguments: [ManagementSheet.create, .edit])
    func repositorySearchPreservesSortingAndSelection(_ sheet: ManagementSheet) throws {
        let suite = "ModuRepositorySearchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = "en"
        var workspace = WorkspaceRecord(root: "/workspace")
        workspace.repositories = [
            Repository(url: "https://example.invalid/api10.git", name: "Service 10"),
            Repository(url: "https://example.invalid/frontend.git", name: "baize-frontend"),
            Repository(url: "https://example.invalid/api2.git", name: "Service 2"),
            Repository(url: "https://example.invalid/mobile.git", name: "移动前端"),
            Repository(url: "https://example.invalid/server.git")
        ]
        model.workspace = workspace
        let selection: Set<String> = ["frontend", "server"]
        let all = model.sortedRepositories.map(\.id)
        for (query, expected) in [("", all), (" \n ", all), (" FRONT ", ["frontend"]),
                                  ("service", ["api2", "api10"]), ("前端", ["mobile"]),
                                  ("api10", []), ("unmatched", [])] {
            let view = ManagementView(model: model, sheet: sheet, selected: selection, repositorySearch: query)
            #expect(view.matchingRepositories.map(\.id) == expected)
            #expect(view.selectedMembers == ["frontend", "server"])
            #expect(view.selected == selection)
            #expect(model.workspace == workspace)
        }
    }

    @Test(arguments: [true, false])
    func toolChoiceUpdatesObservedDefaultOnlyAfterSuccessfulLaunch(_ succeeds: Bool) async throws {
        let root = TestEnvironment.temporaryDirectory.appending(path: "modu-tool-choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "worktrees/feature")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "tool.Agent")
        defaults.set("vscode", forKey: "tool.Editor")
        var launches: [URL] = []
        let toolService = ExternalTools(applicationURL: { _ in root.appending(path: "Claude.app") }, openURL: { url, _ in
            launches.append(url)
            if !succeeds { throw ModuError("tool-launch-failed", "Could not open the desktop app.") }
        })
        let model = AppModel(defaults: defaults, toolService: toolService)
        var workspace = WorkspaceRecord(root: root.path)
        workspace.groups["feature"] = WorktreeGroup()
        model.workspace = workspace
        model.selection = .group("feature")
        model.tools = ExternalTool.builtIn
        let claude = try #require(model.tools.first { $0.id == "claude" })
        #expect(model.preferredToolIDs["Agent"] == "codex")
        withObservationTracking {
            _ = model.preferredToolIDs["Agent"]
        } onChange: {
            UserDefaults(suiteName: suite)?.set(true, forKey: "toolPreferenceChanged")
        }

        model.openTool(claude)
        #expect(model.preferredToolIDs["Agent"] == "codex")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.preferredToolIDs["Agent"] == "codex", model.message == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = succeeds ? "claude" : "codex"
        #expect(model.preferredToolIDs["Agent"] == expected)
        #expect(defaults.string(forKey: "tool.Agent") == expected)
        #expect(defaults.bool(forKey: "toolPreferenceChanged") == succeeds)
        #expect(model.preferredToolIDs["Editor"] == "vscode")
        #expect(model.selection == .group("feature"))
        #expect(launches.count == 1)
        #expect((model.message == nil) == succeeds)
        let reopened = AppModel(defaults: defaults, toolService: toolService)
        #expect(reopened.preferredToolIDs["Agent"] == expected)
    }

    @Test func unknownDeletionStatusDoesNotUseSidebarOrRiskText() throws {
        let suite = "ModuUnknownDeletionStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        for resource in [Resource.repository("repo"), .group("feature"), .member("feature", "repo")] {
            model.states[resource.id] = ResourceState(resource: resource, available: true, dirty: false)
            let target = DeletionTarget(resource: resource, path: "/workspace/\(resource.path)", branch: nil,
                                        detached: false, registered: true, exists: true, risks: ["Working tree is clean."])
            #expect(ManagementView(model: model, sheet: .delete).deletionStatus(target) == "Other")
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
                model.quitPending = quitting; model.resultHost = .settings
                model.run { _, root, _ in
                    var item = ItemResult(.repository("repo"), status: status)
                    if effects { item.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)] }
                    return OperationResult(command: "workspace.import", workspace: root.path, status: status, items: [item])
                }
                #expect(model.busy && model.resultHost == .settings)
                let operation = try #require(model.operation)
                await operation.value
                #expect(!model.busy)
                #expect((model.result != nil) == presentsResult)
                #expect(model.resultHost == (presentsResult ? .settings : .main))
                #expect(model.completionMessage == nil)
                model.quitPending = false
                model.dismissResult()
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
                model.run { _, root, _ in
                    let items = dispositions.enumerated().map { index, disposition in
                        let resource = Resource.repository("repo-\(index)")
                        if disposition == "not-processed" { return ItemResult.notProcessed(resource) }
                        if ["failed", "cancelled"].contains(disposition) { return ItemResult(resource, status: disposition) }
                        var item = ItemResult(resource)
                        item.data = ["disposition": disposition]
                        return item
                    }
                    return OperationResult(command: "repo.update", workspace: root.path, status: status, items: items)
                }
                await (try #require(model.operation)).value
                let visible = dispositions.indices.filter { ["updated", "failed"].contains(dispositions[$0]) }
                #expect(!model.busy && model.progress == nil && model.completionMessage == nil)
                #expect((model.result != nil) == !visible.isEmpty)
                if let result = model.result {
                    #expect(result.items.count == dispositions.count)
                    #expect(model.resultDisplayItems(result).map(\.resource) == visible.map { .repository("repo-\($0)") })
                }
                model.dismissResult()
            }
        }
    }

    @Test func changeTreeSortsDirectoriesFirstAndCollapsesOnlyDescendants() {
        let changes = [
            FileChange(path: "src/file10.swift", index: "A", workingTree: " "),
            FileChange(path: "src/file2.swift", index: "M", workingTree: "M"),
            FileChange(path: "src/a.swift", index: "M", workingTree: " "),
            FileChange(path: "src/hooks/file.swift", index: " ", workingTree: "M"),
            FileChange(path: "README.md", index: " ", workingTree: "D")
        ]
        let tree = ChangeNode.tree(changes)
        let expanded = tree.flatMap { $0.visibleRows(collapsed: []) }
        #expect(expanded.map(\.id) == ["src", "src/hooks", "src/hooks/file.swift", "src/a.swift", "src/file2.swift", "src/file10.swift", "README.md"])
        #expect(expanded.map(\.depth) == [0, 1, 2, 1, 1, 1, 0])
        #expect(expanded[4].node.change?.workingTree == "M")
        #expect(tree.flatMap { $0.visibleRows(collapsed: ["src"]) }.map(\.id) == ["src", "README.md"])
        #expect(tree.flatMap { $0.visibleRows(collapsed: ["src/hooks"]) }.map(\.id) == ["src", "src/hooks", "src/a.swift", "src/file2.swift", "src/file10.swift", "README.md"])
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
        model.workspace = record
        // Result handling needs no saved launch preference or Git reload; real operations are tested separately.
        try await body(model)
    }
}

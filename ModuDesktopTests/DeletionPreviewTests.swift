import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct DeletionPreviewTests {
    @Test(arguments: ["success", "partial-success", "cancelled"])
    func deletionUpdatesSidebarOnlyAfterOperationEnds(_ status: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        #expect(await fixture.service.createGroup("other", repositories: ["repo"], at: fixture.root).status == "success")
        let record = try await fixture.service.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = record
        model.expandedGroups = ["feature", "other"]
        let member = Resource.member("feature", "repo")
        model.selection = member
        await model.reload()
        let visibleResources = model.visibleResources
        let targets = try await fixture.service.previewDelete(.group("feature"), at: fixture.root)
        let release = fixture.directory.appending(path: "continue-group-deletion")
        model.sheet = .delete
        model.run { service, root, progress in
            var outcome = await service.remove(.member(group: "feature", repo: "repo"), at: root,
                                               authorization: targets.filter { $0.resource == member }, progress: progress)
            guard outcome.status == "success" else { return outcome }
            // Hold between actual member and root deletion to inspect the visible inventory.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(release), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if status == "success" {
                let remaining = await service.remove(.group("feature"), at: root,
                                                     authorization: targets.filter { $0.resource.kind == "group" }, progress: progress)
                outcome.items += remaining.items
            } else {
                let cancelled = status == "cancelled"
                outcome.items.append(.init(.group("feature"), status: cancelled ? "skipped" : "failed",
                                           error: .init(cancelled ? "not-processed" : "test-failure", "Stopped before root deletion.")))
            }
            outcome.summarize(cancelled: status == "cancelled")
            return outcome
        }
        let operation = try #require(model.operation)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.progress?.snapshot?.groups["feature"]?.repositories.isEmpty != true, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(model.progress?.snapshot?.groups["feature"]?.repositories == [])
            #expect(model.busy && model.sheet == .delete && model.managementProgress?.progress?.phase == "Deleted")
            #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositories == [])
            #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
            #expect(model.workspace == record && model.visibleResources == visibleResources)
            #expect(model.selection == member && model.expandedGroups == ["feature", "other"])
            try Data().write(to: release)
            await operation.value
            await model.detailPreloadTask?.value
            #expect(!model.busy && model.sheet == nil && model.selection == nil)
            #expect(model.workspace == (try fixture.service.store.load(fixture.root)))
            #expect(!model.visibleResources.contains(member) && model.workspace?.groups["other"] != nil)
            if status == "success" {
                #expect(model.result == nil && model.workspace?.groups["feature"] == nil)
                #expect(!model.visibleResources.contains(.group("feature")))
            } else {
                #expect(model.result?.status == status && model.workspace?.groups["feature"]?.repositories == [])
                #expect(model.visibleResources.contains(.group("feature")) && PathSafety.exists(record.groupURL("feature")))
            }
        } catch {
            try? Data().write(to: release)
            await operation.value
            await model.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [Resource.group("feature"), Resource.member("feature", "repo")])
    func deletingSelectedGroupReturnsToWorkspace(_ selected: Resource) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        #expect(await fixture.service.createGroup("other", repositories: ["repo"], at: fixture.root).status == "success")
        let record = try await fixture.service.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = record
        model.expandedGroups = ["feature", "other"]
        model.selection = selected
        await model.reload()
        #expect(model.selection == selected && model.detail.summary?.head == "feature")
        model.prepareDelete(.group("feature"))
        await model.deletePreviewTask?.value
        try #require(model.canConfirmDelete)
        model.confirmDelete()
        let operation = try #require(model.operation)
        await operation.value
        await model.detailPreloadTask?.value
        #expect(!model.busy && model.result == nil && model.sheet == nil)
        #expect(model.workspace?.groups["feature"] == nil && model.workspace?.groups["other"] != nil)
        #expect(!model.visibleResources.isEmpty && model.selection == nil)
        #expect(model.currentURL == record.rootURL && !model.detailLoading)
        #expect(model.detail.summary == nil && model.detail.changes == nil && model.detail.commits == nil)
        #expect(model.detail.summaryError == nil && model.detail.changesError == nil && model.detail.commitsError == nil)
    }

    @Test(arguments: ["complete", "cancel", "replace", "reopen", "workspace"])
    func deletionOpensBeforePreflightAndDiscardsObsoleteResults(_ action: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try await fixture.service.load(fixture.root)
        let probe = fixture.directory.appending(path: "delete-preview-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_DELETE_PREVIEW_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_DELETE_PREVIEW_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: record.repositoryURL("repo"))
        }
        var runner = fixture.service.git.runner
        runner.environment["MODU_DELETE_PREVIEW_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: service)
        model.workspace = record
        let member = Resource.member("feature", "repo")
        try Data("changed".utf8).write(to: record.memberURL("feature", "repo").appending(path: "README"))
        model.states[member.id] = .init(resource: member, available: true, dirty: false)
        model.prepareDelete(.group("feature"))
        let preview = try #require(model.deletePreviewTask)
        #expect(model.sheet == .delete && model.deletionLoading && model.deletion.isEmpty)
        #expect(model.deletionResources == [member, .group("feature")])
        #expect(ManagementView(model: model, sheet: .delete).deletionDisplayResources == [.group("feature"), member])
        #expect(!model.canConfirmDelete)
        model.confirmDelete()
        #expect(!model.busy && model.operation == nil)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            switch action {
            case "cancel": model.sheet = nil
            case "replace": model.prepareDelete(.member(group: "feature", repo: "repo"))
            case "reopen": model.sheet = nil; model.prepareDelete(.member(group: "feature", repo: "repo"))
            case "workspace": model.workspace = nil
            default: break
            }
            if action == "replace" || action == "reopen" {
                #expect(model.deletionResources == [member] && model.deletion.isEmpty && model.deletionLoading)
            }
            try Data().write(to: probe.appending(path: "release"))
            await preview.value
            await model.deletePreviewTask?.value
            #expect(!model.deletionLoading && model.formError == nil && model.message == nil)
            if action == "cancel" || action == "workspace" {
                #expect(model.sheet == nil && model.deletion.isEmpty && !model.canConfirmDelete)
                let lease = try service.store.lock(fixture.root); lease.unlock()
            } else {
                #expect(model.sheet == .delete && model.canConfirmDelete)
                let expected: [Resource] = action == "replace" || action == "reopen" ? [.member("feature", "repo")] : [.member("feature", "repo"), .group("feature")]
                #expect(model.deletion.map(\.resource) == expected)
                #expect(model.deletion.allSatisfy { $0.branch == "feature" })
                let target = try #require(model.deletion.first { $0.resource == member })
                #expect(ManagementView(model: model, sheet: .delete).deletionStatus(target) == "Dirty")
            }
            #expect(PathSafety.exists(record.groupURL("feature")))
            #expect(PathSafety.exists(record.memberURL("feature", "repo")))
        } catch {
            model.sheet = nil
            try? Data().write(to: probe.appending(path: "release"))
            await preview.value
            await model.deletePreviewTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func failedPreflightStaysInSheetAndCannotDelete(_ locked: Bool) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        if locked { try await prepare(fixture) }
        else { #expect(await fixture.service.openWorkspace(fixture.root).status == "success") }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        if locked {
            _ = try await fixture.service.git.run(["worktree", "lock", fixture.root.appending(path: "worktrees/feature/repo").path], at: fixture.root.appending(path: "repositories/repo"))
        }
        model.prepareDelete(.group(locked ? "feature" : "missing"))
        #expect(model.sheet == .delete && model.deletionLoading)
        await model.deletePreviewTask?.value
        #expect(model.sheet == .delete && !model.deletionLoading && model.formError != nil)
        #expect(model.deletion.isEmpty && !model.canConfirmDelete && model.message == nil)
        let paths: [Resource] = locked ? [.group("feature"), .member("feature", "repo")] : []
        #expect(ManagementView(model: model, sheet: .delete).deletionDisplayResources == paths)
        model.confirmDelete()
        #expect(!model.busy && model.operation == nil)
    }

    @Test(arguments: ["repository", "group", "member"])
    func editingMembersDiscardsACancelledDeletionRequest(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try await fixture.service.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = record
        let request: DeleteRequest = kind == "repository" ? .repository("repo") : kind == "group" ? .group("feature") : .member(group: "feature", repo: "repo")
        model.prepareDelete(request)
        await model.deletePreviewTask?.value
        try #require(model.canConfirmDelete)
        model.sheet = nil
        model.sheet = .edit
        model.edit("feature", members: [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.sheet == .edit, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.sheet == .delete && model.canConfirmDelete)
        #expect(model.deleteRequest == nil)
        #expect(model.pendingEdit?.0 == "feature" && model.pendingEdit?.1 == [])
        #expect(model.deletionResources == [.member("feature", "repo")])
        model.confirmDelete()
        await model.operation?.value
        #expect(model.result == nil && !model.busy)
        #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositories == [])
        #expect(PathSafety.exists(record.groupURL("feature")) && PathSafety.exists(record.repositoryURL("repo")))
        #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
    }

    @Test(arguments: ["group", "member", "repository", "edit"])
    func confirmedDeletionDoesNotScanRisksAgain(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let request: DeleteRequest = kind == "repository" ? .repository("repo") : kind == "member" ? .member(group: "feature", repo: "repo") : .group("feature")
        let trace = fixture.directory.appending(path: "confirmed-delete-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner), trash: fixture.service.trashDirectory)
        let targets: [DeletionTarget]
        if kind == "edit" { targets = try #require(await service.editGroupPreview("feature", repositories: [], at: fixture.root).plan) }
        else { targets = try await service.previewDelete(request, at: fixture.root) }
        let previewCommands = try String(contentsOf: trace, encoding: .utf8)
        #expect(previewCommands.contains("git status ") && previewCommands.contains("git ls-files ") && previewCommands.contains("git rev-list "))
        try Data().write(to: trace)
        let result: OperationResult
        if kind == "edit" { result = await service.editGroup("feature", repositories: [], at: fixture.root, authorization: targets) }
        else { result = await service.remove(request, at: fixture.root, authorization: targets) }
        #expect(result.status == "success", "\(result.message ?? "") \(result.items)")
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(!commands.contains("git status ") && !commands.contains("git ls-files ") && !commands.contains("git rev-list "))
        #expect(commands.contains("git worktree remove ") && commands.contains("git branch -D "))
        let record = try fixture.service.store.load(fixture.root)
        #expect(record.groups["feature"]?.repositories.isEmpty != false)
    }

    @Test(arguments: ["branch", "lock", "nested"])
    func changedDeletionSafetyStopsBeforeAnyEffects(_ change: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try await fixture.service.load(fixture.root)
        let targets = try await fixture.service.previewDelete(.group("feature"), at: fixture.root)
        let member = record.memberURL("feature", "repo")
        let reason: String
        switch change {
        case "branch":
            _ = try await fixture.service.git.run(["switch", "-c", "changed"], at: member)
            reason = "confirmation-changed"
        case "lock":
            _ = try await fixture.service.git.run(["worktree", "lock", member.path], at: record.repositoryURL("repo"))
            reason = "worktree-locked"
        default:
            let nested = record.groupURL("feature").appending(path: "unmanaged")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            _ = try await fixture.service.git.run(["init"], at: nested)
            reason = "unmanaged-worktree"
        }
        let result = await fixture.service.remove(.group("feature"), at: fixture.root, authorization: targets)
        #expect(result.reasonCode == reason && result.items.allSatisfy { $0.effects.isEmpty })
        #expect(PathSafety.exists(member) && PathSafety.exists(record.groupURL("feature")))
        #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositories == ["repo"])
    }

    private func prepare(_ fixture: Fixture) async throws {
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
    }
}

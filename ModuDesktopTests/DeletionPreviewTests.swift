import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct DeletionPreviewTests {
    @Test func repositoryStatusUsesCurrentPreflightInsteadOfSidebarCache() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture, group: false)
        let record = try fixture.service.store.load(fixture.root)
        let repository = Resource.repository("repo")
        let path = record.repositoryURL("repo")
        for state in ["clean", "unstaged", "staged", "untracked"] {
            if state == "untracked" { _ = try await fixture.service.git.run(["reset", "--hard", "HEAD"], at: path) }
            if state != "clean" {
                let name = state == "untracked" ? "notes.txt" : "README"
                try Data("Changed outside Modu.\n".utf8).write(to: path.appending(path: name))
                if state == "staged" { _ = try await fixture.service.git.run(["add", "--", name], at: path) }
            }
            let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
            defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
            let model = AppModel(defaults: defaults, service: fixture.service)
            model.workspace.record = record
            model.workspace.states[repository.id] = ResourceState(resource: repository, available: true, dirty: state == "clean")
            model.management.prepareDelete(.repository("repo"))
            await model.management.deletePreviewTask?.value
            let target = try #require(model.management.deletion.first { $0.resource == repository })
            #expect(model.management.canConfirmDelete && model.management.formError == nil)
            #expect(target.dirty == (state != "clean"))
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(PathSafety.exists(path))
        }
    }

    @Test func unreadableRepositoryStatusBlocksDeletionAndPreservesResources() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try fixture.service.store.load(fixture.root)
        let repository = Resource.repository("repo")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        model.workspace.states[repository.id] = ResourceState(resource: repository, available: true, dirty: false)
        try Data("invalid index".utf8).write(to: record.repositoryURL("repo").appending(path: ".git/index"))
        model.management.prepareDelete(.repository("repo"))
        await model.management.deletePreviewTask?.value
        #expect(model.management.formError != nil)
        #expect(model.management.deletion.isEmpty && !model.management.deletionLoading && !model.management.canConfirmDelete)
        #expect(model.management.deletionResources.contains(repository))
        model.management.confirmDelete()
        #expect(model.operation == nil && !model.busy)
        #expect(try fixture.service.store.load(fixture.root) == record)
        #expect(PathSafety.exists(record.repositoryURL("repo")) && PathSafety.exists(record.memberURL("feature", "repo")))
    }

    @Test func editPreflightDiscardsCancelledRequestsWithoutHoldingTheWorkspaceLock() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        #expect(await fixture.service.createGroup("other", repositories: ["repo"], at: fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        for action in ["complete", "cancel", "reopen", "replace", "workspace", "selection", "delete", "operation"] {
            for name in ["edit-preflight-started", "edit-preflight-release"] {
                try? FileManager.default.removeItem(at: fixture.directory.appending(path: name))
            }
            let started = fixture.directory.appending(path: "edit-preflight-started")
            let release = fixture.directory.appending(path: "edit-preflight-release")
            let monitor = fixture.directory.appending(path: "edit-fsmonitor")
            try Data("""
            #!/bin/sh
            : > "\(started.path)"
            trap 'exit 143' TERM INT
            while [ ! -e "\(release.path)" ]; do sleep 0.02; done
            printf 'test-token\\000/\\000'
            """.utf8).write(to: monitor)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
            for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
                _ = try await fixture.service.git.run(arguments, at: record.repositoryURL("repo"))
            }
            let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
            defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
            let model = AppModel(defaults: defaults, service: fixture.service)
            defer { model.management.sheet = nil; model.workspace.record = nil; model.workspace.selection = nil }
            model.workspace.record = record; model.management.sheet = .edit
            model.management.edit("feature", members: [])
            let preview = try #require(model.management.editPreviewTask)
            defer { preview.cancel(); try? Data().write(to: release) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(PathSafety.exists(started))
            let lease = try fixture.service.store.tryLock(fixture.root); lease.unlock()
            switch action {
            case "cancel": model.management.sheet = nil
            case "reopen": model.management.sheet = nil; model.management.sheet = .edit
            case "replace": model.management.edit("other", members: [])
            case "workspace": model.workspace.record = nil
            case "selection": model.workspace.selection = .group("other")
            case "delete": model.management.prepareDelete(.member(group: "other", repo: "repo"))
            case "operation":
                model.management.run { service, root, _ in
                    do { _ = try await service.load(root); return .init(command: "workspace.inspect", workspace: root.path) }
                    catch { return .init(command: "workspace.inspect", workspace: root.path, status: .failed, error: .wrap(error)) }
                }
            default: break
            }
            if action != "complete" { #expect(preview.isCancelled) }
            try Data().write(to: release)
            await preview.value
            await model.management.editPreviewTask?.value
            await model.management.deletePreviewTask?.value
            await model.operation?.value
            #expect(model.management.formError == nil && model.presentation.result == nil && !model.busy)
            switch action {
            case "complete", "replace":
                let group = action == "complete" ? "feature" : "other"
                #expect(model.management.sheet == .delete && model.management.pendingEdit?.0 == group && model.management.pendingEdit?.1 == [])
                #expect(model.management.deletion.map(\.resource) == [.member(group, "repo")])
            case "delete":
                #expect(model.management.sheet == .delete && model.management.pendingEdit == nil)
                #expect(model.management.deletion.map(\.resource) == [.member("other", "repo")])
            default:
                #expect(model.management.sheet == (action == "cancel" || action == "operation" ? nil : .edit))
                #expect(model.management.pendingEdit == nil && model.management.deletion.isEmpty)
            }
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(PathSafety.exists(record.memberURL("feature", "repo")) && PathSafety.exists(record.memberURL("other", "repo")))
            let preload = model.workspace.detailPreloadTask
            model.workspace.record = nil; model.workspace.selection = nil
            await preload?.value
        }
    }

    @Test func reopeningEditDoesNotSubmitCancelledAdditions() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        #expect(await fixture.service.remove(.member(group: "feature", repo: "repo"), at: fixture.root, execute: true).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record; model.management.sheet = .edit
        model.management.edit("feature", members: ["repo"])
        let preview = try #require(model.management.editPreviewTask)
        model.management.sheet = nil; model.management.sheet = .edit
        await preview.value
        #expect(preview.isCancelled && model.management.sheet == .edit)
        #expect(model.operation == nil && model.management.pendingEdit == nil && model.presentation.result == nil && model.management.formError == nil)
        #expect(try fixture.service.store.load(fixture.root) == record)
        #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
    }

    @Test(arguments: ["success", "partial-success", "cancelled"])
    func deletionUpdatesSidebarOnlyAfterOperationEnds(_ status: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        try await fixture.prepareEmptyGroup("other")
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        model.workspace.expandedGroups = ["feature", "other"]
        let member = Resource.member("feature", "repo")
        let selected = status == "success" ? Resource.group("feature") : member
        model.workspace.selection = selected
        let visibleResources = model.workspace.visibleResources
        let targets = try await fixture.service.previewDelete(.group("feature"), at: fixture.root)
        let release = fixture.directory.appending(path: "continue-group-deletion")
        model.management.sheet = .delete
        model.management.run { service, root, progress in
            var outcome = await service.remove(.member(group: "feature", repo: "repo"), at: root,
                                               authorization: targets.filter { $0.resource == member }, progress: progress)
            guard outcome.status == .success else { return outcome }
            // Hold between actual member and root deletion to inspect the visible inventory.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(release), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if status == "success" {
                let remaining = await service.remove(.group("feature"), at: root,
                                                     authorization: targets.filter { $0.resource.kind == .group }, progress: progress)
                outcome.items += remaining.items
            } else {
                let cancelled = status == "cancelled"
                outcome.items.append(.init(.group("feature"), status: cancelled ? .skipped : .failed,
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
            #expect(model.busy && model.management.sheet == .delete && model.management.progressPresentation?.progress?.phase == .deleted)
            #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositories == [])
            #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
            #expect(model.workspace.record == record && model.workspace.visibleResources == visibleResources)
            #expect(model.workspace.selection == selected && model.workspace.expandedGroups == ["feature", "other"])
            try Data().write(to: release)
            await operation.value
            await model.workspace.detailPreloadTask?.value
            #expect(!model.busy && model.management.sheet == nil && model.workspace.selection == nil)
            #expect(model.workspace.currentURL == record.rootURL && !model.workspace.detailLoading)
            #expect(model.workspace.detail.summary == nil && model.workspace.detail.changes == nil && model.workspace.detail.commits == nil)
            #expect(model.workspace.record == (try fixture.service.store.load(fixture.root)))
            #expect(!model.workspace.visibleResources.contains(member) && model.workspace.record?.groups["other"] != nil)
            if status == "success" {
                #expect(model.presentation.result == nil && model.workspace.record?.groups["feature"] == nil)
                #expect(!model.workspace.visibleResources.contains(.group("feature")))
            } else {
                #expect(model.presentation.result?.status.rawValue == status && model.workspace.record?.groups["feature"]?.repositories == [])
                #expect(model.workspace.visibleResources.contains(.group("feature")) && PathSafety.exists(record.groupURL("feature")))
            }
        } catch {
            try? Data().write(to: release)
            await operation.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test func deletionOpensBeforePreflightAndDiscardsObsoleteResults() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try fixture.service.store.load(fixture.root)
        for action in ["complete", "cancel", "replace", "reopen", "workspace"] {
            try? FileManager.default.removeItem(at: fixture.directory.appending(path: "delete-preview-probe"))
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
            model.workspace.record = record
            let member = Resource.member("feature", "repo")
            try Data("changed".utf8).write(to: record.memberURL("feature", "repo").appending(path: "README"))
            model.workspace.states[member.id] = .init(resource: member, available: true, dirty: false)
            model.management.prepareDelete(.group("feature"))
            let preview = try #require(model.management.deletePreviewTask)
            #expect(model.management.sheet == .delete && model.management.deletionLoading && model.management.deletion.isEmpty)
            #expect(model.management.deletionResources == [member, .group("feature")])
            #expect(ManagementView(management: model.management, workspace: model.workspace, operations: model.operations, presentation: model.presentation, sheet: .delete).deletionDisplayResources == [.group("feature"), member])
            #expect(!model.management.canConfirmDelete)
            model.management.confirmDelete()
            #expect(!model.busy && model.operation == nil)
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(PathSafety.exists(probe.appending(path: "started")))
                let lease = try service.store.tryLock(fixture.root); lease.unlock()
                switch action {
                case "cancel": model.management.sheet = nil
                case "replace": model.management.prepareDelete(.member(group: "feature", repo: "repo"))
                case "reopen": model.management.sheet = nil; model.management.prepareDelete(.member(group: "feature", repo: "repo"))
                case "workspace": model.workspace.record = nil
                default: break
                }
                if action == "replace" || action == "reopen" {
                    #expect(model.management.deletionResources == [member] && model.management.deletion.isEmpty && model.management.deletionLoading)
                }
                try Data().write(to: probe.appending(path: "release"))
                await preview.value
                await model.management.deletePreviewTask?.value
                #expect(!model.management.deletionLoading && model.management.formError == nil && model.presentation.message == nil)
                if action == "cancel" || action == "workspace" {
                    #expect(model.management.sheet == nil && model.management.deletion.isEmpty && !model.management.canConfirmDelete)
                } else {
                    #expect(model.management.sheet == .delete && model.management.canConfirmDelete)
                    let expected: [Resource] = action == "replace" || action == "reopen" ? [.member("feature", "repo")] : [.member("feature", "repo"), .group("feature")]
                    #expect(model.management.deletion.map(\.resource) == expected)
                    #expect(model.management.deletion.allSatisfy { $0.branch == "feature" })
                    let target = try #require(model.management.deletion.first { $0.resource == member })
                    #expect(ManagementView(management: model.management, workspace: model.workspace, operations: model.operations, presentation: model.presentation, sheet: .delete).deletionStatus(target) == "Dirty")
                }
                #expect(PathSafety.exists(record.groupURL("feature")))
                #expect(PathSafety.exists(record.memberURL("feature", "repo")))
            } catch {
                model.management.sheet = nil
                try? Data().write(to: probe.appending(path: "release"))
                await preview.value
                await model.management.deletePreviewTask?.value
                throw error
            }
        }
    }

    @Test(arguments: [false, true])
    func failedPreflightStaysInSheetAndCannotDelete(_ locked: Bool) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        if locked { try await prepare(fixture) }
        else { #expect(await fixture.service.openWorkspace(fixture.root).status == .success) }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        if locked {
            _ = try await fixture.service.git.run(["worktree", "lock", fixture.root.appending(path: "worktrees/feature/repo").path], at: fixture.root.appending(path: "repositories/repo"))
        }
        model.management.prepareDelete(.group(locked ? "feature" : "missing"))
        #expect(model.management.sheet == .delete && model.management.deletionLoading)
        await model.management.deletePreviewTask?.value
        #expect(model.management.sheet == .delete && !model.management.deletionLoading && model.management.formError != nil)
        #expect(model.management.deletion.isEmpty && !model.management.canConfirmDelete && model.presentation.message == nil)
        let paths: [Resource] = locked ? [.group("feature"), .member("feature", "repo")] : []
        #expect(ManagementView(management: model.management, workspace: model.workspace, operations: model.operations, presentation: model.presentation, sheet: .delete).deletionDisplayResources == paths)
        model.management.confirmDelete()
        #expect(!model.busy && model.operation == nil)
    }

    @Test func editingMembersDiscardsACancelledDeletionRequest() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        let request = DeleteRequest.repository("repo")
        model.management.prepareDelete(request)
        await model.management.deletePreviewTask?.value
        try #require(model.management.canConfirmDelete)
        model.management.sheet = nil
        model.management.sheet = .edit
        model.management.edit("feature", members: [])
        await model.management.editPreviewTask?.value
        try #require(model.management.sheet == .delete && model.management.canConfirmDelete)
        #expect(model.management.deleteRequest == nil)
        #expect(model.management.pendingEdit?.0 == "feature" && model.management.pendingEdit?.1 == [])
        #expect(model.management.deletionResources == [.member("feature", "repo")])
        model.management.confirmDelete()
        await model.operation?.value
        #expect(model.presentation.result == nil && !model.busy)
        #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositories == [])
        #expect(PathSafety.exists(record.groupURL("feature")) && PathSafety.exists(record.repositoryURL("repo")))
        #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
    }

    @Test func changedDeletionSafetyStopsBeforeAnyEffects() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try await prepare(fixture)
        let record = try fixture.service.store.load(fixture.root)
        let targets = try await fixture.service.previewDelete(.group("feature"), at: fixture.root)
        let member = record.memberURL("feature", "repo")
        for change in ["branch", "lock", "nested"] {
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
            switch change {
            case "branch":
                _ = try await fixture.service.git.run(["switch", "feature"], at: member)
                _ = try await fixture.service.git.run(["branch", "-D", "changed"], at: member)
            case "lock": _ = try await fixture.service.git.run(["worktree", "unlock", member.path], at: record.repositoryURL("repo"))
            default: try FileManager.default.removeItem(at: record.groupURL("feature").appending(path: "unmanaged"))
            }
        }
    }

    private func prepare(_ fixture: Fixture, group: Bool = true) async throws {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        if group { #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success) }
    }
}

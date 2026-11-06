import AppKit
import Foundation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct WorkspaceActionTests {
    @Test(arguments: ["pending", "maintaining", "failed", "busy", "cancelling"])
    func managementRefusalsDoNotBlockExternalTools(_ state: String) async throws {
        try await withModel { model, fixture in
            let before = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
            var launched: [URL] = []
            let tool = try #require(ExternalTool.builtIn.first { $0.id == "terminal" })
            let tools = ExternalTools(applicationURL: { _ in fixture.directory.appending(path: "Tool.app") },
                                      openURL: { path, _ in launched.append(path) })
            var operationID: Int?
            switch state {
            case "pending": model.workspace.maintenanceState = .pending
            case "maintaining": model.workspace.maintenanceState = .maintaining
            case "failed": model.workspace.maintenanceState = .failed
            default:
                operationID = model.operations.begin(.management)
                if state == "cancelling" { model.operations.cancel() }
            }
            defer { if let operationID { model.operations.finish(operationID) } }
            let issue = try #require(model.workspace.managementIssue)
            model.management.requestForm(.addRepository)
            #expect(model.presentation.message == model.text.message(issue))
            #expect(model.management.sheet == nil && model.management.openingFormTask == nil)
            let opened = try makeModel(fixture, tools: tools)
            defer { opened.defaults.removePersistentDomain(forName: opened.defaultsSuite) }
            opened.model.workspace.maintenanceState = model.workspace.maintenanceState
            let token = operationID == nil ? nil : opened.model.operations.begin(.management)
            if state == "cancelling" { opened.model.operations.cancel() }
            opened.model.openTool(tool)
            await opened.model.waitForPendingActions()
            #expect(launched.map(\.path) == [fixture.root.path] && opened.model.preferredToolIDs["Terminal"] == tool.id)
            if let token { opened.model.operations.finish(token) }
            await opened.model.workspace.stopReads()
            #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == before)
        }
    }

    @Test func entryRequestsCoalesceReplaceAndRecheckOperationOwnership() async throws {
        try await withModel { model, _ in
            model.management.requestForm(.addRepository)
            let first = model.management.openingFormTask
            model.management.requestForm(.createGroup)
            #expect(first?.isCancelled == true)
            await model.management.openingFormTask?.value
            #expect(model.management.sheet == .create)
            let formID = model.management.formSession?.id
            model.management.requestForm(.createGroup)
            model.management.requestForm(.addRepository)
            #expect(model.management.sheet == .create && model.management.formSession?.id == formID)

            model.management.sheet = nil
            model.management.finishDismissal()
            model.management.requestForm(.addRepository)
            let operation = try #require(model.operations.begin(.management))
            await model.management.openingFormTask?.value
            #expect(model.management.sheet == nil && model.operations.isCurrent(operation))
            #expect(model.presentation.message == model.text.message(WorkspaceActionIssue.busy))
            model.operations.finish(operation)
        }
    }

    @Test(arguments: ["empty", "record", "directory", "git"])
    func entryValidationIsReadOnlyAndReportsInvalidWorkspaces(_ failure: String) async throws {
        try await withModel { model, fixture in
            let record = try #require(model.workspace.record)
            switch failure {
            case "empty":
                var empty = record; empty.repositories = []
                try fixture.service.store.save(empty)
            case "record": try Data("invalid".utf8).write(to: fixture.service.store.recordURL(fixture.root))
            case "directory": try FileManager.default.removeItem(at: fixture.root)
            default: try FileManager.default.removeItem(at: fixture.root.appending(path: ".git"))
            }
            model.management.requestForm(.createGroup)
            await model.management.openingFormTask?.value
            #expect(model.management.sheet == nil && !model.busy && model.presentation.message != nil)
            #expect(model.workspace.record == record)
            if failure == "empty" {
                #expect(model.presentation.message == model.text.message(WorkspaceActionIssue.noRepositories))
            }
            if failure == "record" {
                #expect(try String(contentsOf: fixture.service.store.recordURL(fixture.root), encoding: .utf8) == "invalid")
            }
            if failure == "git" { #expect(!PathSafety.exists(fixture.root.appending(path: ".git"))) }
        }
    }

    @Test(arguments: ["switch-back", "removed", "replaced", "disk-only"])
    func submissionsKeepTheirWorkspaceAndFullMemberSelection(_ change: String) async throws {
        try await withModel { model, fixture in
            model.management.requestForm(.createGroup)
            await model.management.openingFormTask?.value
            try #require(model.management.sheet == .create)
            let original = try #require(model.workspace.record)
            let context = model.workspace.contextID
            var changed = original
            if change == "switch-back" {
                var other = original; other.root = fixture.directory.appending(path: "other").path
                model.workspace.record = other
                model.workspace.record = original
                #expect(model.workspace.contextID != context)
            } else {
                if change == "replaced" { changed.repositories = [.init(url: "https://example.invalid/other/repo.git")] }
                else { changed.repositories = [] }
                try fixture.service.store.save(changed)
                if change != "disk-only" { model.workspace.record = changed }
                #expect(model.workspace.contextID == context)
            }
            #expect(model.management.creationRepositories.map(\.id) == ["repo"])
            model.management.create("feature", members: ["repo"])
            await model.operation?.value
            let expectedMessage = change == "switch-back" ? model.text.message(WorkspaceActionIssue.workspaceChanged)
                : model.text.message(UserMessage.selectedRepositoriesChanged)
            #expect(model.management.formError == expectedMessage)
            #expect(model.management.sheet == .create && model.presentation.message == nil && model.presentation.result == nil)
            #expect(!model.busy && model.management.progressPresentation == nil)
            #expect(try fixture.service.store.load(fixture.root).groups["feature"] == nil)
            #expect(!PathSafety.exists(original.groupURL("feature")))
        }
    }

    @Test func submissionUsesTheValidatedRecordBeforeTheSidebarCatchesUp() async throws {
        try await withModel { model, fixture in
            let actual = try #require(model.workspace.record)
            var stale = actual; stale.repositories = []
            model.workspace.record = stale
            model.management.requestForm(.createGroup)
            await model.management.openingFormTask?.value
            #expect(model.workspace.sortedRepositories.isEmpty)
            #expect(model.management.creationRepositories.map(\.id) == ["repo"])
            model.management.create("feature", members: ["repo"])
            await model.operation?.value
            #expect(model.management.formError == nil && model.management.sheet == nil)
            #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositoryIDs == ["repo"])
        }
    }

    @Test(arguments: ["missing", "file", "unreadable", "unsearchable", "symlink", "git", "uninstalled", "launch"])
    func externalToolFailuresAreReportedWithoutStartingManagement(_ failure: String) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        let target = fixture.root.appending(path: "repositories/target")
        var launches = 0
        let tools = ExternalTools(git: fixture.service.git,
            applicationURL: { _ in failure == "uninstalled" ? nil : fixture.directory.appending(path: "Tool.app") },
            openURL: { _, _ in launches += 1; throw MonoDeckError("launch-failed", "Test launch failure") })
        let value = try makeModel(fixture, tools: tools)
        let model = value.model
        defer { value.defaults.removePersistentDomain(forName: value.defaultsSuite) }
        do {
            switch failure {
            case "missing": break
            case "file": try Data().write(to: target)
            case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.directory.appending(path: "source"))
            default: try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            let changesPermissions = failure == "unreadable" || failure == "unsearchable"
            if changesPermissions { try FileManager.default.setAttributes([.posixPermissions: failure == "unreadable" ? 0o000 : 0o400], ofItemAtPath: target.path) }
            defer { if changesPermissions { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) } }
            model.workspace.selection = .repository("target")
            let tool = try #require(ExternalTool.builtIn.first { $0.id == (failure == "git" ? "fork" : "terminal") })
            model.openTool(tool)
            await model.waitForPendingActions()
            #expect(model.presentation.message != nil && model.presentation.messageHost == .main)
            #expect(model.presentation.messageTitle == model.text.string(.uiCanTOpen(tool.name)))
            #expect(launches == (failure == "launch" ? 1 : 0))
            #expect(!model.busy && !model.hasPendingActions && model.preferredToolIDs.isEmpty)
            await model.workspace.stopReads()
        } catch { await model.workspace.stopReads(); throw error }
    }

    @Test(arguments: [false, true])
    func groupCreationChecksExpectedMembersAfterAcquiringTheLock(_ dryRun: Bool) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let gate = ActionGate()
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { await gate.wait() })
        let service = WorkspaceService(store: store, git: fixture.service.git)
        let original = try store.load(fixture.root)
        let lease = try store.tryLock(fixture.root)
        defer { lease.unlock(); gate.release() }
        let creation = Task {
            await service.createGroup("feature", repositoryIDs: ["repo"], at: fixture.root,
                                      expectedRepositories: original.repositories, dryRun: dryRun)
        }
        do {
            if !dryRun { try await gate.waitUntilStarted() }
            var changed = original
            changed.repositories = [.init(url: "https://example.invalid/replaced/repo.git")]
            try store.save(changed)
            lease.unlock(); gate.release()
            let result = await creation.value
            #expect(result.status == .failed && result.reasonCode == "repository-selection-changed")
            #expect(result.dryRun == dryRun && result.items.allSatisfy { $0.effects.isEmpty })
            #expect(try store.load(fixture.root) == changed)
            #expect(!PathSafety.exists(original.groupURL("feature")))
        } catch {
            creation.cancel(); lease.unlock(); gate.release()
            _ = await creation.value
            throw error
        }
    }

    @Test func toolLaunchesCoalesceAndKeepTheClickedTarget() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let gate = ActionGate()
        var targets: [URL] = []
        let tools = ExternalTools(applicationURL: { _ in fixture.directory.appending(path: "Tool.app") },
                                  openURL: { path, _ in targets.append(path); await gate.wait() })
        let value = try makeModel(fixture, tools: tools); let model = value.model
        defer { gate.release(); value.defaults.removePersistentDomain(forName: value.defaultsSuite) }
        let tool = try #require(ExternalTool.builtIn.first { $0.id == "terminal" })
        do {
            model.openTool(tool)
            model.openTool(tool)
            model.workspace.selection = .repository("repo")
            try await gate.waitUntilStarted()
            #expect(targets.map(\.path) == [fixture.root.path] && !model.busy && model.workspace.canManage)
            gate.release()
            await model.waitForPendingActions()
            #expect(!model.hasPendingActions && model.preferredToolIDs["Terminal"] == tool.id)
            model.openTool(tool)
            await model.waitForPendingActions()
            #expect(targets.map(\.path) == [fixture.root.path, fixture.root.appending(path: "repositories/repo").path])
            await model.workspace.stopReads()
        } catch {
            gate.release(); model.cancelPendingActions()
            await model.waitForPendingActions()
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test(arguments: ["existing-message", "form", "result", "switch"])
    func actionFailuresWaitWithoutOverwritingPresentation(_ blocker: String) async throws {
        try await withModel { model, _ in
            switch blocker {
            case "existing-message": model.presentation.presentMessage("Existing", title: "Existing")
            case "form", "switch": model.management.sheet = .add
            default: model.presentation.result = .init(command: "repo.update", workspace: model.workspace.record?.root)
            }
            let tool = try #require(ExternalTool.builtIn.first { $0.id == "codex" })
            // The injected adapter has no applications, matching an app uninstalled after discovery.
            model.openTool(tool)
            await model.waitForPendingActions()
            #expect(model.presentation.actionMessages.count == 1)
            #expect(model.presentation.message == (blocker == "existing-message" ? "Existing" : nil))
            if blocker == "switch" {
                var other = try #require(model.workspace.record); other.root += "-other"
                model.workspace.record = other
            }
            model.management.sheet = nil
            model.presentation.result = nil
            model.dismissMessage()
            model.presentActionFailureIfPossible()
            #expect(model.presentation.actionMessages.isEmpty)
            #expect((model.presentation.message != nil) == (blocker != "switch"))
            if blocker != "switch" {
                model.openTool(tool)
                await model.waitForPendingActions()
                #expect(model.presentation.actionMessages.isEmpty)
            }
        }
    }

    @Test(arguments: ["workspace", "quit"], [false, true])
    func toolTasksDrainWithoutPublishingIntoTheirSuccessor(_ ending: String, _ fails: Bool) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        let gate = ActionGate()
        let tools = ExternalTools(applicationURL: { _ in fixture.directory.appending(path: "Tool.app") },
                                  openURL: { _, _ in
                                      await gate.wait()
                                      if fails { throw MonoDeckError("launch-failed", "Old error") }
                                  })
        let value = try makeModel(fixture, tools: tools); let model = value.model
        defer { gate.release(); value.defaults.removePersistentDomain(forName: value.defaultsSuite) }
        let tool = try #require(ExternalTool.builtIn.first { $0.id == "terminal" })
        do {
            model.openTool(tool)
            try await gate.waitUntilStarted()
            if ending == "workspace" {
                let root = fixture.directory.appending(path: "next")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try #require(model.changeWorkspace(root))
                let switching = try #require(model.operation)
                await Task.yield()
                #expect(!PathSafety.exists(root.appending(path: ".git")))
                gate.release()
                await switching.value
                #expect(model.workspace.record?.root == PathSafety.canonical(root).path)
            } else {
                var requests = 0
                let delegate = AppDelegate(terminate: { _ in requests += 1 }); delegate.model = model
                #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
                let termination = try #require(delegate.terminationTask)
                #expect(model.presentation.quitPending && requests == 0)
                model.management.requestForm(.addRepository)
                #expect(model.presentation.message == model.text.message(WorkspaceActionIssue.quitting))
                #expect(model.management.sheet == nil)
                model.dismissMessage()
                gate.release()
                await termination.value
                #expect(requests == 1 && delegate.terminationTask == nil)
            }
            #expect(!model.hasPendingActions && model.preferredToolIDs.isEmpty)
            #expect(model.presentation.message == nil && model.presentation.actionMessages.isEmpty)
            await model.workspace.stopReads()
        } catch {
            gate.release(); model.cancelPendingActions()
            await model.waitForPendingActions()
            await model.workspace.stopReads()
            throw error
        }
    }

    private func withModel(_ body: (AppModel, Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let value = try makeModel(fixture)
        defer { value.defaults.removePersistentDomain(forName: value.defaultsSuite) }
        do { try await body(value.model, fixture); await value.model.workspace.stopReads() }
        catch { value.model.cancelPendingActions(); await value.model.waitForPendingActions(); await value.model.workspace.stopReads(); throw error }
    }

    private func makeModel(_ fixture: Fixture, tools: ExternalTools? = nil) throws -> (model: AppModel, defaults: UserDefaults, defaultsSuite: String) {
        let suite = "WorkspaceActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let tools = tools ?? ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools)
        model.workspace.setActive(false)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        return (model, defaults, suite)
    }
}

@MainActor private final class ActionGate {
    private var released = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(started)
    }

    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

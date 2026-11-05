import Foundation
import AppKit
import Darwin
import Testing
import SwiftUI
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct WorkspaceLoadingTests {
    @Test(arguments: [false, true])
    func cancelledManagementRefreshesCompletedRemoval(_ reportsCancellation: Bool) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.prepareEmptyGroup("removed")
        let original = try fixture.service.store.load(fixture.root)
        model.workspace.details.setActive(false)
        model.workspace.record = original
        model.workspace.selection = .group("removed")
        model.management.run { service, root, progress in
            var outcome = await service.deleteConfirmed(.group("removed"), at: root, progress: progress)
            #expect(outcome.status == .success)
            #expect(outcome.items.contains { $0.effects.contains { $0.action == "remove-record-entry" } })
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            if reportsCancellation { outcome.status = .cancelled; outcome.reasonCode = "cancelled" }
            return outcome
        }
        let operation = try #require(model.operation)
        do {
            await operation.value
            let saved = try fixture.service.store.load(fixture.root)
            #expect(operation.isCancelled && !model.busy)
            #expect(original.groups["removed"] != nil && saved.groups["removed"] == nil)
            #expect(!PathSafety.exists(original.groupURL("removed")))
            #expect(model.workspace.record == saved && model.workspace.selection == nil)
            #expect(!model.workspace.visibleResources.contains(.group("removed")))
            #expect(model.workspace.blocked == nil)
            if reportsCancellation { #expect(model.presentation.result?.status == .cancelled) }
            else { #expect(model.presentation.result == nil) }
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            await operation.value
            throw error
        }
    }

    @Test func recordRefreshBatchesKeepCallbacksAndIndependentWaiters() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let trace = fixture.directory.appending(path: "reload-trace")
        let model = try await makeModel(fixture, trace: trace)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        model.workspace.details.setActive(false)
        var firstGate = try ReloadValidationGate(fixture.root)
        var secondGate: ReloadValidationGate?
        defer { try? firstGate.resume(); try? secondGate?.resume() }
        var callbacks: [String] = []
        var firstFinished = false
        var queued = 0
        var finished: [String] = []
        let first = Task {
            await model.workspace.refreshRecord {
                callbacks.append("initial")
                do { secondGate = try ReloadValidationGate(fixture.root) }
                catch { Issue.record(error) }
            }
            firstFinished = true
        }
        var following: [Task<Void, Never>] = []
        do {
            try await firstGate.waitUntilStarted()
            var latest = try fixture.service.store.load(fixture.root)
            latest.groups["latest"] = WorktreeGroup()
            try fixture.service.store.save(latest)
            for name in ["one", "two", "cancelled"] {
                following.append(Task {
                    queued += 1
                    await model.workspace.refreshRecord {
                        callbacks.append(name)
                        #expect(model.workspace.record == latest)
                    }
                    finished.append(name)
                })
                try await waitUntil { queued == following.count }
            }
            await Task.yield()
            following[2].cancel()
            try await waitUntil { finished == ["cancelled"] }
            #expect(!firstFinished && callbacks.isEmpty)
            try firstGate.resume()
            try await waitUntil { secondGate != nil }
            try await secondGate!.waitUntilStarted()
            try await waitUntil { firstFinished }
            #expect(callbacks == ["initial"] && finished == ["cancelled"])
            try secondGate!.resume()
            for task in following { await task.value }
            await first.value
            #expect(callbacks == ["initial", "one", "two"])
            #expect(Set(finished) == ["one", "two", "cancelled"])
            await model.workspace.stopReads()
            let commands = try String(contentsOf: trace, encoding: .utf8)
            #expect(commands.components(separatedBy: "built-in: git rev-parse --show-toplevel").count - 1 == 2)
        } catch {
            try? firstGate.resume(); try? secondGate?.resume()
            first.cancel(); for task in following { task.cancel() }
            await model.workspace.stopReads()
            await first.value; for task in following { await task.value }
            throw error
        }
    }

    @Test func maintenanceJoinKeepsOptionsAndFollowupReadDrainsBeforeWrites() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let trace = fixture.directory.appending(path: "maintenance-trace")
        let model = try await makeModel(fixture, trace: trace)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        var followupGate: ReloadValidationGate?
        defer { try? followupGate?.resume() }
        let originalBusyChange = model.operations.onBusyChange
        model.operations.onBusyChange = { busy in
            originalBusyChange?(busy)
            if !busy, followupGate == nil {
                do {
                    var changed = try fixture.service.store.load(fixture.root)
                    changed.groups["followup"] = WorktreeGroup()
                    try fixture.service.store.save(changed)
                    followupGate = try ReloadValidationGate(fixture.root)
                }
                catch { Issue.record(error) }
            }
        }
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        var maintenanceFinished = false
        var joined = false
        var joinFinished = false
        var bodyStarted = false
        let maintenance = Task {
            await model.workspace.maintainWorkspace(.startup)
            maintenanceFinished = true
        }
        var joining: Task<Void, Never>?
        var writing: Task<Void, Never>?
        do {
            try await waitForWorkspaceOperation(model)
            joining = Task {
                joined = true
                await model.workspace.maintainWorkspace()
                joinFinished = true
            }
            try await waitUntil { joined }
            await Task.yield()
            #expect(!model.workspace.showsReloadProgress && model.operations.canCancel)
            await model.activate()
            #expect(!maintenanceFinished && !joinFinished)
            lease.unlock()
            try await waitUntil { followupGate != nil }
            try await followupGate!.waitUntilStarted()
            try await waitUntil { maintenanceFinished && joinFinished }
            #expect(!model.busy && !model.workspace.isReloading && model.workspace.needsReadTermination)
            model.management.run { _, root, _ in
                await MainActor.run {
                    bodyStarted = true
                    #expect(!model.workspace.hasActiveReads)
                }
                return OperationResult(command: "repo.update", workspace: root.path, status: .success)
            }
            let operation = try #require(model.operation)
            writing = operation
            try await waitUntil { bodyStarted }
            try followupGate!.resume()
            await writing?.value
            await joining?.value
            await maintenance.value
            await model.workspace.stopReads()
            let commands = try String(contentsOf: trace, encoding: .utf8)
            #expect(commands.components(separatedBy: "ls-files -z -- repositories worktrees").count - 1 == 1)
        } catch {
            lease.unlock(); try? followupGate?.resume()
            model.cancel(); maintenance.cancel(); joining?.cancel()
            await model.workspace.stopReads()
            await maintenance.value; await joining?.value; await writing?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func invalidatedReloadBatchesDoNotPublishCallbacks(_ switchesWorkspace: Bool) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        var gate = try ReloadValidationGate(fixture.root)
        defer { try? gate.resume() }
        var callbacks: [String] = []
        var firstFinished = false
        var queued = false
        var queuedFinished = false
        var actionStarted = false
        let first = Task {
            await model.workspace.refreshRecord { callbacks.append("active") }
            firstFinished = true
        }
        var following: Task<Void, Never>?
        var switching: Task<Void, Error>?
        var stopping: Task<Void, Never>?
        do {
            try await gate.waitUntilStarted()
            following = Task {
                queued = true
                await model.workspace.refreshRecord { callbacks.append("pending") }
                queuedFinished = true
            }
            try await waitUntil { queued }
            await Task.yield()
            if switchesWorkspace {
                switching = Task {
                    actionStarted = true
                    try await model.switchTo(next)
                }
            } else {
                model.presentation.quitPending = true
                stopping = Task {
                    actionStarted = true
                    await model.workspace.stopReads()
                }
            }
            try await waitUntil { actionStarted }
            try await waitUntil { firstFinished && queuedFinished }
            try gate.resume()
            try await switching?.value
            await stopping?.value
            try await waitUntil { firstFinished && queuedFinished }
            await first.value; await following?.value
            #expect(callbacks.isEmpty)
            #expect(model.workspace.record?.root == PathSafety.canonical(switchesWorkspace ? next : fixture.root).path)
            await model.workspace.stopReads()
        } catch {
            try? gate.resume()
            first.cancel(); following?.cancel(); switching?.cancel()
            await model.workspace.stopReads()
            _ = try? await switching?.value
            await stopping?.value; await first.value; await following?.value
            throw error
        }
    }

    @Test(arguments: ["failed", "cancelled", "success"])
    func queuedStartupMaintenanceFollowsWorkspaceChangeOutcome(_ outcome: String) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = try fixture.service.store.load(fixture.root)
        initial.defaults.set(try JSONEncoder().encode(Resource.repository("repo")), forKey: "sidebar.\(record.root).selection")
        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try #require(await fixture.service.openWorkspace(next).status == .success)
        let lease = try fixture.service.store.tryLock(next)
        defer { lease.unlock() }
        let ignore = fixture.root.appending(path: ".gitignore")
        try FileManager.default.removeItem(at: ignore)
        let probe = fixture.directory.appending(path: "startup-switch-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MONO_DECK_STARTUP_SWITCH_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MONO_DECK_STARTUP_SWITCH_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: record.repositoryURL("repo"))
        }
        var runner = fixture.service.git.runner
        runner.environment["MONO_DECK_STARTUP_SWITCH_PROBE"] = probe.path
        let retry = WorkspaceLockRetryGate()
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try await retry.wait() })
        let service = WorkspaceService(store: store, git: Git(runner: runner))
        let tools = ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in })
        let model = AppModel(defaults: initial.defaults, service: service, toolService: tools, installer: try fixture.makeCLIInstaller())
        let startup = Task { await model.start() }
        var changing: Task<Void, Never>?
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            let initialRead = try #require(model.workspace.details.detailTask)
            #expect(model.workspace.maintenanceState == .pending && !model.busy)
            try #require(model.changeWorkspace(next))
            #expect(!model.showsWorkspacePreparation && !model.showsMainOperationProgress)
            let changeTask = try #require(model.operation)
            changing = changeTask
            #expect(await startup.value == false)
            #expect(initialRead.isCancelled && model.busy)
            await model.activate()
            try await retry.waitUntilStarted()
            try Data().write(to: probe.appending(path: "release"))
            if outcome == "success" { lease.unlock() }
            else if outcome == "cancelled" { model.cancel() }
            await retry.release()
            await changing?.value
            lease.unlock()

            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !model.workspace.canManage, ContinuousClock.now < readyDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(model.workspace.canManage)
            #expect(model.workspace.maintenanceState == .ready)
            if outcome == "success" {
                #expect(model.workspace.record?.root == PathSafety.canonical(next).path)
                #expect(!PathSafety.exists(ignore))
            } else {
                #expect(model.workspace.record == record)
                #expect(PathSafety.exists(ignore))
                if outcome == "failed" { #expect(model.presentation.result?.status == .failed) }
                else { #expect(model.presentation.result == nil || model.presentation.result?.status == .cancelled) }
            }
            await model.workspace.stopReads()
        } catch {
            await retry.release()
            try? Data().write(to: probe.appending(path: "release"))
            lease.unlock()
            model.cancel(); startup.cancel()
            _ = await startup.value
            await changing?.value
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func failedSwitchAfterCancellingMaintenanceKeepsWorkspaceBrowsable() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let maintenance = Task { await model.workspace.maintainWorkspace(.startup) }
        do {
            try await waitForWorkspaceOperation(model)
            #expect(model.operations.canCancel && model.workspace.isReloading)
            #expect(model.showsMainOperationProgress && model.mainOperationProgressText == model.text.string(.uiPreparingWorkspace))
            do {
                try await model.switchTo(fixture.directory.appending(path: "missing-workspace"))
                Issue.record("Switching to a missing workspace must fail.")
            } catch {
                #expect(!(error is CancellationError))
            }
            await maintenance.value
            #expect(model.workspace.record == original && model.defaults.string(forKey: "workspace") == original.root)
            #expect(!model.busy && !model.workspace.isReloading)
            #expect(model.workspace.maintenanceState == .failed && !model.workspace.canManage)
            #expect(model.workspace.maintenanceFailure?.status == .cancelled && !model.workspace.maintenanceFailurePending)
            #expect(model.presentation.result == nil && model.canShowMaintenanceFailure)
            model.showMaintenanceFailure()
            #expect(model.presentation.isMaintenanceFailure && model.presentation.result?.status == .cancelled)
            model.presentation.dismissResult()
            model.presentMaintenanceFailureIfPossible()
            #expect(model.presentation.result == nil)
            await model.workspace.refreshRecord()
            #expect(model.workspace.record == original && model.workspace.blocked == nil)
            #expect(!model.busy && !model.workspace.isReloading && model.workspace.maintenanceState == .failed)
            let recordURL = fixture.service.store.recordURL(fixture.root)
            let saved = try Data(contentsOf: recordURL)
            try Data("invalid".utf8).write(to: recordURL)
            await model.workspace.refreshRecord()
            #expect(model.workspace.record == original && model.workspace.notice != nil && !model.workspace.canManage)
            try saved.write(to: recordURL)
            await model.workspace.refreshRecord()
            #expect(model.workspace.record == original && model.workspace.notice == nil)
            #expect(model.workspace.maintenanceState == .failed && !model.workspace.canManage)
            lease.unlock()
            await model.workspace.maintainWorkspace()
            #expect(model.workspace.record == original && model.workspace.maintenanceState == .ready && model.workspace.canManage)
            await model.workspace.stopReads()
        } catch {
            lease.unlock(); maintenance.cancel()
            await model.workspace.stopReads()
            await maintenance.value
            throw error
        }
    }

    @Test func queuedMaintenanceKeepsExplicitReloadOptions() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let ignore = fixture.root.appending(path: ".gitignore")
        try FileManager.default.removeItem(at: ignore)
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let operationID = try #require(model.operations.begin(.workspace))
        await model.workspace.maintainWorkspace(.startup)
        await model.workspace.maintainWorkspace()
        await model.activate()
        model.operations.finish(operationID)
        do {
            try await waitForWorkspaceOperation(model)
            let maintenance = try #require(model.operation)
            #expect(model.workspace.showsReloadProgress && !model.operations.canCancel)
            model.cancel()
            #expect(!model.cancelling && !maintenance.isCancelled)
            lease.unlock()
            await maintenance.value
            #expect(model.workspace.canManage && model.workspace.maintenanceState == .ready)
            #expect(PathSafety.exists(ignore))
            await model.workspace.stopReads()
        } catch {
            lease.unlock()
            await model.operation?.value
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func queuedMaintenanceResumesAfterFailedQuit() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await model.workspace.restoreForStartup(fixture.root)
        let ignore = fixture.root.appending(path: ".gitignore")
        try FileManager.default.removeItem(at: ignore)
        let operationID = try #require(model.operations.begin(.workspace))
        await model.workspace.maintainWorkspace(.startup)
        model.presentation.quitPending = true
        model.operations.finish(operationID)
        await model.workspace.stopReads()
        #expect(model.workspace.maintenanceState == .pending && !PathSafety.exists(ignore))
        model.resumeAfterFailedQuit()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !model.workspace.canManage, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(model.workspace.canManage && model.workspace.maintenanceState == .ready)
            #expect(PathSafety.exists(ignore))
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func maintenanceRefreshesStatusesWithoutDiscardingWarmPreparation() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let trace = fixture.directory.appending(path: "maintenance-read-trace")
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        // Start record monitoring after the fixture has its final membership.
        let model = try await makeModel(fixture, trace: trace)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = try fixture.service.store.load(fixture.root)
        let member = Resource.member(groupName: "feature", repositoryID: "repo")
        let readState = {
            let detail = model.workspace.detail
            return """
            loading=\(model.workspace.detailLoading), preload=\(model.workspace.detailPreloadTask != nil), summary=\(detail.summary != nil), \
            changes=\(String(describing: detail.changes?.map(\.path))), changesError=\(String(describing: detail.changesError)), \
            summaryError=\(String(describing: detail.summaryError)), member=\(String(describing: model.workspace.state(for: member)))
            """
        }
        let originalBusyChange = model.operations.onBusyChange
        var gate: ReloadValidationGate?
        var maintenance: Task<Void, Never>?
        defer { model.operations.onBusyChange = originalBusyChange; try? gate?.resume() }
        do {
            model.workspace.record = record
            model.workspace.selection = .repository("repo")
            model.workspace.setVisibleResources([.repository("repo"), member], in: record.root)
            try await waitUntil(diagnostics: "Initial clean state: \(readState())") {
                !model.workspace.detailLoading && model.workspace.detail.summary != nil
                    && model.workspace.detail.changes?.isEmpty == true && model.workspace.detail.changesError == nil
                    && model.workspace.detail.summaryError == nil && model.workspace.state(for: member)?.dirty == false
            }
            await model.workspace.detailPreloadTask?.value
            try FileManager.default.removeItem(at: fixture.root.appending(path: ".gitignore"))
            gate = try ReloadValidationGate(fixture.root)
            model.operations.onBusyChange = { busy in
                originalBusyChange?(busy)
                if !busy {
                    do { try Data().write(to: trace) }
                    catch { Issue.record(error) }
                }
            }
            maintenance = Task { await model.workspace.maintainWorkspace() }
            try await gate!.waitUntilStarted()
            try Data("main change".utf8).write(to: record.repositoryURL("repo").appending(path: "main.txt"))
            try Data("member change".utf8).write(to: record.memberURL("feature", "repo").appending(path: "member.txt"))
            try gate!.resume()
            await maintenance?.value
            try await waitUntil(diagnostics: "Refreshed state after maintenance: \(readState())") {
                model.workspace.detail.changes?.map(\.path) == ["main.txt"]
                    && model.workspace.state(for: member)?.dirty == true
                    && !model.workspace.detailLoading && model.workspace.detailPreloadTask == nil
            }
            #expect(model.workspace.canManage)
            await model.workspace.stopReads()
            let commands = try String(contentsOf: trace, encoding: .utf8)
            #expect(commands.contains("status --porcelain=v2"))
            #expect(commands.contains("config --null --show-origin --includes --list"))
            #expect(!commands.contains("worktree list") && !commands.contains("rev-parse --absolute-git-dir"))
        } catch {
            try? gate?.resume()
            model.cancel(); maintenance?.cancel()
            await model.workspace.stopReads()
            await maintenance?.value
            throw error
        }
    }

    @Test func startupShowsCompleteDetailsBeforeMaintenanceAndKeepsNavigationDuringMaintenance() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        initial.workspace.record = try fixture.service.store.load(fixture.root)
        initial.workspace.selection = .repository("repo")
        await initial.workspace.details.detailTask?.value
        await initial.workspace.stopReads()
        let record = try #require(initial.workspace.record)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "launch history"], at: record.repositoryURL("repo"))
        try Data("on launch".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
        let model = AppModel(defaults: initial.defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())
        var gate = try ReloadValidationGate(fixture.root)
        defer { try? gate.resume() }
        var readyCount = 0
        let startup = Task { await model.start(onReady: {
            readyCount += 1
            #expect(model.workspace.record == record && !model.workspace.canManage && !model.busy)
            #expect(model.showsWorkspacePreparation && !model.showsMainOperationProgress)
        }) }
        do {
            try await gate.waitUntilStarted()
            #expect(readyCount == 1 && model.busy)
            #expect(model.showsMainOperationProgress && !model.showsWorkspacePreparation && model.operations.canCancel)
            #expect(model.mainOperationProgressText == model.text.string(.uiPreparingWorkspace))
            #expect(model.workspace.detail.changes?.map(\.path) == ["new.txt"])
            #expect(model.workspace.detail.summary?.head == "main")
            #expect(model.workspace.detail.uniqueCommits?.map(\.subject) == ["launch history"] && model.workspace.detail.behindCommits?.isEmpty == true)
            model.workspace.selection = .member(groupName: "feature", repositoryID: "repo")
            #expect(model.workspace.details.detailTask == nil)
            try gate.resume()
            #expect(await startup.value == false)
            await model.workspace.details.detailTask?.value
            #expect(readyCount == 1 && model.workspace.canManage)
            #expect(model.workspace.selection == .member(groupName: "feature", repositoryID: "repo"))
            #expect(model.workspace.detail.summary?.head == "feature")
            await model.workspace.stopReads()
        } catch {
            try? gate.resume()
            _ = await startup.value
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func reloadReinitializesRecreatedWorkspaceWithoutLosingUserFiles() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        try await fixture.prepareGroup("old", repositoryIDs: ["repo"])
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.selection = .member(groupName: "old", repositoryID: "repo")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.workspace.detailLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!model.workspace.detailLoading)
        await model.workspace.detailPreloadTask?.value

        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        let notes = fixture.root.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: notes)
        model.presentation.completionMessage = "Completed"
        await model.workspace.maintainWorkspace()

        let record = try #require(model.workspace.record)
        #expect(record.repositories.isEmpty && record.groups.isEmpty)
        #expect(model.workspace.selection == nil && model.workspace.blocked == nil && model.presentation.result == nil)
        #expect(model.presentation.completionMessage == nil)
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(try fixture.service.store.load(fixture.root) == record)
        for path in [".git", "repositories", "worktrees", ".agents/skills/mono-deck-workflow/SKILL.md", ".agents/skills/mono-deck-workflow/agents/openai.yaml"] {
            #expect(PathSafety.exists(fixture.root.appending(path: path)))
        }
        #expect(try await fixture.service.git.run(["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.root).text.components(separatedBy: "\n") == [".agents/skills/mono-deck-workflow/SKILL.md", ".agents/skills/mono-deck-workflow/agents/openai.yaml", ".gitignore"])
        #expect(try Data(contentsOf: notes) == Data("keep me".utf8))
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        await model.workspace.maintainWorkspace()
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)

    }

    @Test func activationReadsWithoutMaintenanceAndExplicitReloadStillRepairs() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        var now = ContinuousClock.now
        let model = try await makeModel(fixture, now: { now })
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        await model.activate()
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.root.appending(path: ".gitignore")))
        #expect(model.workspace.record != nil && model.workspace.blocked == nil && model.workspace.notice != nil)
        #expect(!model.workspace.canManage && model.presentation.result == nil)

        await model.workspace.maintainWorkspace()
        let head = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
        let skill = fixture.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")
        try Data("user edit".utf8).write(to: skill)
        var record = try #require(model.workspace.record)
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        now = now.advanced(by: .seconds(10))
        await model.activate()
        #expect(model.workspace.record == record)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try String(contentsOf: skill, encoding: .utf8) == "user edit")
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)
        #expect(model.workspace.canManage && model.workspace.notice == nil)
        await model.workspace.stopReads()
    }

    @Test func queuedMaintenanceReloadWaitsForReadOnlyActivationAndIgnoresCancellation() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        await model.workspace.maintainWorkspace()
        await model.workspace.detailPreloadTask?.value
        let head = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
        var record = try fixture.service.store.load(fixture.root)
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let skill = fixture.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")
        let installedSkill = try Data(contentsOf: skill)
        try Data("user edit".utf8).write(to: skill)
        var gate = try ReloadValidationGate(fixture.root)
        defer { try? gate.resume() }
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let refreshing = Task { await model.activate() }
        var maintaining: Task<Void, Never>?
        do {
            try await gate.waitUntilStarted()
            #expect(!model.busy && model.operation == nil)
            model.cancel()
            #expect(!model.cancelling && !refreshing.isCancelled)
            var maintenanceRequested = false
            maintaining = Task {
                maintenanceRequested = true
                await model.workspace.maintainWorkspace()
            }
            while !maintenanceRequested { await Task.yield() }
            model.cancel()
            #expect(!model.cancelling && !refreshing.isCancelled && maintaining?.isCancelled == false)
            #expect(try fixture.service.store.load(fixture.root).groups["missing"] != nil)
            #expect(try String(contentsOf: skill, encoding: .utf8) == "user edit")

            try gate.resume()
            await refreshing.value
            try await waitForWorkspaceOperation(model)
            let operation = try #require(model.operation)
            #expect(!model.operations.canCancel)
            model.cancel()
            await Task.yield()
            #expect(model.busy && model.openingWorkspace && !model.cancelling && !operation.isCancelled)
            lease.unlock()
            await maintaining?.value
            await model.workspace.detailPreloadTask?.value

            #expect(!model.busy && model.operation == nil)
            #expect(model.workspace.record?.groups.isEmpty == true)
            #expect(try fixture.service.store.load(fixture.root).groups.isEmpty)
            #expect(try Data(contentsOf: skill) == installedSkill)
            #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)
            #expect(model.workspace.blocked == nil && model.presentation.result == nil && model.presentation.message == nil)
        } catch {
            try? gate.resume()
            lease.unlock()
            await refreshing.value
            await maintaining?.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func activationKeepsSettingsImportFailurePresented(_ dismissDuringReload: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let file = fixture.root.appending(path: "repositories/.user-data")
        try Data("keep me".utf8).write(to: file)
        model.presentation.resultHost = .settings
        model.management.importWorkspace("version: 2\nrepositories: []\ngroups: {}", filename: "workspace.yaml")
        await (try #require(model.operation)).value
        #expect(model.presentation.result?.reasonCode == "workspace-not-empty" && model.presentation.resultHost == .settings)
        let presentation = SettingsView(model: model).operationSheetPresentation
        #expect(presentation.wrappedValue)

        var record = try #require(model.workspace.record)
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let refresh = Task { await model.activate() }
        #expect(presentation.wrappedValue)
        #expect(model.presentation.result?.reasonCode == "workspace-not-empty" && model.presentation.resultHost == .settings)
        if dismissDuringReload {
            presentation.wrappedValue = false
            #expect(!presentation.wrappedValue && model.presentation.result == nil)
        }
        lease.unlock()
        await refresh.value

        #expect(!model.busy && !model.openingWorkspace)
        #expect(presentation.wrappedValue == !dismissDuringReload)
        #expect(model.workspace.record?.groups["missing"] != nil)
        #expect(try fixture.service.store.load(fixture.root).groups["missing"] != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
        if !dismissDuringReload {
            #expect(model.presentation.result?.reasonCode == "workspace-not-empty" && model.presentation.resultHost == .settings)
            presentation.wrappedValue = false
        }
        #expect(model.presentation.result == nil && model.presentation.resultHost == .main)
        await model.workspace.detailPreloadTask?.value
    }

    @Test(arguments: ["missing", "invalid"], [false, true])
    func reloadDoesNotInitializeWithMissingOrInvalidRecord(_ kind: String, _ implicit: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let file = fixture.service.store.recordURL(fixture.root)
        if kind == "missing" { try FileManager.default.removeItem(at: file) }
        else { try Data("broken".utf8).write(to: file) }
        try FileManager.default.removeItem(at: fixture.root.appending(path: ".git"))

        if implicit { await model.activate() } else { await model.workspace.maintainWorkspace() }
        #expect(model.workspace.record != nil && model.workspace.blocked == nil && !model.workspace.canManage)
        #expect(model.workspace.notice != nil)
        if implicit {
            #expect(model.workspace.maintenanceState == .ready)
        } else {
            #expect(model.workspace.maintenanceState == .failed)
        }
        await model.workspace.waitForReadCancellation()
        #expect(!model.workspace.details.hasActiveReads)
        #expect((model.presentation.result == nil) == implicit)
        #expect(model.presentation.isMaintenanceFailure == !implicit && !model.busy && !model.openingWorkspace)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.root.appending(path: ".agents")))
        if kind == "missing" { #expect(!PathSafety.exists(file)) }
        else { #expect(try Data(contentsOf: file) == Data("broken".utf8)) }
        await model.workspace.stopReads()
    }

    @Test func reloadInitializationFailureReportsRetainedEffectsAndCanRetry() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        _ = try await fixture.service.git.run(["config", "commit.gpgSign", "true"], at: fixture.root)
        _ = try await fixture.service.git.run(["config", "gpg.program", "/usr/bin/false"], at: fixture.root)
        await model.workspace.maintainWorkspace()
        #expect(model.workspace.record != nil && model.workspace.maintenanceState == .failed && !model.busy)
        #expect(!model.workspace.canManage && model.workspace.notice != nil)
        #expect(model.presentation.result?.items.first?.reasonCode == "workspace-commit-failed")
        #expect(model.presentation.result?.items.first?.effects.contains { $0.action == "install-skill" } == true)
        #expect(model.presentation.isMaintenanceFailure && !model.workspace.maintenanceFailurePending)
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")))
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)

        _ = try await fixture.service.git.run(["config", "commit.gpgSign", "false"], at: fixture.root)
        model.presentation.dismissResult()
        model.presentMaintenanceFailureIfPossible()
        #expect(model.presentation.result == nil && model.canShowMaintenanceFailure)
        model.showMaintenanceFailure()
        #expect(model.presentation.result?.items.first?.effects == model.workspace.maintenanceFailure?.items.first?.effects)
        await model.retryWorkspaceMaintenance()
        #expect(model.workspace.record != nil && model.workspace.blocked == nil && model.presentation.result == nil)
        #expect(model.workspace.maintenanceFailure == nil && !model.workspace.maintenanceFailurePending && !model.canShowMaintenanceFailure)
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) != head)
        #expect(try await fixture.service.git.changes(at: fixture.root).isEmpty)
    }

    @Test(arguments: [false, true])
    func maintenanceFailureWaitsForPresentationsAndDoesNotOutliveItsContext(_ switchWorkspace: Bool) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try FileManager.default.removeItem(at: fixture.service.store.recordURL(fixture.root))
        model.presentation.resultHost = .settings
        model.presentation.result = .init(command: "workspace.configuration.import", workspace: fixture.root.path, status: .failed)
        await model.workspace.maintainWorkspace(.startup)
        #expect(model.workspace.maintenanceFailurePending && !model.canPresentMaintenanceFailure)
        #expect(model.presentation.result?.command == "workspace.configuration.import" && model.presentation.resultHost == .settings)

        model.presentation.mainSheetVisible = true
        model.presentation.dismissResult()
        model.presentMaintenanceFailureIfPossible()
        #expect(model.presentation.result == nil && model.workspace.maintenanceFailurePending)
        if switchWorkspace {
            let next = fixture.directory.appending(path: "next-workspace")
            try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
            try #require(await fixture.service.openWorkspace(next).status == .success)
            try await model.switchTo(next)
            model.presentation.mainSheetVisible = false
            model.presentMaintenanceFailureIfPossible()
            #expect(model.workspace.maintenanceFailure == nil && !model.workspace.maintenanceFailurePending)
            #expect(model.presentation.result == nil && !model.canShowMaintenanceFailure)
            await model.workspace.stopReads()
            return
        }
        model.presentation.mainSheetVisible = false
        model.presentation.message = "Another error"
        model.presentMaintenanceFailureIfPossible()
        #expect(model.presentation.result == nil && model.workspace.maintenanceFailurePending)
        model.presentation.message = nil
        model.management.sheet = .add
        model.presentMaintenanceFailureIfPossible()
        #expect(model.presentation.result == nil && model.workspace.maintenanceFailurePending)
        model.management.sheet = nil
        model.presentMaintenanceFailureIfPossible()
        #expect(model.presentation.isMaintenanceFailure && model.presentation.result?.command == "workspace.open")
        #expect(!model.workspace.maintenanceFailurePending)

        model.presentation.dismissResult()
        await model.workspace.refreshRecord()
        model.presentMaintenanceFailureIfPossible()
        #expect(model.presentation.result == nil && model.canShowMaintenanceFailure && !model.workspace.canManage)
        await model.workspace.stopReads()
    }

    @Test func startupPublishesWorkspaceAndToolsBeforeSlowResourceChecks() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        var record = try fixture.service.store.load(fixture.root)
        let other = Repository(url: "https://mono-deck-test.invalid/other.git")
        try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL(other.id))
        _ = try await fixture.service.git.run(["config", "remote.origin.url", other.url], at: record.repositoryURL(other.id))
        record.repositories.append(other)
        try fixture.service.store.save(record)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")

        let probe = fixture.directory.appending(path: "startup-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MONO_DECK_STARTUP_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MONO_DECK_STARTUP_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: record.repositoryURL(other.id))
        }
        var runner = fixture.service.git.runner
        runner.environment["MONO_DECK_STARTUP_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? probe.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: service, toolService: tools, installer: try fixture.makeCLIInstaller())
        var completed = false
        let startup = Task {
            let needsSetup = await model.start(onReady: {
                model.workspace.setVisibleResources(Set(service.resources(record)), in: record.root)
            })
            completed = true
            return needsSetup
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(completed && !model.busy && !model.openingWorkspace)
            #expect(model.workspace.record == record && model.workspace.blocked == nil)
            #expect(model.tools.map(\.id) == ["codex"])
            try Data("changed".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
            model.workspace.selection = .repository("repo")
            let detailDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.workspace.detailLoading, ContinuousClock.now < detailDeadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.workspace.detailLoading && model.workspace.detail.changes?.map(\.path) == ["new.txt"])
            #expect(model.workspace.state(for: .repository("repo"))?.dirty == true)
            try Data().write(to: probe.appending(path: "release"))
            #expect(await startup.value == false)
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.state(for: .repository(other.id))?.available == true)
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            _ = await startup.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func startupChecksCLIBeforeOpeningTheSavedWorkspace(_ cliAvailable: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let saved = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(saved)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        defaults.set(saved.root, forKey: "workspace")
        defaults.set(false, forKey: "sidebar.\(saved.root).repositoriesExpanded")
        let installer = try fixture.makeCLIInstaller()
        if !cliAvailable { try FileManager.default.removeItem(at: installer.executable) }
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)
        var readyCount = 0

        #expect(await model.start(onReady: { readyCount += 1 }) == !cliAvailable)
        #expect(readyCount == (cliAvailable ? 1 : 0))
        #expect(model.workspace.blocked == nil && model.presentation.result == nil && !model.busy)
        #expect(defaults.string(forKey: "workspace") == saved.root)
        if cliAvailable {
            #expect(model.workspace.record == saved)
            #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)
        } else {
            #expect(model.workspace.record == nil && model.operation == nil)
            #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
            #expect(defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)
            #expect(!PathSafety.exists(fixture.root.appending(path: "repositories")))
        }
    }

    @Test(arguments: ["missing-link", "missing-path"])
    func setupUsesStartupCLIResultAndRestoresSavedSelection(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(record)
        defaults.set(record.root, forKey: "workspace")
        let installer = try fixture.makeCLIInstaller(resolved: kind != "missing-path")
        if kind == "missing-link" { try FileManager.default.removeItem(at: installer.commandLink) }
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)
        #expect(await model.start() == true)
        await model.workspace.detailPreloadTask?.value
        let initial = try #require(model.startupCLIInstallation)
        #expect(!initial.available)

        let file = fixture.service.store.recordURL(fixture.root)
        if kind == "missing-link" { try FileManager.default.removeItem(at: file) }
        if kind == "missing-path" { try Data("invalid record".utf8).write(to: file) }
        let original = PathSafety.exists(file) ? try Data(contentsOf: file) : nil

        let setup = SetupModel(model: model)
        #expect(setup.cliReady == initial.available && setup.cliActivity == nil)
        #expect(setup.cliMessage == initial.message && setup.cliUserMessage == initial.userMessage)
        #expect(setup.cliPreviouslyInstalled)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: installer.executable)
        if kind == "missing-link" { try FileManager.default.createSymbolicLink(at: installer.commandLink, withDestinationURL: installer.executable) }
        await setup.check()
        #expect(setup.cliReady == initial.available && setup.cliMessage == initial.message)
        #expect(setup.cliActivity == nil && !setup.working && model.startupCLIInstallation == nil)
        #expect(setup.selectedWorkspace?.path == PathSafety.canonical(fixture.root).path)
        #expect(setup.error == nil)
        #expect((PathSafety.exists(file) ? try Data(contentsOf: file) : nil) == original)

        setup.windowClosed()
        await setup.check()
        #expect(!setup.cliReady && setup.cliUserMessage == .appSBundledCLICouldNotRun)

        let otherWorkspace = PathSafety.canonical(fixture.directory.appending(path: "other-workspace"))
        try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        try fixture.service.store.save(WorkspaceRecord(root: otherWorkspace.path))
        defaults.set(otherWorkspace.path, forKey: "workspace")
        #expect(!setup.isPreparedForCurrentWorkspace)
        await setup.check()
        #expect(setup.isPreparedForCurrentWorkspace)
        #expect(setup.selectedWorkspace?.path == otherWorkspace.path)
        await model.workspace.stopReads()
    }

    @Test(arguments: ["cancelled", "quitting"])
    func interruptedSetupKeepsWorkspaceAndTools(_ kind: String) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try fixture.service.store.load(fixture.root)
        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        let opened = await fixture.service.openWorkspaceWithRecord(nextRoot)
        let next = try #require(opened.record)
        let tools = ExternalTools(applicationURL: { id in
            if kind == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return id == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil
        }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools)
        model.workspace.record = original
        defaults.set(original.root, forKey: "workspace")
        let previousTools = ExternalTool.builtIn.filter { $0.id == "terminal" }
        model.tools = previousTools
        model.presentation.quitPending = kind == "quitting"

        do {
            try await Task { try await model.completeSetup(nextRoot, loaded: next) }.value
            Issue.record("Expected interrupted setup to stop before publishing the workspace.")
        } catch { #expect(error is CancellationError) }
        #expect(model.workspace.record == original && model.tools == previousTools)
        #expect(defaults.string(forKey: "workspace") == original.root)
    }

    @Test(arguments: ["installation", "path"], [false, true])
    func startupDefersCLIChecksToSetupAndWaitsForQuit(_ stage: String, _ quitting: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let baseInstaller = try fixture.makeCLIInstaller()
        let probe = fixture.directory.appending(path: "cli-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let shell = fixture.directory.appending(path: "login-shell")
        let command = stage == "installation" ? "printf '\(MonoDeckVersion.current)\\n'" : "exec /bin/sh -c \"$2\""
        try Data("""
        #!/bin/sh
        printf 'check\\n' >> "$MONO_DECK_CLI_PROBE/calls"
        : > "$MONO_DECK_CLI_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MONO_DECK_CLI_PROBE/release" ]; do sleep 0.02; done
        \(command)
        """.utf8).write(to: stage == "installation" ? baseInstaller.executable : shell)
        var environment = baseInstaller.runner.environment
        environment["MONO_DECK_CLI_PROBE"] = probe.path
        let installer = InstallationService(support: baseInstaller.support, executable: baseInstaller.executable, runner: .init(environment: environment), home: fixture.directory, shell: shell.path)
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)
        defer { model.globalShortcut.stop() }
        var terminationRequests = 0
        let delegate = AppDelegate(terminate: { _ in terminationRequests += 1 })
        var setup: SetupModel?
        delegate.start(model: model, onReady: { Issue.record("Expected setup without opening the main window.") }, onFinished: { needsSetup in
            #expect(needsSetup && model.startupCLIInstallation == nil)
            #expect(!PathSafety.exists(probe.appending(path: "started")))
            let initialSetup = SetupModel(model: model)
            setup = initialSetup
            #expect(initialSetup.cliActivity == .checking && !initialSetup.cliReady)
            await initialSetup.check()
        })
        let startup = try #require(delegate.startupTask)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            let setup = try #require(setup)
            #expect(setup.working && setup.cliActivity == .checking && !setup.cliReady)
            await setup.check()
            if quitting {
                #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
                await (try #require(delegate.terminationTask)).value
                #expect(terminationRequests == 1 && startup.isCancelled && model.presentation.quitPending)
                #expect(!setup.isPreparedForCurrentWorkspace && !setup.cliReady)
            } else {
                try Data().write(to: probe.appending(path: "release"))
                await startup.value
                #expect(setup.isPreparedForCurrentWorkspace && setup.cliReady)
                await setup.check()
            }
            #expect(!setup.working && setup.cliActivity == nil && delegate.startupTask == nil)
            #expect(try String(contentsOf: probe.appending(path: "calls"), encoding: .utf8) == "check\n")
            #expect(!model.hasSavedWorkspace && model.workspace.record == nil && model.startupCLIInstallation == nil)
            #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        } catch {
            startup.cancel()
            try? Data().write(to: probe.appending(path: "release"))
            await startup.value
            await delegate.terminationTask?.value
            throw error
        }
    }

    @Test(arguments: ["available", "missing-path", "cancelled"])
    func startupPublishesWorkspaceBeforeSlowCLIPathCheck(_ kind: String) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let baseInstaller = try fixture.makeCLIInstaller(resolved: kind != "missing-path")
        let probe = fixture.directory.appending(path: "cli-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let shell = fixture.directory.appending(path: "login-shell")
        try Data("""
        #!/bin/sh
        : > "$MONO_DECK_CLI_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MONO_DECK_CLI_PROBE/release" ]; do sleep 0.02; done
        exec /bin/sh -c "$2"
        """.utf8).write(to: shell)
        var environment = baseInstaller.runner.environment
        environment["MONO_DECK_CLI_PROBE"] = probe.path
        let installer = InstallationService(support: baseInstaller.support, executable: baseInstaller.executable, runner: .init(environment: environment), home: fixture.directory, shell: shell.path)
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools, installer: installer)
        var completed = false
        var readyCount = 0
        let startup = Task {
            let needsSetup = await model.start(onReady: {
                readyCount += 1
                #expect(model.workspace.record == record && !model.busy && model.tools.map(\.id) == ["codex"])
            })
            completed = true
            return needsSetup
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while (!PathSafety.exists(probe.appending(path: "started")) || readyCount == 0 || model.workspace.record == nil || model.busy || model.tools.isEmpty), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(!completed && !model.busy && !model.openingWorkspace)
            #expect(readyCount == 1)
            #expect(model.workspace.record == record && model.workspace.blocked == nil)
            #expect(model.tools.map(\.id) == ["codex"])
            if kind == "cancelled" { startup.cancel() }
            else { try Data().write(to: probe.appending(path: "release")) }
            #expect(await startup.value == (kind == "missing-path"))
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.record == record && model.presentation.result == nil)
            #expect(defaults.string(forKey: "workspace") == record.root)
            #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        } catch {
            startup.cancel()
            try? Data().write(to: probe.appending(path: "release"))
            _ = await startup.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func startupDoesNotReinitializeWorkspaceWhenRecordIsMissing(_ initialized: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        if initialized { #expect(await fixture.service.openWorkspace(fixture.root).status == .success) }
        else { try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)) }
        let record = fixture.service.store.recordURL(fixture.root)
        try FileManager.default.removeItem(at: record)
        let notes = fixture.root.appending(path: "notes.txt")
        try Data("keep me\n".utf8).write(to: notes)
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let head = initialized ? try await fixture.service.git.oid("HEAD", at: fixture.root) : nil
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())

        #expect(await model.start() == false)
        #expect(model.workspace.record == nil && model.workspace.blocked != nil && !model.busy)
        #expect(model.presentation.result?.items.first?.reasonCode == "workspace-record-missing")
        #expect(model.presentation.result?.items.allSatisfy { $0.effects.isEmpty } == true)
        #expect(defaults.string(forKey: "workspace") == fixture.root.path)
        #expect(!PathSafety.exists(record))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == entries)
        #expect(try Data(contentsOf: notes) == Data("keep me\n".utf8))
        if initialized { #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head) }
        else { #expect(!PathSafety.exists(fixture.root.appending(path: ".git"))) }
    }

    @Test(arguments: ["invalid-record", "missing-root", "busy", "no-saved-workspace"])
    func startupSignalsReadyForWorkspaceErrorsAndSetup(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        if kind != "no-saved-workspace" {
            defaults.set(fixture.root.path, forKey: "workspace")
            try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(fixture.root).path))
        }
        if kind == "invalid-record" { try Data("invalid".utf8).write(to: fixture.service.store.recordURL(fixture.root)) }
        if kind == "missing-root" { try FileManager.default.removeItem(at: fixture.root) }
        let lease = kind == "busy" ? try fixture.service.store.tryLock(fixture.root) : nil
        defer { lease?.unlock() }
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try Task.checkCancellation() })
        let service = WorkspaceService(store: store, git: fixture.service.git, trash: fixture.service.trashDirectory)
        let model = AppModel(defaults: defaults, service: service, toolService: tools, installer: try fixture.makeCLIInstaller())
        var readyCount = 0
        let needsSetup = await model.start(onReady: {
            readyCount += 1
            #expect(!model.busy && model.tools.map(\.id) == ["codex"])
            #expect((model.workspace.record != nil) == (kind == "busy"))
            #expect((model.workspace.blocked != nil) == (kind != "no-saved-workspace" && kind != "busy"))
        })
        let expectedReadyCount = kind == "no-saved-workspace" ? 0 : 1
        #expect(needsSetup == (kind == "no-saved-workspace"))
        #expect(readyCount == expectedReadyCount)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(await model.start(onReady: { readyCount += 1 }) == false)
        #expect(readyCount == expectedReadyCount)
    }

    @Test func quittingAfterEarlyStartupPresentationStillPresentsRetainedEffects() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        let probe = fixture.directory.appending(path: "quit-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MONO_DECK_QUIT_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MONO_DECK_QUIT_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: fixture.root)
        }
        let ignore = fixture.root.appending(path: ".gitignore")
        var ignoreData = try Data(contentsOf: ignore)
        ignoreData.append(Data("\n".utf8))
        try ignoreData.write(to: ignore)
        var runner = fixture.service.git.runner
        runner.environment["MONO_DECK_QUIT_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let tools = ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: service, toolService: tools, installer: try fixture.makeCLIInstaller())
        let delegate = AppDelegate()
        var readyCount = 0
        delegate.start(model: model, onReady: {
            readyCount += 1
            #expect(!model.presentation.quitPending && model.workspace.record != nil && !model.workspace.canManage)
        }, onFinished: { _ in })
        let startup = try #require(delegate.startupTask)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(readyCount == 1 && model.busy)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            try Data().write(to: probe.appending(path: "release"))
            await startup.value
            #expect(readyCount == 1 && model.presentation.quitPending && !model.busy)
            #expect(model.presentation.result?.items.contains { !$0.effects.isEmpty } == true)
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await startup.value
            throw error
        }
    }

    @Test func reloadRemovesDeletedDirectoriesAndTheirReferences() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        for group in ["feature", "kept"] {
            try await fixture.prepareGroup(group, repositoryIDs: ["repo"])
        }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.expandedGroups = ["feature", "kept"]
        for resource in [Resource.member(groupName: "feature", repositoryID: "repo"), .group("feature"), .repository("repo")] {
            var expected = try #require(model.workspace.record)
            switch resource.kind {
            case .repository:
                expected.repositories = []
                for group in expected.groups.keys { expected.groups[group]?.repositoryIDs = [] }
            case .group: expected.groups.removeValue(forKey: "feature")
            default: expected.groups["feature"]?.repositoryIDs = []
            }
            model.workspace.selection = resource
            try FileManager.default.removeItem(at: fixture.root.appending(path: resource.path))
            await model.workspace.maintainWorkspace()
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.record == expected)
            #expect(try fixture.service.store.load(fixture.root) == expected)
            #expect(model.workspace.selection == nil && model.workspace.detail.summary == nil)
            #expect(model.workspace.state(for: resource) == nil && model.workspace.blocked == nil)
            #expect(model.workspace.expandedGroups == Set(expected.groups.keys))
            #expect(PathSafety.exists(expected.groupURL("kept")) && PathSafety.exists(expected.memberURL("kept", "repo")))
            #expect(try await fixture.service.git.oid("refs/heads/feature", at: fixture.root) != nil)
            #expect(try await fixture.service.git.registrations(at: fixture.root).count == 3)
            if resource.kind != .repository {
                #expect(try await fixture.service.git.oid("refs/heads/feature", at: expected.repositoryURL("repo")) != nil)
                #expect(try await fixture.service.git.registrations(at: expected.repositoryURL("repo")).count == 3)
            }
        }
        let inspection = await fixture.service.inspect(fixture.root)
        #expect(inspection.status == .success && inspection.items.allSatisfy { $0.resource.repositoryID == nil })
    }

    @Test(arguments: ["open", "inspect", "tree", "repo", "group", "export"])
    func onlyMaintenanceRemovesMissingResourceRecords(_ entry: String) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        let empty = try fixture.service.store.load(fixture.root)
        var record = empty
        record.repositories = [.init(url: fixture.remoteURL)]
        record.groups["feature"] = WorktreeGroup(repositoryIDs: ["repo"])
        try fixture.service.store.save(record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        switch entry {
        case "open":
            let opened = await fixture.service.openWorkspaceWithRecord(fixture.root)
            #expect(opened.result.status == .success && opened.record == empty)
        case "inspect":
            let inspected = await fixture.service.inspect(fixture.root)
            #expect(inspected.status == .partialSuccess && inspected.items.count == 4)
        case "tree":
            let tree = try await fixture.service.workspaceTree(fixture.root)
            #expect(tree.children?.allSatisfy { $0.children == [] } == true)
        case "export":
            let yaml = try await fixture.service.exportYAML(at: fixture.root)
            #expect(yaml.contains(fixture.remoteURL) && yaml.contains("feature"))
        default:
            let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
            var runner = fixture.service.git.runner
            runner.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] = fixture.service.store.support.path
            let output = try await runner.run(executable.path, [entry, "list", "--json", "--workspace", fixture.root.path])
            let inspected = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
            #expect(output.status == 1 && inspected.status == .failed)
            #expect(inspected.items.contains { $0.status == .failed })
        }
        if entry == "open" { #expect(try fixture.service.store.load(fixture.root) == empty) }
        else { #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original) }
    }

    @Test(arguments: ["git", "file", "symlink", "permissions"])
    func unavailableDirectoriesKeepTheirConfiguration(_ kind: String) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        var record = try fixture.service.store.load(fixture.root)
        record.repositories = [.init(url: fixture.remoteURL)]
        try fixture.service.store.save(record)
        let path = record.repositoryURL("repo")
        switch kind {
        case "git": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        case "file": try Data("keep".utf8).write(to: path)
        case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.directory.appending(path: "missing"))
        default: try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.deletingLastPathComponent().path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.deletingLastPathComponent().path) }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        #expect(try await fixture.service.load(fixture.root) == record)
        let inspection = await fixture.service.inspect(fixture.root)
        #expect(inspection.items.first { $0.resource == .repository("repo") }?.status == .failed)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func failedCleanupAndMissingWorkspaceDoNotOverwriteConfiguration() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        var record = try #require(model.workspace.record)
        record.repositories = [.init(url: fixture.remoteURL)]
        try fixture.service.store.save(record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let failingStore = WorkspaceStore(support: fixture.service.store.support) { _, _ in throw MonoDeckError("injected", "save failed") }
        let failing = AppModel(defaults: model.defaults, service: WorkspaceService(store: failingStore, git: fixture.service.git))
        await failing.workspace.maintainWorkspace()
        #expect(failing.workspace.record == nil && failing.workspace.blocked != nil)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)

        try FileManager.default.removeItem(at: fixture.root)
        await model.workspace.maintainWorkspace()
        #expect(model.workspace.record != nil && model.workspace.maintenanceState == .failed && !model.workspace.canManage)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func openingWorkspacesUsesSavedRecordsAndPreservesHistory() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        var record = try fixture.service.store.load(fixture.root)
        record.repositories[0].displayNameOverride = "Custom"
        try fixture.service.store.save(record)
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        try await fixture.prepareEmptyGroup("closed")
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        await model.workspace.stopReads()
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.toggleGroup("closed")
        model.workspace.selection = .member(groupName: "feature", repositoryID: "repo")
        model.workspace.details.collapsedPaths = ["Sources"]
        model.defaults.set(false, forKey: model.workspace.sidebarPreferenceKey("repositoriesExpanded"))
        model.defaults.set(false, forKey: model.workspace.sidebarPreferenceKey("groupsExpanded"))
        model.defaults.set("zh_CN", forKey: "appLanguage")
        model.defaults.set("codex", forKey: "tool.Agent")
        let saved = try #require(model.workspace.record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))

        let reopened = AppModel(defaults: model.defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())
        var readySelection: Resource?
        #expect(await reopened.start { readySelection = reopened.workspace.selection } == false)
        #expect(readySelection == .member(groupName: "feature", repositoryID: "repo"))
        #expect(reopened.workspace.details.collapsedPaths == ["Sources"])
        #expect(reopened.workspace.blocked == nil && !reopened.busy)
        #expect(reopened.workspace.expandedGroups == ["feature"])
        #expect(reopened.defaults.object(forKey: reopened.workspace.sidebarPreferenceKey("repositoriesExpanded")) as? Bool == false)
        #expect(reopened.defaults.object(forKey: reopened.workspace.sidebarPreferenceKey("groupsExpanded")) as? Bool == false)
        #expect(reopened.workspace.record?.repositories.first?.url == fixture.remoteURL)
        #expect(reopened.workspace.record == saved)
        #expect(reopened.workspace.record?.repositories.first?.displayNameOverride == "Custom")
        #expect(Set(reopened.workspace.record?.groups.keys ?? [:].keys) == ["feature", "closed"])

        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        reopened.changeWorkspace(nextRoot)
        await reopened.operation?.value
        #expect(reopened.workspace.record?.rootURL.path == PathSafety.canonical(nextRoot).path && reopened.presentation.result == nil)
        #expect(reopened.workspace.expandedGroups.isEmpty)
        #expect(reopened.workspace.selection == nil && reopened.workspace.details.collapsedPaths.isEmpty)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try await fixture.service.store.locate(explicit: fixture.root.path, cwd: fixture.root).path == PathSafety.canonical(fixture.root).path)
        #expect(reopened.defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)

        reopened.changeWorkspace(fixture.root)
        await reopened.operation?.value
        #expect(reopened.workspace.record?.rootURL.path == PathSafety.canonical(fixture.root).path && reopened.presentation.result == nil)
        #expect(reopened.workspace.record?.groups["feature"]?.repositoryIDs == ["repo"])
        #expect(reopened.workspace.record?.groups["closed"]?.repositoryIDs == [])
        #expect(reopened.workspace.expandedGroups == ["feature"] && reopened.workspace.selection == .member(groupName: "feature", repositoryID: "repo"))
        #expect(reopened.workspace.details.collapsedPaths == ["Sources"])
        #expect(reopened.workspace.record == saved)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(PathSafety.exists(fixture.service.store.recordURL(nextRoot)))
        #expect(reopened.defaults.string(forKey: "appLanguage") == "zh_CN")
        #expect(reopened.defaults.string(forKey: "tool.Agent") == "codex")
        #expect(try await fixture.service.store.locate(explicit: nil, cwd: fixture.root.appending(path: "worktrees/feature/repo")).path == PathSafety.canonical(fixture.root).path)
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")))
        reopened.workspace.selection = nil
        await reopened.workspace.stopReads()
        let welcome = AppModel(defaults: model.defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())
        #expect(await welcome.start() == false)
        #expect(welcome.workspace.selection == nil)
        await welcome.workspace.stopReads()
    }

    @Test(arguments: ["missing", "invalid"], [false, true])
    func temporaryReadFailurePreservesBrowsingUntilValidationRecovers(_ kind: String, _ implicit: Bool) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        var now = ContinuousClock.now
        let trace = fixture.directory.appending(path: "paused-read-trace")
        let model = try await makeModel(fixture, trace: trace, now: { now })
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.prepareEmptyGroup("feature")
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.selection = .group("feature")
        model.workspace.details.collapsedPaths = ["Sources"]
        await model.workspace.details.detailTask?.value
        await model.workspace.detailPreloadTask?.value
        let recordURL = fixture.service.store.recordURL(fixture.root)
        let original = try Data(contentsOf: recordURL)
        let record = try #require(model.workspace.record)
        let summary = try #require(model.workspace.detail.summary)
        let changes = try #require(model.workspace.detail.changes)
        let expanded = model.workspace.expandedGroups
        do {
            if kind == "missing" { try FileManager.default.removeItem(at: recordURL) }
            else { try Data("invalid".utf8).write(to: recordURL) }

            if implicit { await model.activate() } else { await model.workspace.refreshRecord() }
            await model.workspace.waitForReadCancellation()
            #expect(model.workspace.record == record && model.workspace.selection == .group("feature"))
            #expect(model.workspace.blocked == nil && model.workspace.notice != nil && !model.workspace.canManage)
            #expect(model.workspace.maintenanceState == .ready && !model.workspace.details.hasActiveReads)
            #expect(model.workspace.detail.summary == summary && model.workspace.detail.changes == changes)
            #expect(model.workspace.expandedGroups == expanded && model.workspace.details.collapsedPaths == ["Sources"])
            let saved = try #require(model.defaults.data(forKey: model.workspace.sidebarPreferenceKey("selection")))
            #expect(try JSONDecoder().decode(Resource.self, from: saved) == .group("feature"))

            try Data().write(to: trace)
            try Data("new change".utf8).write(to: record.groupURL("feature").appending(path: "new.txt"))
            model.workspace.selection = nil
            model.workspace.selection = .group("feature")
            model.workspace.refreshDetail(userInitiated: true)
            model.workspace.setVisibleResources([.group("feature")], in: record.root)
            model.workspace.setActive(false)
            model.workspace.setActive(true)
            #expect(!model.workspace.details.hasActiveReads)
            #expect(model.workspace.detail.summary == summary && model.workspace.detail.changes == changes)
            #expect(try Data(contentsOf: trace).isEmpty)

            try original.write(to: recordURL)
            let configURL = fixture.root.appending(path: ".git/config")
            let config = try Data(contentsOf: configURL)
            try Data("[invalid".utf8).write(to: configURL)
            now = now.advanced(by: .seconds(10))
            await model.activate()
            #expect(model.workspace.record == record && !model.workspace.canManage && model.workspace.notice != nil)
            #expect(!model.workspace.details.hasActiveReads)

            try config.write(to: configURL)
            now = now.advanced(by: .seconds(10))
            await model.activate()
            await model.workspace.details.detailTask?.value
            #expect(model.workspace.blocked == nil && model.workspace.notice == nil && model.workspace.noticeDetails == nil)
            #expect(model.workspace.canManage && model.workspace.selection == .group("feature"))
            #expect(model.workspace.expandedGroups == expanded && model.workspace.details.collapsedPaths == ["Sources"])
            #expect(model.workspace.detail.changes?.contains { $0.path == "new.txt" } == true)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func lockedHistoryDoesNotPreventSwitchingAndIsKept() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let history = fixture.directory.appending(path: "history")
        try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(history).path))
        let lease = try fixture.service.store.tryLock(history)
        defer { lease.unlock() }
        let historyRecord = try Data(contentsOf: fixture.service.store.recordURL(history))
        let next = fixture.directory.appending(path: "next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace.record?.rootURL.path == PathSafety.canonical(next).path && model.presentation.result == nil)
        #expect(model.defaults.string(forKey: "workspace") == PathSafety.canonical(next).path)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(history)) == historyRecord)
    }

    @Test(arguments: [true, false])
    func changingWorkspaceCreatesOrLoadsWithoutCLIAndPublishesOnlyWhenReady(_ cancellable: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        let next = fixture.directory.appending(path: "new-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try Data("keep me".utf8).write(to: next.appending(path: "notes.txt"))
        #expect(!PathSafety.exists(model.installer.commandLink))

        #expect(model.changeWorkspace(next, cancellable: cancellable))
        #expect(model.busy && model.openingWorkspace)
        #expect(model.operations.canCancel == cancellable)
        #expect(model.workspace.record == original)
        #expect(model.defaults.string(forKey: "workspace") == original.root)
        let opening = try #require(model.operation)
        if !cancellable {
            model.cancel(); model.cancel()
            let delegate = AppDelegate()
            delegate.model = model
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            #expect(!model.cancelling && !opening.isCancelled && !model.presentation.quitPending)
        }
        model.changeWorkspace(fixture.root)
        await opening.value
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(model.workspace.record?.rootURL.path == PathSafety.canonical(next).path)
        #expect(model.defaults.string(forKey: "workspace") == PathSafety.canonical(next).path)
        #expect(model.workspace.selection == nil && model.presentation.result == nil && model.workspace.notice == nil)
        #expect(PathSafety.exists(next.appending(path: ".git")))
        #expect(PathSafety.exists(next.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")))
        #expect(try String(contentsOf: next.appending(path: "notes.txt"), encoding: .utf8) == "keep me")

        let alias = fixture.directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: next)
        #expect(!model.changeWorkspace(alias, cancellable: false))
        #expect(!model.busy && model.operation == nil)
        model.changeWorkspace(fixture.root)
        #expect(model.operations.canCancel)
        await model.operation?.value
        #expect(model.workspace.record == original && model.presentation.result == nil)
    }

    @Test func invalidLockedAndCancelledChangesKeepTheCurrentWorkspace() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try Task.checkCancellation() })
        let model = try await makeModel(fixture, store: store)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        await model.workspace.maintainWorkspace()
        await model.workspace.detailPreloadTask?.value
        model.workspace.selection = .repository("repo")
        await model.workspace.details.waitForDetail()
        let oldHead = try #require(model.workspace.detail.summary?.headOID)
        let original = try #require(model.workspace.record)
        model.workspace.expandedGroups = ["expanded"]
        let next = fixture.directory.appending(path: "locked")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        let lease = try fixture.service.store.tryLock(next)
        let nested = fixture.root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        for target in [next, nested, fixture.directory.appending(path: "missing")] {
            model.changeWorkspace(target)
            await model.operation?.value
            #expect(model.presentation.result != nil && model.presentation.resultHost == .settings)
            #expect(model.workspace.record == original && model.workspace.selection == .repository("repo"))
            #expect(model.defaults.string(forKey: "workspace") == original.root)
            #expect(model.workspace.detail.summary?.headOID == oldHead && model.workspace.expandedGroups == ["expanded"])
            #expect(!model.busy && !model.openingWorkspace)
            model.presentation.dismissResult()
        }
        lease.unlock()
        model.changeWorkspace(next)
        model.cancel()
        await model.operation?.value
        #expect(model.workspace.record == original && model.workspace.selection == .repository("repo"))
        #expect(model.defaults.string(forKey: "workspace") == original.root)
        #expect(!model.busy && !model.openingWorkspace)
        #expect(model.presentation.result == nil || model.presentation.result?.status == .cancelled)
    }

    @Test func failedInitializationAndFinalLoadKeepOldReferenceAndReportEffects() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        let next = fixture.directory.appending(path: "invalid-ignore")
        try FileManager.default.createDirectory(at: next.appending(path: ".gitignore"), withIntermediateDirectories: true)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace.record == original && model.defaults.string(forKey: "workspace") == original.root)
        #expect(model.presentation.result?.status == .failed)
        #expect(model.presentation.result?.items.flatMap(\.effects).contains { $0.action == "git-init" && $0.state == "applied" } == true)
        #expect(PathSafety.exists(next.appending(path: ".git")))
        model.presentation.dismissResult()

        let invalid = fixture.directory.appending(path: "corrupt-record")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data("broken".utf8).write(to: fixture.service.store.recordURL(invalid))
        do { try await model.switchTo(invalid); Issue.record("Expected invalid workspace to be rejected") }
        catch { #expect((error as? MonoDeckError)?.code == "invalid-workspace-record") }
        #expect(model.workspace.record == original && model.defaults.string(forKey: "workspace") == original.root)
    }

    @Test func skillConflictDoesNotBlockSwitchOrOverwriteUserFile() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let next = fixture.directory.appending(path: "skill-conflict")
        let skill = next.appending(path: ".agents/skills/mono-deck-workflow")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: skill)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace.record?.rootURL.path == PathSafety.canonical(next).path)
        #expect(model.workspace.notice != nil && model.presentation.result == nil && !model.busy)
        #expect(try String(contentsOf: skill, encoding: .utf8) == "user skill")
        model.workspace.notice = nil
        #expect(model.workspace.notice == nil)
    }

    @Test func switchingWorkspacesWhileLoadingKeepsTheNewWorkspace() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        var original = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        original.groups["feature"] = WorktreeGroup()
        try FileManager.default.createDirectory(at: original.groupURL("feature"), withIntermediateDirectories: true)
        try fixture.service.store.save(original)
        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(nextRoot).status == .success)
        let next = try await fixture.service.load(nextRoot)
        let suite = "MonoDeckLoadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(original.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)

        let first = Task { await model.workspace.maintainWorkspace() }
        do {
            try await waitForReadLock(fixture)
            try await model.switchTo(nextRoot)
            await first.value
        } catch {
            first.cancel()
            await model.workspace.stopReads()
            await first.value
            throw error
        }

        #expect(model.workspace.record == next)
        #expect(model.workspace.blocked == nil)
        await model.workspace.stopReads()
    }

    @Test(arguments: [false, true])
    func lockTimeoutReportsAnErrorAndKeepsTheCurrentWorkspace(_ alreadyLoaded: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try Task.checkCancellation() })
        let model = try await makeModel(fixture, store: store)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = try #require(model.workspace.record)
        if !alreadyLoaded { model.workspace.record = nil }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        await model.workspace.maintainWorkspace()
        #expect(!model.busy && model.hasSavedWorkspace)
        #expect(model.workspace.record == (alreadyLoaded ? record : nil))
        if alreadyLoaded {
            #expect(model.workspace.blocked == nil && model.workspace.notice != nil && !model.workspace.canManage)
        } else {
            #expect(model.workspace.blocked != nil && model.workspace.blockedDetails?.contains("10 retries") == true)
        }
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        lease.unlock()

        await model.workspace.maintainWorkspace()
        #expect(model.workspace.record == record && model.workspace.blocked == nil)
        try FileManager.default.removeItem(at: fixture.service.store.recordURL(fixture.root))
        await model.workspace.maintainWorkspace()
        #expect(model.workspace.record == record && model.workspace.maintenanceState == .failed && !model.workspace.canManage)
    }

    @Test func reloadingWhileWaitingForTheLockIgnoresCancellationAndDefersQuit() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = model.workspace.record
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let refresh = Task { await model.workspace.maintainWorkspace() }
        do {
            try await waitForWorkspaceOperation(model)
            let operation = try #require(model.operation)
            #expect(!model.operations.canCancel)
            model.cancel()
            let delegate = AppDelegate()
            delegate.model = model
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            await Task.yield()
            #expect(model.busy && model.openingWorkspace && !model.cancelling && !operation.isCancelled)
            #expect(model.presentation.quitPending)
            model.presentation.quitPending = false
            lease.unlock()
            await refresh.value
            await model.workspace.detailPreloadTask?.value
        } catch {
            model.presentation.quitPending = false
            lease.unlock()
            await refresh.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
        #expect(!model.busy && model.operation == nil)
        #expect(model.workspace.record == record && model.workspace.blocked == nil)
        #expect(model.presentation.result == nil && model.presentation.message == nil)
    }

    private func waitForWorkspaceOperation(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(model.busy && model.openingWorkspace)
    }

    private func makeModel(_ fixture: Fixture, trace: URL? = nil, store: WorkspaceStore? = nil,
                           now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) async throws -> AppModel {
        if !PathSafety.exists(fixture.service.store.recordURL(fixture.root)) { try await fixture.prepareWorkspace() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        var git = fixture.service.git
        if let trace { git.runner.environment["GIT_TRACE"] = trace.path }
        let service = WorkspaceService(store: store ?? fixture.service.store, git: git, trash: fixture.service.trashDirectory)
        let model = AppModel(defaults: defaults, service: service, now: now)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        defaults.set(model.workspace.record?.root, forKey: "workspace")
        return model
    }

    private func waitForReadLock(_ fixture: Fixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            do { let lease = try fixture.service.store.tryLock(fixture.root); lease.unlock() }
            catch let error as MonoDeckError where error.code == "workspace-busy" { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw MonoDeckError("test-timeout", "Workspace reload did not acquire its read lock.")
    }

    private func waitUntil(diagnostics: @autoclosure () -> String = "", sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(diagnostics())", sourceLocation: sourceLocation)
    }
}

private actor WorkspaceLockRetryGate {
    private var started = false
    private var released = false

    func wait() async throws {
        started = true
        while !released { try await Task.sleep(for: .milliseconds(1)) }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(started)
    }

    func release() { released = true }
}

@MainActor struct ReloadValidationGate {
    private let config: URL
    private let original: Data
    private var writer: Int32 = -1
    private var restored = false

    init(_ root: URL) throws {
        config = root.appending(path: ".git/config")
        original = try Data(contentsOf: config)
        try FileManager.default.removeItem(at: config)
        guard mkfifo(config.path, 0o600) == 0 else {
            try original.write(to: config, options: .atomic)
            throw MonoDeckError("test-gate", "Could not pause Git repository validation.")
        }
    }

    mutating func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !connectIfStarted(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(connectIfStarted())
    }

    mutating func connectIfStarted() -> Bool {
        if writer < 0 { writer = Darwin.open(config.path, O_WRONLY | O_NONBLOCK) }
        return writer >= 0
    }

    mutating func resume() throws {
        guard !restored else { return }
        if writer < 0 { writer = Darwin.open(config.path, O_RDWR | O_NONBLOCK) }
        defer {
            if writer >= 0 { close(writer) }
            writer = -1
        }
        try FileManager.default.removeItem(at: config)
        try original.write(to: config, options: .atomic)
        restored = true
        if writer >= 0 {
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)
            let written = original.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
            // Cancellation may already have terminated the blocked Git reader.
            if written < 0, errno == EPIPE { return }
            guard written == original.count else { throw MonoDeckError("test-gate", "Could not resume Git repository validation.") }
        }
    }
}

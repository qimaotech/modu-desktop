import Foundation
import Darwin
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct RepositoryRefreshTests {
    @Test(arguments: [false, true])
    func cancelledBackgroundScanDrainsBeforeStopOrWrites(_ startsWrite: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        var record = try f.service.store.load(f.root)
        for name in ["slow", "cached"] {
            let repository = Repository(url: "https://modu-test.invalid/\(name).git")
            try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL(name))
            _ = try await f.service.git.run(["config", "remote.origin.url", repository.url], at: record.repositoryURL(name))
            record.repositories.append(repository)
        }
        try f.service.store.save(record)
        let cachedFile = record.repositoryURL("cached").appending(path: "pending.txt")
        try Data("before cancellation".utf8).write(to: cachedFile)
        let probe = f.directory.appending(path: "preload-drain-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let hook = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        printf 'read\\n' >> "$MODU_PRELOAD_DRAIN_PROBE/reads"
        finish() {
            trap '' TERM INT
            : > "$MODU_PRELOAD_DRAIN_PROBE/cancelling"
            while [ ! -e "$MODU_PRELOAD_DRAIN_PROBE/release" ]; do sleep 0.02; done
            : > "$MODU_PRELOAD_DRAIN_PROBE/finished"
            exit 143
        }
        trap finish TERM INT
        echo $$ > "$MODU_PRELOAD_DRAIN_PROBE/pid"
        : > "$MODU_PRELOAD_DRAIN_PROBE/started"
        while [ ! -e "$MODU_PRELOAD_DRAIN_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for arguments in [["config", "core.fsmonitor", hook.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await f.service.git.run(arguments, at: record.repositoryURL("slow"))
        }
        var runner = f.service.git.runner
        runner.environment["MODU_PRELOAD_DRAIN_PROBE"] = probe.path
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: service)
        model.workspace.record = record
        model.workspace.details.cache(.init(resource: .repository("slow"), available: true, dirty: false))
        model.workspace.details.cache(.init(resource: .repository("cached"), available: true, dirty: false))
        let state = DrainWaitState()
        var background: Task<Void, Never>?
        var waiting: Task<Void, Never>?
        var operation: Task<Void, Never>?
        do {
            model.workspace.selection = .repository("repo")
            try await eventually { !model.workspace.detailLoading }
            model.workspace.details.invalidate(resources: [.repository("slow"), .repository("cached")])
            model.workspace.setVisibleResources(Set(service.resources(record)), in: record.root)
            let scanning = try #require(model.workspace.detailPreloadTask)
            background = scanning
            try await eventually {
                PathSafety.exists(probe.appending(path: "started")) && model.workspace.state(for: .repository("cached"))?.dirty == true
            }
            let pidText = try String(contentsOf: probe.appending(path: "pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let helperPID = try #require(Int32(pidText))
            try Data("foreground".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
            model.workspace.refreshDetail()
            try await eventually { PathSafety.exists(probe.appending(path: "cancelling")) }
            try await eventually { model.workspace.detail.changes?.map(\.path) == ["new.txt"] }
            #expect(background?.isCancelled == true && model.workspace.detailPreloadTask == nil)
            #expect(model.workspace.state(for: .repository("slow"))?.dirty == false)
            try Data("latest".utf8).write(to: record.repositoryURL("slow").appending(path: "late.txt"))
            try FileManager.default.removeItem(at: cachedFile)
            model.workspace.cancelDetailPreload()
            model.workspace.cancelDetailPreload()
            model.workspace.details.invalidate(resources: [.repository("slow"), .repository("cached")])
            model.workspace.startDetailPreload()
            #expect(model.workspace.detailPreloadTask == nil)
            #expect(try String(contentsOf: probe.appending(path: "reads"), encoding: .utf8).split(separator: "\n").count == 1)

            if startsWrite {
                model.management.run { _, root, _ in
                    await MainActor.run {
                        state.writeStarted = true
                        state.writeStartedAfterCleanup = PathSafety.exists(probe.appending(path: "finished")) && kill(helperPID, 0) != 0
                    }
                    return OperationResult(command: "repo.update", workspace: root.path, status: .success)
                }
                let writing = try #require(model.operation)
                operation = writing
                try await Task.sleep(for: .milliseconds(50))
                #expect(model.busy && !state.writeStarted)
            } else {
                waiting = Task {
                    state.waitingStarted = true
                    await model.workspace.stopReads()
                    state.completed = true
                }
                try await eventually { state.waitingStarted }
                #expect(!state.completed && model.workspace.details.hasActiveReads)
            }
            #expect(kill(helperPID, 0) == 0 && !PathSafety.exists(probe.appending(path: "finished")))
            try Data().write(to: probe.appending(path: "release"))
            await background?.value
            await waiting?.value
            await operation?.value
            #expect(PathSafety.exists(probe.appending(path: "finished")) && kill(helperPID, 0) != 0)
            if startsWrite { #expect(state.writeStarted && state.writeStartedAfterCleanup) }
            else {
                #expect(state.completed && !model.workspace.details.hasActiveReads)
                model.workspace.resumeAfterFailedQuit()
            }
            try await eventually {
                model.workspace.state(for: .repository("slow"))?.dirty == true && model.workspace.state(for: .repository("cached"))?.dirty == false
            }
            await model.workspace.stopReads()
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await background?.value
            await waiting?.value
            await operation?.value
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func detailsPublishTogetherAfterBothHistoryReads(_ blocksAhead: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let path = record.repositoryURL("repo")
        let base = try #require(await f.service.git.oid("HEAD", at: path))
        _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "first"], at: path)
        let first = try #require(await f.service.git.oid("HEAD", at: path))
        let gate = HistoryReadGate(git: f.service.git)
        gate.blockedHead = blocksAhead ? first : base
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let details = RepositoryDetailModel(service: f.service, defaults: defaults, monitor: TestResourceMonitor(), readCommits: { path, head, base in
            try await gate.read(at: path, head: head, base: base)
        })
        details.cache(.init(resource: resource, available: true, dirty: false))
        details.refresh(resource, in: record)
        do {
            try await eventually { gate.started.contains(gate.blockedHead!) && gate.completed.contains(blocksAhead ? base : first) }
            #expect(details.detail.changes == nil && details.detail.summary == nil)
            #expect(details.detail.commits == nil && details.detail.behindCommits == nil && details.detailLoading)
            gate.blockedHead = nil
            try await settle(details)
            #expect(details.detail.changes?.isEmpty == true && details.detail.summary?.headOID == first)
            #expect(details.detail.commits?.map(\.subject) == ["first"] && details.detail.behindCommits?.isEmpty == true)

            _ = try await f.service.git.run(["checkout", "-b", "feature"], at: path)
            _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "second"], at: path)
            let second = try #require(await f.service.git.oid("HEAD", at: path))
            try Data("edit".utf8).write(to: path.appending(path: "new.txt"))
            gate.started = []; gate.completed = []
            gate.blockedHead = blocksAhead ? second : base
            var idleNotified = false
            details.onIdle = { idleNotified = true }
            details.request(.structure)
            let reading = try #require(details.detailTask)
            try await eventually { gate.started.contains(gate.blockedHead!) && gate.completed.contains(blocksAhead ? base : second) }
            #expect(!idleNotified && !details.snapshotLoading && details.detailLoading)
            #expect(details.detail.changes?.isEmpty == true && details.detail.summary?.head == "main")
            #expect(details.detail.summary?.headOID == first && details.detail.commits?.map(\.subject) == ["first"])
            try Data("during history".utf8).write(to: path.appending(path: "last.txt"))
            details.request(.workingTree)
            #expect(!reading.isCancelled)
            gate.blockedHead = nil
            await reading.value
            try await settle(details)
            #expect(idleNotified)
            #expect(details.detail.changes?.map(\.path) == ["last.txt", "new.txt"])
            #expect(details.detail.summary?.head == "feature" && details.detail.summary?.headOID == second)
            #expect(details.detail.commits?.map(\.subject) == ["second", "first"] && details.detail.behindCommits?.isEmpty == true)
            details.stop(); await details.waitForReads()
        } catch {
            gate.blockedHead = nil
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func cancelledHistoryCannotPublishPartialDetailsOrErrors(_ switchesSelection: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let path = record.repositoryURL("repo")
        let head = try #require(await f.service.git.oid("HEAD", at: path))
        let gate = HistoryReadGate(git: f.service.git)
        gate.blockedHead = head
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let details = RepositoryDetailModel(service: f.service, defaults: defaults, monitor: TestResourceMonitor(), readCommits: { path, head, base in
            try await gate.read(at: path, head: head, base: base)
        })
        details.refresh(resource, in: record)
        do {
            try await eventually { gate.started.contains(head) }
            let reading = try #require(details.detailTask)
            var waiterFinished = false
            let waiter = Task { await details.waitForDetail(); waiterFinished = true }
            await Task.yield()
            waiter.cancel()
            try await eventually { waiterFinished }
            await waiter.value
            #expect(!reading.isCancelled && details.detailLoading)
            if switchesSelection { details.refresh(nil, in: record) }
            else { details.pause(); await details.waitForReads() }
            await reading.value
            #expect(reading.isCancelled && !details.detailLoading && details.pendingFailure == nil)
            #expect(details.detail.changes == nil && details.detail.summary == nil && details.detail.commits == nil)
            gate.blockedHead = nil
            if switchesSelection { details.refresh(resource, in: record) }
            else { details.resume() }
            try await settle(details)
            #expect(details.detail.summary?.headOID == head && details.detail.changes?.isEmpty == true)
            #expect(details.detail.commits?.isEmpty == true && details.detail.behindCommits?.isEmpty == true)
            details.stop(); await details.waitForReads()
        } catch {
            gate.blockedHead = nil
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func activationRefreshesSelectionWithoutWaitingForBackgroundInspection() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        var record = try f.service.store.load(f.root)
        let slow = Repository(url: "https://modu-test.invalid/slow.git")
        try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL("slow"))
        _ = try await f.service.git.run(["config", "remote.origin.url", slow.url], at: record.repositoryURL("slow"))
        record.repositories.append(slow); try f.service.store.save(record)
        let probe = f.directory.appending(path: "activation-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let hook = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_ACTIVATION_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_ACTIVATION_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for arguments in [["config", "core.fsmonitor", hook.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await f.service.git.run(arguments, at: record.repositoryURL("slow"))
        }
        var runner = f.service.git.runner
        runner.environment["MODU_ACTIVATION_PROBE"] = probe.path
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: service, toolService: ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in }))
        model.workspace.record = record
        model.workspace.details.cache(.init(resource: .repository("slow"), available: true, dirty: false))
        model.workspace.selection = .repository("repo")
        do {
            try await eventually { !model.workspace.details.snapshotLoading }
            model.workspace.details.invalidate(resources: [.repository("slow")])
            model.workspace.setVisibleResources(Set(service.resources(record)), in: record.root)
            try await eventually { PathSafety.exists(probe.appending(path: "started")) }
            try Data("background".utf8).write(to: record.repositoryURL("slow").appending(path: "slow.txt"))
            try Data("latest".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
            await model.activate()
            try await eventually { model.workspace.detail.changes?.map(\.path) == ["new.txt"] }
            #expect(!PathSafety.exists(probe.appending(path: "release")))
            let operation = try #require(model.operations.begin(.management))
            try Data("while busy".utf8).write(to: record.repositoryURL("repo").appending(path: "busy.txt"))
            await model.activate()
            #expect(model.workspace.details.detailTask == nil)
            model.operations.finish(operation)
            try await eventually { model.workspace.detail.changes?.map(\.path) == ["busy.txt", "new.txt"] }
            try Data().write(to: probe.appending(path: "release"))
            try await eventually { model.workspace.state(for: .repository("slow"))?.dirty == true }
            await model.workspace.stopReads()
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func changesDuringReadAreCoalescedWithoutCancellingTheRunningRead() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        try await f.prepareEmptyGroup("feature")
        let record = try f.service.store.load(f.root)
        let probe = f.directory.appending(path: "refresh-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = f.service.git.runner
        runner.environment["MODU_REFRESH_PROBE"] = probe.path
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let monitor = TestResourceMonitor()
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let details = RepositoryDetailModel(service: service, defaults: defaults, monitor: monitor)
        details.refresh(.group("feature"), in: record)
        try await settle(details)
        let hook = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        printf 'read\\n' >> "$MODU_REFRESH_PROBE/reads"
        : > "$MODU_REFRESH_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_REFRESH_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for arguments in [["config", "core.fsmonitor", hook.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await service.git.run(arguments, at: record.rootURL)
        }
        details.request(.structure)
        let reading = try #require(details.detailTask)
        do {
            try await eventually { PathSafety.exists(probe.appending(path: "started")) }
            try Data("latest".utf8).write(to: record.groupURL("feature").appending(path: "new.txt"))
            for _ in 0..<10 { monitor.emit(.workingTree) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(!reading.isCancelled)
            try Data().write(to: probe.appending(path: "release"))
            await reading.value
            try await settle(details)
            #expect(details.detail.changes?.map(\.path) == ["new.txt"])
            let reads = try String(contentsOf: probe.appending(path: "reads"), encoding: .utf8).split(separator: "\n")
            #expect(reads.count == 2)
            details.stop(); await details.waitForReads()
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func inactiveChangesWaitForActivationAndBusyChangesResume() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        try await f.prepareEmptyGroup("feature")
        let record = try f.service.store.load(f.root)
        let monitor = TestResourceMonitor()
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let details = RepositoryDetailModel(service: f.service, defaults: defaults, monitor: monitor)
        details.refresh(.group("feature"), in: record)
        try await settle(details)
        details.setActive(false)
        try Data("edit".utf8).write(to: record.groupURL("feature").appending(path: "new.txt"))
        monitor.emit(.workingTree)
        try await Task.sleep(for: .milliseconds(200))
        #expect(details.detailTask == nil && details.detail.changes?.isEmpty == true)
        details.setActive(true)
        try await settle(details)
        #expect(details.detail.changes?.map(\.path) == ["new.txt"])
        details.pause(); await details.waitForReads()
        try Data("busy".utf8).write(to: record.groupURL("feature").appending(path: "busy.txt"))
        details.refresh(.group("feature"), in: record)
        #expect(details.detailTask == nil)
        details.resume()
        try await settle(details)
        #expect(details.detail.changes?.map(\.path) == ["busy.txt", "new.txt"])
        let lateCallback = monitor.currentCallback
        details.stop(); await details.waitForReads()
        lateCallback?(.init(change: .structure))
        await Task.yield()
        #expect(details.detailTask == nil)
    }

    @Test func nativeMonitorDeliversWorktreeAndSharedReferenceChangesAndStops() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        try await f.prepareEmptyGroup("feature")
        let record = try f.service.store.load(f.root)
        let context = try await f.service.prepareResourceRead(.group("feature"), in: record)
        let monitor = ResourceChangeMonitor()
        defer { monitor.stop() }
        let received = MonitorEvents()
        #expect(monitor.start(context, excludedDirectories: []) { event in
            Task { @MainActor in received.values.append(event) }
        })
        try Data("edit".utf8).write(to: context.path.appending(path: "new.txt"))
        try await eventually { !received.values.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        received.values = []
        try FileManager.default.removeItem(at: context.path.appending(path: "new.txt"))
        try await eventually { received.values.contains { $0.change.contains(.workingTree) } }
        received.values = []
        _ = try await f.service.git.run(["update-ref", "refs/remotes/origin/main", "HEAD"], at: context.path)
        try await eventually { received.values.contains { $0.change.contains(.summary) } }
        monitor.stop()
        try await Task.sleep(for: .milliseconds(200))
        let count = received.values.count
        try Data("after stop".utf8).write(to: context.path.appending(path: "after.txt"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.values.count == count)
    }

    @Test func nativeMonitorIgnoresSubmoduleContentsAndKeepsParentStructureEvents() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let path = record.repositoryURL("repo")
        _ = try await f.service.git.run(["submodule", "add", f.remoteURL, "sub"], at: path)
        _ = try await f.service.git.run(["commit", "-m", "add submodule"], at: path)
        let context = try await f.service.prepareResourceRead(.repository("repo"), in: record, visibility: .application)
        #expect(context.submoduleDirectories == [path.appending(path: "sub")])
        let monitor = ResourceChangeMonitor()
        defer { monitor.stop() }
        let received = MonitorEvents()
        #expect(monitor.start(context) { event in
            Task { @MainActor in received.values.append(event) }
        })
        try Data("control".utf8).write(to: path.appending(path: "control.txt"))
        try await eventually { !received.values.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        received.values = []
        try Data("changed".utf8).write(to: path.appending(path: "sub/README"))
        try Data("new".utf8).write(to: path.appending(path: "sub/new.txt"))
        _ = try await f.service.git.run(["add", "README"], at: path.appending(path: "sub"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(received.values.isEmpty)

        var modules = try Data(contentsOf: path.appending(path: ".gitmodules"))
        modules.append(Data("\n".utf8))
        try modules.write(to: path.appending(path: ".gitmodules"))
        try await eventually { received.values.contains { $0.change.contains([.index, .workingTree]) } }
        try await Task.sleep(for: .milliseconds(300))
        received.values = []
        _ = try await f.service.git.run(["add", ".gitmodules"], at: path)
        try await eventually { received.values.contains { $0.change.contains(.index) } }
        try await Task.sleep(for: .milliseconds(300))
        received.values = []
        _ = try await f.service.git.run(["init", "nested"], at: path)
        try await eventually { !received.values.isEmpty }
    }

    @Test func staleSubmoduleContextDoesNotHideFilesAfterIndexTypeConversion() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let path = record.repositoryURL("repo")
        _ = try await f.service.git.run(["submodule", "add", f.remoteURL, "sub"], at: path)
        _ = try await f.service.git.run(["commit", "-m", "add submodule"], at: path)
        let context = try await f.service.prepareResourceRead(.repository("repo"), in: record, visibility: .application)
        #expect(context.submoduleDirectories == [path.appending(path: "sub")])
        _ = try await f.service.git.run(["rm", "--cached", "sub"], at: path)
        try FileManager.default.removeItem(at: path.appending(path: "sub/.git"))
        _ = try await f.service.git.run(["add", "sub"], at: path)
        #expect(context.isValid(in: record) && context.submoduleDirectories.isEmpty)
        let monitor = ResourceChangeMonitor()
        defer { monitor.stop() }
        let received = MonitorEvents()
        #expect(monitor.start(context) { event in
            Task { @MainActor in received.values.append(event) }
        })
        try Data("now a parent file".utf8).write(to: path.appending(path: "sub/README"))
        try await eventually { received.values.contains { $0.change.contains(.workingTree) || $0.candidatePaths.contains("sub/README") } }
    }

    @Test func indexChangesRebuildSubmoduleExclusionsWithoutHidingNestedRepositories() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let path = record.repositoryURL("repo")
        let monitor = TestResourceMonitor()
        let defaults = UserDefaults(suiteName: f.directory.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let details = RepositoryDetailModel(service: f.service, defaults: defaults, monitor: monitor)
        details.refresh(resource, in: record)
        do {
            try await settle(details)
            #expect(monitor.submoduleDirectories.isEmpty)
            _ = try await f.service.git.run(["submodule", "add", f.remoteURL, "sub"], at: path)
            monitor.emit(.structure)
            try await eventually { monitor.submoduleDirectories == [path.appending(path: "sub")] && !details.detailLoading }
            #expect(details.detail.changes?.map(\.path) == [".gitmodules"])
            _ = try await f.service.git.run(["rm", "--cached", "sub"], at: path)
            monitor.emit(.structure)
            try await eventually { monitor.submoduleDirectories.isEmpty && !details.detailLoading }
            #expect(details.detail.changes?.contains { $0.path == "sub/" } == true)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    private func settle(_ details: RepositoryDetailModel) async throws {
        try await eventually { !details.detailLoading && details.detailTask == nil }
    }
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

@MainActor private final class MonitorEvents { var values: [ResourceChangeEvent] = [] }

@MainActor private final class DrainWaitState {
    var waitingStarted = false
    var completed = false
    var writeStarted = false
    var writeStartedAfterCleanup = false
}

@MainActor private final class HistoryReadGate {
    let git: Git
    var blockedHead: String?
    var started = Set<String>()
    var completed = Set<String>()
    init(git: Git) { self.git = git }
    func read(at path: URL, head: String, base: String) async throws -> [GitCommit] {
        started.insert(head)
        while blockedHead == head { try await Task.sleep(for: .milliseconds(10)) }
        let commits = try await git.commits(at: path, head: head, base: base, limit: nil)
        completed.insert(head)
        return commits
    }
}

private final class TestResourceMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (ResourceChangeEvent) -> Void)?
    private var directories: [URL] = []
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool {
        lock.withLock { callback = onChange; directories = context.submoduleDirectories }
        return true
    }
    func stop() { lock.withLock { callback = nil } }
    var currentCallback: (@Sendable (ResourceChangeEvent) -> Void)? { lock.withLock { callback } }
    var submoduleDirectories: [URL] { lock.withLock { directories } }
    func emit(_ event: ResourceChange) { lock.withLock { callback }?(.init(change: event)) }
}

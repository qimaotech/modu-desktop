import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct WorkspaceSyncTests {
    @Test func recordEventsApplyChangesWithoutRewritingOrRefreshingUnrelatedDetails() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        try await fixture.prepareEmptyGroup("current")
        let monitor = WorkspaceRecordMonitorStub()
        let trace = fixture.directory.appending(path: "record-events-trace")
        let model = try makeModel(fixture, monitor: monitor, trace: trace)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        model.workspace.selection = .group("current")
        do {
            try await eventually { !model.workspace.detailLoading && model.workspace.detail.summary != nil }
            let previous = model.workspace.detail.summary?.headOID
            var changed = try fixture.service.store.load(fixture.root)
            changed.groups["external"] = WorktreeGroup()
            try fixture.service.store.save(changed)
            let file = fixture.service.store.recordURL(fixture.root)
            let bytes = try Data(contentsOf: file)
            try Data().write(to: trace)
            for _ in 0..<8 { monitor.emit() }
            try await eventually { model.workspace.record == changed }
            try await Task.sleep(for: .milliseconds(250))
            #expect(model.workspace.detail.summary?.headOID == previous)
            #expect(!model.busy && model.workspace.blocked == nil)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(commandCount("status ", in: trace) == 0)
            #expect(commandCount("rev-parse --show-toplevel", in: trace) == 1)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func recordEventsWaitForForegroundAndIdle(_ busy: Bool) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let monitor = WorkspaceRecordMonitorStub()
        let model = try makeModel(fixture, monitor: monitor)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        let operation = busy ? model.operations.begin(.management) : nil
        if busy { #expect(operation != nil) }
        if !busy { model.workspace.setActive(false) }
        var changed = original
        changed.groups["external"] = WorktreeGroup()
        do {
            try fixture.service.store.save(changed)
            monitor.emit()
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.workspace.record == original)
            if let operation { model.operations.finish(operation) }
            else { await model.activate() }
            try await eventually { model.workspace.record == changed }
            #expect(!model.busy && model.workspace.blocked == nil)
            await model.workspace.stopReads()
        } catch {
            if let operation { model.operations.finish(operation) }
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func cancelledDebounceCannotClearItsReplacementAfterTheDelayCompletes() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let monitor = WorkspaceRecordMonitorStub()
        let delay = WorkspaceRecordDebounceGate()
        let model = try makeModel(fixture, monitor: monitor, waitForRecordDebounce: { _ in await delay.wait() })
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        var latest = original
        latest.groups["external"] = WorktreeGroup()
        do {
            try fixture.service.store.save(latest)
            monitor.emit()
            try await eventually { delay.count == 1 }
            model.workspace.record = original
            #expect(monitor.starts == 1)
            monitor.emit()
            try await eventually { delay.count == 2 }

            // A successful delay may resume after a newer event has already cancelled its task.
            delay.resume(0)
            try await eventually { delay.completed == 1 }
            model.workspace.record = original
            #expect(monitor.starts == 1)

            delay.resume(1)
            try await eventually { model.workspace.record == latest }
            #expect(!model.busy && model.workspace.blocked == nil)
            await model.workspace.stopReads()
        } catch {
            delay.resumeAll()
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func oldRecordCallbacksCannotReloadAfterWorkspaceSwitchOrStop() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        let nextRecord = try fixture.service.store.load(next)
        let monitor = WorkspaceRecordMonitorStub()
        let model = try makeModel(fixture, monitor: monitor)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let oldCallback = try #require(monitor.callback)
        do {
            try await model.switchTo(next, loaded: nextRecord)
            #expect(monitor.recordURL == fixture.service.store.recordURL(next))
            var changed = nextRecord
            changed.groups["external"] = WorktreeGroup()
            try fixture.service.store.save(changed)
            oldCallback()
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.workspace.record == nextRecord)
            monitor.emit()
            try await eventually { model.workspace.record == changed }
            let stoppedCallback = try #require(monitor.callback)
            await model.workspace.stopReads()
            var afterStop = changed
            afterStop.groups["after-stop"] = WorktreeGroup()
            try fixture.service.store.save(afterStop)
            stoppedCallback()
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.workspace.record == changed)
            #expect(!model.workspace.needsReadTermination)
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func activationDoesNotReadDetailsAgainAfterUnchangedRecordLoads() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        let monitor = WorkspaceRecordMonitorStub()
        let trace = fixture.directory.appending(path: "activation-once-trace")
        let model = try makeModel(fixture, monitor: monitor, trace: trace)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        model.workspace.selection = .repository("repo")
        model.workspace.setVisibleResources([.repository("repo")], in: try #require(model.workspace.record?.root))
        do {
            try await eventually { !model.workspace.detailLoading && model.workspace.detail.summary != nil }
            model.workspace.setActive(false)
            try Data("latest".utf8).write(to: fixture.root.appending(path: "repositories/repo/latest.txt"))
            try await Task.sleep(for: .milliseconds(250))
            try Data().write(to: trace)
            await model.activate()
            try await eventually { !model.workspace.detailLoading && model.workspace.detail.changes?.map(\.path) == ["latest.txt"] }
            #expect(commandCount("status ", in: trace) == 1)
            #expect(commandCount("rev-parse --show-toplevel", in: trace) == 0)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func activationAndExpansionCheckVisibleRowsWithoutAnIdleTimer() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        for name in ["visible", "folded"] { try await fixture.prepareEmptyGroup(name) }
        let clock = WorkspaceSyncClock()
        let monitor = WorkspaceRecordMonitorStub()
        let model = try makeModel(fixture, monitor: monitor, now: { clock.now })
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let visible = Resource.group("visible"), folded = Resource.group("folded")
        let root = try #require(model.workspace.record)
        do {
            model.workspace.setVisibleResources([visible], in: root.root)
            try await eventually { model.workspace.state(for: visible)?.dirty == false }
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.state(for: folded) == nil)
            let visibleFile = root.groupURL("visible").appending(path: "new.txt")
            try Data("visible change".utf8).write(to: visibleFile)
            try Data("folded change".utf8).write(to: root.groupURL("folded").appending(path: "new.txt"))
            clock.now = clock.now.advanced(by: .seconds(31))
            model.workspace.startDetailPreload()
            #expect(model.workspace.detailPreloadTask == nil && model.workspace.state(for: visible)?.dirty == false)
            await model.activate()
            try await eventually { model.workspace.state(for: visible)?.dirty == true }
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.state(for: folded) == nil)
            model.workspace.setVisibleResources([folded], in: root.root)
            try await eventually { model.workspace.state(for: folded)?.dirty == true }
            await model.workspace.detailPreloadTask?.value
            try FileManager.default.removeItem(at: visibleFile)
            clock.now = clock.now.advanced(by: .seconds(31))
            model.workspace.startDetailPreload()
            #expect(model.workspace.detailPreloadTask == nil)
            #expect(model.workspace.state(for: visible)?.dirty == true)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func repeatedActivationJoinsAnInFlightSidebarCheck() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        try await fixture.prepareEmptyGroup("slow")
        let record = try fixture.service.store.load(fixture.root)
        let started = fixture.directory.appending(path: "sidebar-started")
        let release = fixture.directory.appending(path: "sidebar-release")
        let hook = fixture.directory.appending(path: "sidebar-fsmonitor")
        try Data("""
        #!/bin/sh
        : > "\(started.path)"
        trap 'exit 143' TERM INT
        while [ ! -e "\(release.path)" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for arguments in [["config", "core.fsmonitor", hook.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: record.groupURL("slow"))
        }
        let trace = fixture.directory.appending(path: "sidebar-join-trace")
        let model = try makeModel(fixture, monitor: WorkspaceRecordMonitorStub(), trace: trace)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        model.workspace.setVisibleResources([.group("slow")], in: record.root)
        do {
            try await eventually { PathSafety.exists(started) }
            let checking = try #require(model.workspace.detailPreloadTask)
            await model.activate()
            await model.activate()
            #expect(!checking.isCancelled)
            #expect(commandCount("status ", in: trace) == 1)
            try Data().write(to: release)
            await checking.value
            #expect(model.workspace.state(for: .group("slow"))?.available == true)
            #expect(commandCount("status ", in: trace) == 1)
            await model.workspace.stopReads()
        } catch {
            try? Data().write(to: release)
            await model.workspace.stopReads()
            throw error
        }
    }

    private func makeModel(_ fixture: Fixture, monitor: WorkspaceRecordMonitorStub, trace: URL? = nil,
                           now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                           waitForRecordDebounce: (@MainActor (ContinuousClock.Instant) async throws -> Void)? = nil) throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        var git = fixture.service.git
        if let trace { git.runner.environment["GIT_TRACE"] = trace.path }
        let service = WorkspaceService(store: fixture.service.store, git: git, trash: fixture.service.trashDirectory)
        let model = AppModel(defaults: defaults, service: service,
                             toolService: ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in }),
                             recordMonitor: monitor, now: now, waitForRecordDebounce: waitForRecordDebounce)
        let record = try fixture.service.store.load(fixture.root)
        defaults.set(record.root, forKey: "workspace")
        model.workspace.record = record
        model.workspace.setVisibleResources([], in: record.root)
        return model
    }

    private func commandCount(_ command: String, in trace: URL) -> Int {
        let text = (try? String(contentsOf: trace, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n").filter { $0.contains("built-in: git " + command) }.count
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

@MainActor private final class WorkspaceSyncClock {
    var now = ContinuousClock.now
}

@MainActor private final class WorkspaceRecordDebounceGate {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    var count: Int { continuations.count }
    private(set) var completed = 0

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
        completed += 1
    }

    func resume(_ index: Int) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume()
    }

    func resumeAll() {
        for index in continuations.indices { resume(index) }
    }
}

private final class WorkspaceRecordMonitorStub: WorkspaceRecordChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var url: URL?
    private var startCount = 0

    var callback: (@Sendable () -> Void)? { lock.withLock { handler } }
    var recordURL: URL? { lock.withLock { url } }
    var starts: Int { lock.withLock { startCount } }

    func start(_ recordURL: URL, onChange: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock { url = recordURL; handler = onChange; startCount += 1 }
        return true
    }

    func stop() { lock.withLock { handler = nil; url = nil } }
    func emit() { callback?() }
}

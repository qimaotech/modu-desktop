import Foundation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct RepositoryReadSchedulingTests {
    @Test func completePreloadsHaveTheirOwnExpansionFreshnessAndActivationDoesNotEnqueueThem() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        try await fixture.prepareEmptyGroup("cached")
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let clock = RepositoryReadClock(), counts = SchedulingReadCounts()
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: SchedulingResourceMonitor(),
                                           now: { clock.now }, diagnostics: counts.diagnostics)
        let resource = Resource.group("cached")
        do {
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            details.drainPreload()
            await details.snapshotPreloadTask?.value
            #expect(counts.count("detail.preload.read") == 1)
            clock.now = clock.now.advanced(by: .seconds(29))
            details.setPreloadScope(in: record, including: [])
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            #expect(details.detailPreloadTask == nil && details.snapshotPreloadTask == nil)
            clock.now = clock.now.advanced(by: .seconds(1))
            details.activatePreload(in: record, including: [resource])
            await details.detailPreloadTask?.value
            details.drainPreload()
            #expect(details.snapshotPreloadTask == nil && counts.count("detail.preload.read") == 1)
            #expect(counts.count("sidebar.completed") == 2)
            details.setPreloadScope(in: record, including: [])
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            #expect(details.detailPreloadTask == nil)
            let expired = try #require(details.snapshotPreloadTask)
            await expired.value
            #expect(counts.count("detail.preload.read") == 2)
            details.invalidateStates(resources: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            details.drainPreload()
            await details.snapshotPreloadTask?.value
            #expect(counts.count("detail.preload.read") == 3)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func completePreloadsWaitForForegroundHistoryAndReadOneResourceAtATime() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        for name in ["first", "second"] { try await fixture.prepareGroup(name, repositories: ["repo"]) }
        let record = try fixture.service.store.load(fixture.root)
        for resource in [Resource.repository("repo"), .member("first", "repo"), .member("second", "repo")] {
            _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", resource.id], at: record.rootURL.appending(path: resource.path))
        }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let history = SchedulingHistoryReader(git: fixture.service.git, blocked: true)
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: SchedulingResourceMonitor(), readCommits: { path, head, base in
            try await history.read(at: path, head: head, base: base)
        })
        do {
            details.refresh(.repository("repo"), in: record)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while await history.started < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(await history.started == 2)
            let resources: Set<Resource> = [.repository("repo"), .member("first", "repo"), .member("second", "repo")]
            details.setPreloadScope(in: record, including: resources)
            details.drainPreload()
            #expect(details.detailLoading && !details.snapshotLoading)
            #expect(details.detailPreloadTask == nil && details.snapshotPreloadTask == nil)
            await history.release()
            await details.detailTask?.value
            let selectedHead = try #require(details.detail.summary?.headOID)
            details.drainPreload()
            await details.detailPreloadTask?.value
            details.drainPreload()
            await details.snapshotPreloadTask?.value
            #expect(await history.started == 6)
            #expect(await history.maximumConcurrentResources == 1)
            #expect(details.detail.summary?.headOID == selectedHead && details.pendingFailure == nil)
            details.refresh(.member("second", "repo"), in: record)
            #expect(details.detail.commits?.first?.subject == Resource.member("second", "repo").id)
            details.stop(); await details.waitForReads()
        } catch {
            await history.release()
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func failedStatusReadsWaitForExpiryUnlessPathIdentityChanges() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        var record = try fixture.service.store.load(fixture.root)
        let resource = Resource.group("missing")
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let clock = RepositoryReadClock()
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: SchedulingResourceMonitor(), now: { clock.now })
        do {
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            #expect(details.state(for: resource)?.available == false)
            clock.now = clock.now.advanced(by: .seconds(29))
            details.setPreloadScope(in: record, including: [])
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            #expect(details.detailPreloadTask == nil && details.state(for: resource)?.available == false)
            clock.now = clock.now.advanced(by: .seconds(2))
            details.setPreloadScope(in: record, including: [])
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            #expect(details.state(for: resource)?.available == false)
            _ = try await fixture.service.git.run(["worktree", "add", "-b", "missing", record.groupURL("missing").path], at: fixture.root)
            details.setPreloadScope(in: record, including: [])
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            #expect(details.state(for: resource)?.available == true)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func cancelledFollowupReadKeepsTheResourceInvalidatedForVisibleStatusChecks() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let resource = Resource.repository("repo"), path = record.repositoryURL("repo")
        let blocked = fixture.directory.appending(path: "followup-blocked")
        let started = fixture.directory.appending(path: "followup-started")
        let hook = fixture.directory.appending(path: "followup-fsmonitor")
        try Data("""
        #!/bin/sh
        if [ -e "\(blocked.path)" ]; then
            : > "\(started.path)"
            trap 'exit 143' TERM INT
            while [ -e "\(blocked.path)" ]; do sleep 0.02; done
        fi
        printf 'test-token\\000/\\000'
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for arguments in [["config", "core.fsmonitor", hook.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: path)
        }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let clock = RepositoryReadClock()
        let history = SchedulingHistoryReader(git: fixture.service.git, blocked: true)
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: SchedulingResourceMonitor(), readCommits: { path, head, base in
            try await history.read(at: path, head: head, base: base)
        }, now: { clock.now })
        do {
            details.refresh(resource, in: record)
            let historyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while await history.started < 2, ContinuousClock.now < historyDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(await history.started == 2)
            try Data("new change".utf8).write(to: path.appending(path: "new.txt"))
            try Data().write(to: blocked)
            details.request(.workingTree)
            await history.release()
            let statusDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(started), ContinuousClock.now < statusDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(PathSafety.exists(started))
            #expect(details.state(for: resource)?.dirty == false)
            details.refresh(nil, in: record)
            await details.waitForReads()
            try FileManager.default.removeItem(at: blocked)

            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            let retry = try #require(details.detailPreloadTask)
            await retry.value
            #expect(details.state(for: resource)?.dirty == true)
            details.drainPreload()
            #expect(details.detailPreloadTask == nil)
            details.stop(); await details.waitForReads()
        } catch {
            await history.release()
            try? FileManager.default.removeItem(at: blocked)
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func unrelatedRegistrationChangesKeepCurrentReadsAndCompleteDetails() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let history = SchedulingHistoryReader(git: fixture.service.git, blocked: true)
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: SchedulingResourceMonitor(), readCommits: { path, head, base in
            try await history.read(at: path, head: head, base: base)
        })
        details.refresh(.repository("repo"), in: record)
        let reading = try #require(details.detailTask)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while await history.started < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await history.started == 2)
            try await fixture.prepareEmptyGroup("unrelated")
            let updated = try fixture.service.store.load(fixture.root)
            #expect(!details.applyWorkspace(updated))
            #expect(!reading.isCancelled)
            await history.release()
            await reading.value
            let head = try #require(details.detail.summary?.headOID)
            details.invalidate(resources: [.group("unrelated")])
            details.refresh(nil, in: updated)
            details.refresh(.repository("repo"), in: updated)
            #expect(details.detail.summary?.headOID == head && details.detail.commits != nil)
            await details.detailTask?.value
            details.stop(); await details.waitForReads()
        } catch {
            await history.release()
            details.stop(); await details.waitForReads()
            throw error
        }
    }
}

@MainActor private final class RepositoryReadClock {
    var now = ContinuousClock.now
}

private final class SchedulingReadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var diagnostics: RepositoryReadDiagnostics { .init { [self] event in lock.withLock { counts[event.name, default: 0] += event.count } } }
    func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
}

private actor SchedulingHistoryReader {
    let git: Git
    var blocked: Bool
    private(set) var started = 0
    private var activePaths: [String: Int] = [:]
    private(set) var maximumConcurrentResources = 0

    init(git: Git, blocked: Bool = false) { self.git = git; self.blocked = blocked }
    func release() { blocked = false }
    func read(at path: URL, head: String, base: String) async throws -> [GitCommit] {
        started += 1
        activePaths[path.path, default: 0] += 1
        maximumConcurrentResources = max(maximumConcurrentResources, activePaths.count)
        defer {
            if activePaths[path.path] == 1 { activePaths.removeValue(forKey: path.path) }
            else { activePaths[path.path, default: 0] -= 1 }
        }
        while blocked { try await Task.sleep(for: .milliseconds(10)) }
        return try await git.commits(at: path, head: head, base: base, limit: nil)
    }
}

private final class SchedulingResourceMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool { true }
    func stop() {}
}

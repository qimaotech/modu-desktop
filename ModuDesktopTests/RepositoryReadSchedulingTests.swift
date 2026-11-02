import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct RepositoryReadSchedulingTests {
    @Test func failedStatusReadsWaitForExpiryUnlessPathIdentityChanges() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
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
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
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
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
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

    @Test func historyEvictionRereadsOldPairsAndRetainsRecentlyUsedPairs() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        let path = record.repositoryURL("repo")
        let base = try #require(await fixture.service.git.oid("HEAD", at: path))
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let history = SchedulingHistoryReader(git: fixture.service.git)
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: SchedulingResourceMonitor(), readCommits: { path, head, base in
            try await history.read(at: path, head: head, base: base)
        })
        var heads: [String] = []
        do {
            for index in 0..<3 {
                _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "head \(index)"], at: path)
                let head = try #require(await fixture.service.git.oid("HEAD", at: path))
                heads.append(head)
                details.refresh(.repository("repo"), in: record)
                await details.detailTask?.value
                #expect(details.detail.summary?.headOID == head)
            }
            _ = try await fixture.service.git.run(["checkout", "--detach", heads[0]], at: path)
            details.refresh(.repository("repo"), in: record)
            await details.detailTask?.value
            #expect(await history.count(head: heads[0], base: base) == 2)
            #expect(details.detail.commits?.map(\.subject) == ["head 0"])
            _ = try await fixture.service.git.run(["checkout", "--detach", heads[2]], at: path)
            details.refresh(.repository("repo"), in: record)
            await details.detailTask?.value
            #expect(await history.count(head: heads[2], base: base) == 1)
            #expect(details.detail.commits?.count == 3)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }
}

@MainActor private final class RepositoryReadClock {
    var now = ContinuousClock.now
}

private actor SchedulingHistoryReader {
    let git: Git
    var blocked: Bool
    private(set) var started = 0
    private var calls: [String: Int] = [:]

    init(git: Git, blocked: Bool = false) { self.git = git; self.blocked = blocked }
    func release() { blocked = false }
    func count(head: String, base: String) -> Int { calls[head + "|" + base] ?? 0 }
    func read(at path: URL, head: String, base: String) async throws -> [GitCommit] {
        started += 1
        calls[head + "|" + base, default: 0] += 1
        while blocked { try await Task.sleep(for: .milliseconds(10)) }
        return try await git.commits(at: path, head: head, base: base, limit: nil)
    }
}

private final class SchedulingResourceMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool { true }
    func stop() {}
}

import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct RepositoryDiskDetailTests {
    @Test func diskSnapshotAppearsBeforeLiveReadAndDoesNotReleaseTheDetailWaiter() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let first = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), cache: cache)
        first.refresh(.repository("repo"), in: record)
        await first.detailTask?.value
        let original = try #require(first.detail.summary?.headOID)
        first.stop(); await first.waitForReads(); await first.flushCache()

        let path = record.repositoryURL("repo")
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "new head"], at: path)
        let updated = try #require(await fixture.service.git.oid("HEAD", at: path))
        try Data("pending".utf8).write(to: path.appending(path: "pending.txt"))
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        reader.blocked = true
        let reopened = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache")))
        reopened.refresh(.repository("repo"), in: record)
        var waiterFinished = false
        let waiter = Task { await reopened.waitForDetail(); waiterFinished = true }
        do {
            try await eventually { reader.calls == 2 }
            #expect(reopened.detail.summary?.headOID == original && reopened.detail.changes?.isEmpty == true)
            #expect(reopened.detailIsStale && reopened.detailObservedAt != nil && reopened.detailRefreshError == nil)
            #expect(reopened.state(for: .repository("repo")) == nil && !waiterFinished)
            reader.blocked = false
            await reopened.detailTask?.value
            await waiter.value
            #expect(waiterFinished && !reopened.detailIsStale)
            #expect(reopened.detail.summary?.headOID == updated && reopened.detail.commits?.map(\.subject) == ["new head"])
            #expect(reopened.detail.changes?.map(\.path) == ["pending.txt"])
            reopened.stop(); await reopened.waitForReads()
        } catch {
            reader.blocked = false; waiter.cancel()
            reopened.stop(); await reopened.waitForReads(); await waiter.value
            throw error
        }
    }

    @Test func anotherModelReusesDiskHistoryWhileReadingFreshChanges() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let directory = fixture.directory.appending(path: "detail-cache")
        let initialCache = HistoryWriteCountingCache(directory: directory)
        let first = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), cache: initialCache)
        first.refresh(.repository("repo"), in: record)
        await first.detailTask?.value
        first.request(.workingTree)
        await first.detailTask?.value
        #expect(await initialCache.historyWrites == 1)
        first.stop(); await first.waitForReads(); await first.flushCache()
        try Data("fresh".utf8).write(to: record.repositoryURL("repo").appending(path: "fresh.txt"))
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        reader.failure = ModuError("unexpected-history-read", "History should come from disk.")
        let reopenedCache = HistoryWriteCountingCache(directory: directory)
        let reopened = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: reopenedCache)
        reopened.refresh(.repository("repo"), in: record)
        await reopened.detailTask?.value
        #expect(reader.calls == 0 && reopened.detailRefreshError == nil && !reopened.detailIsStale)
        #expect(await reopenedCache.historyWrites == 0)
        #expect(reopened.detail.changes?.map(\.path) == ["fresh.txt"])
        reopened.stop(); await reopened.waitForReads()
    }

    @Test func failedHistoryKeepsOneCoherentSuccessAndRetryReplacesIt() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = record.repositoryURL("repo")
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "old head"], at: path)
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: cache)
        details.refresh(.repository("repo"), in: record)
        await details.detailTask?.value
        let original = try #require(details.detail.summary?.headOID)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "new head"], at: path)
        let updated = try #require(await fixture.service.git.oid("HEAD", at: path))
        try Data("new".utf8).write(to: path.appending(path: "new.txt"))
        reader.failure = ModuError("history-failed", "History temporarily unavailable.")
        var alerts = 0
        details.onCommitsError = { _ in alerts += 1 }
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.detail.summary?.headOID == original && details.detail.commits?.map(\.subject) == ["old head"])
        #expect(details.detail.changes?.isEmpty == true && details.detailIsStale)
        #expect(details.detailRefreshError?.code == "history-failed" && alerts == 0)
        #expect(details.state(for: .repository("repo"))?.dirty == true)
        let context = try await fixture.service.prepareResourceRead(.repository("repo"), in: record)
        await details.flushCache()
        let stored = await cache.loadDetail(for: try RepositoryCacheIdentity(context: context))
        #expect(stored?.summary.headOID == original)

        reader.failure = nil
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.detail.summary?.headOID == updated && details.detail.changes?.map(\.path) == ["new.txt"])
        #expect(!details.detailIsStale && details.detailRefreshError == nil)
        details.stop(); await details.waitForReads()
    }

    @Test func cancelledHydrationCannotPublishOrWriteAndIsDrained() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = record.repositoryURL("repo")
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        let cache = SuspendedDetailCache(snapshot: .init(summary: .init(head: "main", headOID: head, base: "origin/main", baseOID: head), changes: [], commits: [], behindCommits: [], observedAt: Date()))
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), cache: cache)
        do {
            details.refresh(.repository("repo"), in: record)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while await !cache.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(await cache.started)
            details.refresh(nil, in: record)
            var drained = false
            let drain = Task { await details.waitForReads(); drained = true }
            await Task.yield()
            #expect(!drained && details.detail.summary == nil)
            await cache.release()
            await drain.value
            #expect(drained && details.detail.summary == nil && details.detailObservedAt == nil)
            #expect(await cache.writes == 0)
            details.stop(); await details.waitForReads()
        } catch {
            await cache.release()
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func replacedInvalidGitDirectoryClearsThePreviousSuccess() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor())
        details.refresh(.repository("repo"), in: record)
        await details.detailTask?.value
        try #require(details.detail.summary != nil)
        let gitDirectory = record.repositoryURL("repo").appending(path: ".git")
        try FileManager.default.moveItem(at: gitDirectory, to: fixture.directory.appending(path: "original-git"))
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: false)
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.detail.summary == nil && details.detail.summaryError != nil)
        #expect(details.detailObservedAt == nil && !details.detailIsStale)
        details.stop(); await details.waitForReads()
    }

    @Test(arguments: ["shallow", "grafts", "replace"])
    func specialHistoryBypassesBothMemoryAndDiskRanges(_ mode: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = record.repositoryURL("repo")
        let base = try #require(await fixture.service.git.oid("HEAD", at: path))
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "local"], at: path)
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        let cache = HistoryWriteCountingCache(directory: fixture.directory.appending(path: "detail-cache"))
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        let details = RepositoryDetailModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: cache)
        do {
            details.refresh(.repository("repo"), in: record)
            await details.detailTask?.value
            let context = try await fixture.service.prepareResourceRead(.repository("repo"), in: record)
            let identity = try RepositoryCacheIdentity(context: context)
            let key = RepositoryHistoryCacheKey(repository: identity.repository, head: head, base: base)
            let stored = await cache.loadHistory(for: key)
            #expect(reader.calls == 2 && stored != nil)
            switch mode {
            case "replace": _ = try await fixture.service.git.run(["update-ref", "refs/replace/\(head)", base], at: path)
            case "grafts": try Data((head + "\n").utf8).write(to: context.commonDirectory.appending(path: "info/grafts"))
            default: try Data((head + "\n").utf8).write(to: context.commonDirectory.appending(path: "shallow"))
            }
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 4)
            #expect(await cache.historyInvalidations == 1)
            #expect(await cache.loadHistory(for: key) == nil)
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 6)
            #expect(await cache.historyInvalidations == 1)

            if mode == "replace" {
                let tree = try await fixture.service.git.run(["rev-parse", "HEAD^{tree}"], at: path).text
                let replacement = try await fixture.service.git.run(["commit-tree", tree, "-m", "replacement"], at: path).text
                _ = try await fixture.service.git.run(["update-ref", "refs/replace/\(head)", replacement], at: path)
            } else {
                let file = context.commonDirectory.appending(path: mode == "grafts" ? "info/grafts" : "shallow")
                try Data((head + "\n").utf8).write(to: file, options: .atomic)
            }
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 8)
            #expect(await cache.historyInvalidations == 2)
            if mode == "replace" {
                _ = try await fixture.service.git.run(["update-ref", "-d", "refs/replace/\(head)"], at: path)
            } else {
                try FileManager.default.removeItem(at: context.commonDirectory.appending(path: mode == "grafts" ? "info/grafts" : "shallow"))
            }
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 10)
            #expect(await cache.historyWrites == 2)
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 10)
            #expect(await cache.historyInvalidations == 2)
            details.stop(); await details.waitForReads(); await details.flushCache()
        } catch {
            details.stop(); await details.waitForReads(); await details.flushCache()
            throw error
        }
    }

    private func prepare(_ fixture: Fixture) async throws -> WorkspaceRecord {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        return try fixture.service.store.load(fixture.root)
    }

    private func preferences(_ fixture: Fixture) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

@MainActor private final class DiskDetailHistoryReader {
    let git: Git
    var blocked = false
    var failure: ModuError?
    private(set) var calls = 0

    init(git: Git) { self.git = git }

    func read(at path: URL, head: String, base: String) async throws -> [GitCommit] {
        calls += 1
        while blocked { try await Task.sleep(for: .milliseconds(10)) }
        if let failure { throw failure }
        return try await git.commits(at: path, head: head, base: base, limit: nil)
    }
}

private final class DiskDetailMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool { true }
    func stop() {}
}

private actor SuspendedDetailCache: RepositoryDetailCaching {
    let snapshot: RepositoryDetailSnapshot
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var writes = 0

    init(snapshot: RepositoryDetailSnapshot) { self.snapshot = snapshot }

    func loadDetail(for identity: RepositoryCacheIdentity) async -> RepositoryDetailSnapshot? {
        await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
        return snapshot
    }
    func release() { continuation?.resume(); continuation = nil }
    func saveDetail(_ value: RepositoryDetailSnapshot, for identity: RepositoryCacheIdentity) async { writes += 1 }
    func loadHistory(for key: RepositoryHistoryCacheKey) async -> RepositoryHistorySnapshot? { nil }
    func saveHistory(_ value: RepositoryHistorySnapshot, for key: RepositoryHistoryCacheKey) async { writes += 1 }
    func invalidateDetail(for identity: RepositoryCacheIdentity) async {}
    func invalidateHistory(for repository: RepositoryCacheRepositoryIdentity) async {}
}

private actor HistoryWriteCountingCache: RepositoryDetailCaching {
    let storage: RepositoryDiskCache
    private(set) var historyWrites = 0
    private(set) var historyInvalidations = 0

    init(directory: URL) { storage = RepositoryDiskCache(directory: directory) }

    func loadDetail(for identity: RepositoryCacheIdentity) async -> RepositoryDetailSnapshot? { await storage.loadDetail(for: identity) }
    func saveDetail(_ value: RepositoryDetailSnapshot, for identity: RepositoryCacheIdentity) async { await storage.saveDetail(value, for: identity) }
    func loadHistory(for key: RepositoryHistoryCacheKey) async -> RepositoryHistorySnapshot? { await storage.loadHistory(for: key) }
    func saveHistory(_ value: RepositoryHistorySnapshot, for key: RepositoryHistoryCacheKey) async {
        historyWrites += 1
        await storage.saveHistory(value, for: key)
    }
    func invalidateDetail(for identity: RepositoryCacheIdentity) async { await storage.invalidateDetail(for: identity) }
    func invalidateHistory(for repository: RepositoryCacheRepositoryIdentity) async {
        historyInvalidations += 1
        await storage.invalidateHistory(for: repository)
    }
    func flush() async { await storage.flush() }
}

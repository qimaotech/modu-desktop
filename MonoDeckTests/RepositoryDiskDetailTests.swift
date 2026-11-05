import Foundation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct RepositoryDiskDetailTests {
    @Test func failedCompletePreloadKeepsThePreviousSuccessAndConsumesItsRequest() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let resource = Resource.repository("repo"), path = record.repositoryURL("repo")
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: cache)
        do {
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            details.drainPreload()
            await details.snapshotPreloadTask?.value
            await details.flushCache()
            let context = try await fixture.service.prepareResourceRead(resource, in: record)
            let identity = try RepositoryCacheIdentity(context: context)
            let original = try #require(await cache.loadDetail(for: identity)?.summary.headOID)
            _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "invalidate background history"], at: path)
            try Data("new".utf8).write(to: path.appending(path: "new.txt"))
            reader.failure = MonoDeckError("background-history-failed", "Background history is unavailable.")
            details.invalidateStates(resources: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            details.drainPreload()
            await details.snapshotPreloadTask?.value
            #expect(reader.calls == 4)
            #expect(details.detail.summary == nil && !details.detailLoading && details.pendingFailure == nil)
            #expect(details.state(for: resource)?.dirty == true)
            details.drainPreload()
            #expect(details.snapshotPreloadTask == nil)
            await details.flushCache()
            #expect(await cache.loadDetail(for: identity)?.summary.headOID == original)
            details.refresh(resource, in: record)
            #expect(details.detail.summary?.headOID == original && details.detail.changes?.isEmpty == true)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test(arguments: CompletePreloadCancellation.allCases)
    func cancelledCompletePreloadsCannotPublishOrPersist(_ cancellation: CompletePreloadCancellation) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        try await fixture.prepareEmptyGroup("foreground")
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let resource = Resource.repository("repo")
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        reader.blocked = true
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let now = ContinuousClock.now
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: cache, now: { now })
        do {
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await details.detailPreloadTask?.value
            details.drainPreload()
            let reading = try #require(details.snapshotPreloadTask)
            try await eventually { reader.calls == 2 }
            switch cancellation {
            case .collapse: details.setPreloadScope(in: record, including: [])
            case .selection: details.refresh(.group("foreground"), in: record)
            case .invalidation: details.invalidateStates(resources: [resource])
            }
            #expect(reading.isCancelled && details.snapshotPreloadTask == nil)
            reader.blocked = false
            await reading.value
            await details.waitForReads()
            await details.detailTask?.value
            await details.flushCache()
            let context = try await fixture.service.prepareResourceRead(resource, in: record)
            #expect(await cache.loadDetail(for: try RepositoryCacheIdentity(context: context)) == nil)
            #expect(details.pendingFailure == nil)
            if case .collapse = cancellation {
                details.setPreloadScope(in: record, including: [resource])
                details.drainPreload()
                let retry = try #require(details.snapshotPreloadTask)
                await retry.value
            }
            details.refresh(resource, in: record)
            if case .collapse = cancellation {
                #expect(details.detail.summary != nil && details.detail.uniqueCommits != nil)
            } else {
                #expect(details.detail.summary == nil && details.detail.changes == nil)
            }
            details.stop(); await details.waitForReads(); await details.flushCache()
        } catch {
            reader.blocked = false
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func diskSnapshotAppearsBeforeLiveReadAndDoesNotReleaseTheDetailWaiter() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let first = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), cache: cache)
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
        let reopened = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache")))
        reopened.refresh(.repository("repo"), in: record)
        var waiterFinished = false
        let waiter = Task { await reopened.waitForDetail(); waiterFinished = true }
        do {
            try await eventually { reader.calls == 2 }
            #expect(reopened.detail.summary?.headOID == original && reopened.detail.changes?.isEmpty == true)
            #expect(reopened.detailLoading && reopened.pendingFailure == nil)
            #expect(reopened.state(for: .repository("repo")) == nil && !waiterFinished)
            reader.blocked = false
            await reopened.detailTask?.value
            await waiter.value
            #expect(waiterFinished && !reopened.detailLoading)
            #expect(reopened.detail.summary?.headOID == updated && reopened.detail.uniqueCommits?.map(\.subject) == ["new head"])
            #expect(reopened.detail.changes?.map(\.path) == ["pending.txt"])
            reopened.stop(); await reopened.waitForReads()
        } catch {
            reader.blocked = false; waiter.cancel()
            reopened.stop(); await reopened.waitForReads(); await waiter.value
            throw error
        }
    }

    @Test func preloadedDetailsReuseDiskHistoryWhileReadingFreshChanges() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let directory = fixture.directory.appending(path: "detail-cache")
        let initialCache = RepositoryDiskCache(directory: directory)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "preloaded head"], at: record.repositoryURL("repo"))
        let first = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), cache: initialCache)
        first.setPreloadScope(in: record, including: [.repository("repo")])
        first.drainPreload()
        await first.detailPreloadTask?.value
        first.drainPreload()
        await first.snapshotPreloadTask?.value
        #expect(first.detail.summary == nil && first.detail.changes == nil && !first.detailLoading)
        first.refresh(.repository("repo"), in: record)
        #expect(first.detail.uniqueCommits?.map(\.subject) == ["preloaded head"])
        first.stop(); await first.waitForReads(); await first.flushCache()
        try Data("fresh".utf8).write(to: record.repositoryURL("repo").appending(path: "fresh.txt"))
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        reader.failure = MonoDeckError("unexpected-history-read", "History should come from disk.")
        let reopenedCache = RepositoryDiskCache(directory: directory)
        let context = try await fixture.service.prepareResourceRead(.repository("repo"), in: record)
        let saved = await reopenedCache.loadDetail(for: try RepositoryCacheIdentity(context: context))
        #expect(saved?.uniqueCommits?.map(\.subject) == ["preloaded head"] && saved?.changes.isEmpty == true)
        let reopened = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: reopenedCache)
        reopened.refresh(.repository("repo"), in: record)
        await reopened.detailTask?.value
        #expect(reader.calls == 0 && reopened.pendingFailure == nil)
        #expect(reopened.detail.changes?.map(\.path) == ["fresh.txt"])
        reopened.stop(); await reopened.waitForReads()
    }

    @Test func failedHistoryKeepsOneCoherentSuccessAndRetryReplacesIt() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = record.repositoryURL("repo")
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "old head"], at: path)
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        }, cache: cache)
        details.refresh(.repository("repo"), in: record)
        await details.detailTask?.value
        let original = try #require(details.detail.summary?.headOID)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "new head"], at: path)
        let updated = try #require(await fixture.service.git.oid("HEAD", at: path))
        try Data("new".utf8).write(to: path.appending(path: "new.txt"))
        reader.failure = MonoDeckError("history-failed", "History temporarily unavailable.")
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.detail.summary?.headOID == original && details.detail.uniqueCommits?.map(\.subject) == ["old head"])
        #expect(details.detail.changes?.isEmpty == true)
        #expect(details.failureForPresentation?.keepsPreviousResult == true)
        #expect(details.failureForPresentation?.error.code == "history-failed")
        #expect(details.state(for: .repository("repo"))?.dirty == true)
        let context = try await fixture.service.prepareResourceRead(.repository("repo"), in: record)
        await details.flushCache()
        let stored = await cache.loadDetail(for: try RepositoryCacheIdentity(context: context))
        #expect(stored?.summary.headOID == original)

        reader.failure = nil
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.detail.summary?.headOID == updated && details.detail.changes?.map(\.path) == ["new.txt"])
        #expect(details.pendingFailure == nil)
        details.stop(); await details.waitForReads()
    }

    @Test func detailFailuresDeduplicateUntilRecoveryButAllowManualRetries() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        reader.failure = MonoDeckError("history-failed", "History temporarily unavailable.")
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        })
        let resource = Resource.repository("repo")
        details.refresh(resource, in: record)
        #expect(details.detailLoading && details.failureForPresentation == nil)
        await details.detailTask?.value
        #expect(!details.detailLoading && details.failureForPresentation?.keepsPreviousResult == false)
        #expect(details.takeFailureForPresentation()?.error.code == "history-failed")
        details.refresh(resource, in: record, userInitiated: true)
        await details.detailTask?.value
        #expect(details.pendingFailure == nil)
        details.dismissFailure()

        details.request(.structure)
        await details.detailTask?.value
        #expect(details.pendingFailure == nil)
        details.refresh(resource, in: record, userInitiated: true)
        await details.detailTask?.value
        #expect(details.pendingFailure?.userInitiated == true)
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.takeFailureForPresentation()?.error.code == "history-failed")
        details.dismissFailure()

        reader.failure = MonoDeckError("other-failure", "Another error.")
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.takeFailureForPresentation()?.error.code == "other-failure")
        details.dismissFailure()
        reader.failure = nil
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.pendingFailure == nil && details.detail.uniqueCommitsError == nil)

        let path = record.repositoryURL("repo")
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "invalidate history"], at: path)
        reader.failure = MonoDeckError("other-failure", "Another error.")
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.takeFailureForPresentation()?.error.code == "other-failure")
        details.stop(); await details.waitForReads()
    }

    @Test(arguments: [false, true])
    func followUpRefreshSuppressesIntermediateFailureAndKeepsManualIntent(_ manualRetry: Bool) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        reader.failure = MonoDeckError("history-failed", "History temporarily unavailable.")
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
            try await reader.read(at: path, head: head, base: base)
        })
        let resource = Resource.repository("repo")
        details.refresh(resource, in: record)
        await details.detailTask?.value
        #expect(details.takeFailureForPresentation() != nil)
        details.dismissFailure()
        reader.blocked = true
        if !manualRetry { reader.failuresRemaining = 2 }
        let calls = reader.calls
        details.refresh(resource, in: record, userInitiated: manualRetry)
        do {
            try await eventually { reader.calls == calls + 2 }
            #expect(details.detailLoading && details.pendingFailure == nil)
            details.request(.structure)
            reader.blocked = false
            await details.detailTask?.value
            #expect(reader.calls == calls + 4 && !details.detailLoading)
            if manualRetry { #expect(details.failureForPresentation?.error.code == "history-failed") }
            else { #expect(details.pendingFailure == nil && details.detail.summary != nil && details.detail.uniqueCommitsError == nil) }
            details.stop(); await details.waitForReads()
        } catch {
            reader.blocked = false
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func cancelledHydrationCannotPublishOrWriteAndIsDrained() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = record.repositoryURL("repo")
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        let cache = SuspendedDetailCache(snapshot: .init(summary: .init(head: "main", headOID: head, base: "origin/main", baseOID: head), changes: [], uniqueCommits: [], behindCommits: [], observedAt: Date()))
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), cache: cache)
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
            #expect(drained && details.detail.summary == nil && details.pendingFailure == nil)
            #expect(await cache.writes == 0)
            details.stop(); await details.waitForReads()
        } catch {
            await cache.release()
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func replacedInvalidGitDirectoryClearsThePreviousSuccess() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor())
        details.refresh(.repository("repo"), in: record)
        await details.detailTask?.value
        try #require(details.detail.summary != nil)
        let gitDirectory = record.repositoryURL("repo").appending(path: ".git")
        try FileManager.default.moveItem(at: gitDirectory, to: fixture.directory.appending(path: "original-git"))
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: false)
        details.request(.structure)
        await details.detailTask?.value
        #expect(details.detail.summary == nil && details.detail.summaryError != nil)
        #expect(details.failureForPresentation?.keepsPreviousResult == false)
        details.stop(); await details.waitForReads()
    }

    @Test func shallowHistoryBypassesCachedRanges() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try preferences(fixture)
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = record.repositoryURL("repo")
        let base = try #require(await fixture.service.git.oid("HEAD", at: path))
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "local"], at: path)
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        let cache = RepositoryDiskCache(directory: fixture.directory.appending(path: "detail-cache"))
        let reader = DiskDetailHistoryReader(git: fixture.service.git)
        let details = GitBrowserModel(service: fixture.service, defaults: defaults, monitor: DiskDetailMonitor(), readCommits: { path, head, base in
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
            try Data((head + "\n").utf8).write(to: context.commonDirectory.appending(path: "shallow"))
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 4)
            #expect(await cache.loadHistory(for: key) == nil)
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 6)

            try FileManager.default.removeItem(at: context.commonDirectory.appending(path: "shallow"))
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 8)
            #expect(await cache.loadHistory(for: key) != nil)
            details.request(.structure)
            await details.detailTask?.value
            #expect(reader.calls == 8)
            details.stop(); await details.waitForReads(); await details.flushCache()
        } catch {
            details.stop(); await details.waitForReads(); await details.flushCache()
            throw error
        }
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

enum CompletePreloadCancellation: CaseIterable {
    case collapse, selection, invalidation
}

@MainActor private final class DiskDetailHistoryReader {
    let git: Git
    var blocked = false
    var failure: MonoDeckError?
    var failuresRemaining: Int?
    private(set) var calls = 0

    init(git: Git) { self.git = git }

    func read(at path: URL, head: String, base: String) async throws -> [GitCommit] {
        calls += 1
        while blocked { try await Task.sleep(for: .milliseconds(10)) }
        if let failure, failuresRemaining.map({ $0 > 0 }) ?? true {
            if let remaining = failuresRemaining { failuresRemaining = remaining - 1 }
            throw failure
        }
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

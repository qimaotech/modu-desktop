import Foundation
import Testing
@testable import ModuCore

struct RepositoryCacheSchedulingTests {
    @Test func detailChangesShareTheFirstWriteDeadlineAndPersistOnlyTheLatestContent() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try await identity(f)
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"), diagnostics: events.diagnostics,
                                        waitForWrite: { try await gate.wait() })
        await cache.saveDetail(snapshot("first"), for: identity)
        try await eventually { await gate.waits == 1 }
        await cache.saveDetail(snapshot("second"), for: identity)
        await cache.saveDetail(snapshot("latest"), for: identity)
        #expect(await gate.waits == 1)
        #expect(events.count("cache.encode") == 0 && events.count("cache.write") == 0)
        await gate.release()
        try await eventually { events.count("cache.write") == 1 }
        let directory = await cache.directory
        let reopened = RepositoryDiskCache(directory: directory)
        #expect(await reopened.loadDetail(for: identity)?.summary.head == "latest")
        #expect(events.count("cache.encode") == 1)
        await reopened.flush(); await cache.flush()
    }

    @Test func unchangedContentSkipsEncodingUntilCheckpointAndFlushPreservesTheLatestObservation() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try await identity(f)
        let clock = SchedulingCacheClock()
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"), now: { clock.now }, diagnostics: events.diagnostics,
                                        waitForWrite: { try await gate.wait() })
        await cache.saveDetail(snapshot("same", observedAt: clock.now), for: identity)
        await cache.flush()
        #expect(events.count("cache.encode") == 1)
        clock.advance(59)
        await cache.saveDetail(snapshot("same", observedAt: clock.now), for: identity)
        #expect(events.count("cache.encode") == 1 && events.count("cache.write") == 1)
        clock.advance(1)
        await cache.saveDetail(snapshot("same", observedAt: clock.now), for: identity)
        try await eventually { await gate.pending == 1 }
        await gate.release()
        try await eventually { events.count("cache.write") == 2 }
        clock.advance(1)
        await cache.saveDetail(snapshot("same", observedAt: clock.now), for: identity)
        await cache.flush()
        let directory = await cache.directory
        let reopened = RepositoryDiskCache(directory: directory, now: { clock.now })
        #expect(await reopened.loadDetail(for: identity)?.observedAt == clock.now)
        #expect(events.count("cache.write") == 3)
        await reopened.flush()
    }

    @Test func invalidationCancelsAcceptedWritesAndAnOldDeadlineCannotReviveThem() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try await identity(f)
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory, diagnostics: events.diagnostics, waitForWrite: { try await gate.wait() })
        await cache.saveDetail(snapshot("discard"), for: identity)
        try await eventually { await gate.waits == 1 }
        await cache.invalidateDetail(for: identity)
        await gate.release()
        await cache.flush()
        #expect(await cache.loadDetail(for: identity) == nil)
        #expect(events.count("cache.write") == 0 && !PathSafety.exists(directory))
        await cache.saveDetail(snapshot("replacement"), for: identity)
        await cache.flush()
        #expect(await cache.loadDetail(for: identity)?.summary.head == "replacement")
        await cache.flush()
    }

    @Test func targetReadsNeverScanTheCacheAndStableWritesReuseTheCapacityLedger() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try await identity(f)
        let directory = f.directory.appending(path: "cache")
        let producer = RepositoryDiskCache(directory: directory)
        let history = RepositoryHistorySnapshot(ahead: [], behind: [])
        let first = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "a", count: 40), base: String(repeating: "b", count: 40))
        let second = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "c", count: 40), base: first.base)
        await producer.saveHistory(history, for: first)
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let consumer = RepositoryDiskCache(directory: directory, diagnostics: events.diagnostics, waitForWrite: { try await gate.wait() })
        #expect(await consumer.loadHistory(for: first) != nil)
        #expect(events.count("cache.scan") == 0)
        await consumer.saveHistory(history, for: second)
        #expect(events.count("cache.scan") == 1)
        await consumer.saveHistory(history, for: first)
        #expect(events.count("cache.scan") == 1)
        await consumer.flush(); await producer.flush()
    }

    @Test func anotherActorMutationInvalidatesTheLedgerAndFlushDoesNotRecreateRemovedWorkspaces() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try await identity(f)
        let directory = f.directory.appending(path: "cache")
        let events = CacheDiagnosticEvents()
        let first = RepositoryDiskCache(directory: directory, diagnostics: events.diagnostics)
        let second = RepositoryDiskCache(directory: directory)
        let history = RepositoryHistorySnapshot(ahead: [], behind: [])
        let key = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "a", count: 40), base: String(repeating: "b", count: 40))
        await first.saveHistory(history, for: key)
        await second.saveHistory(history, for: key)
        await first.saveHistory(history, for: key)
        #expect(events.count("cache.scan") == 2)
        await first.saveDetail(snapshot("pending"), for: identity)
        try FileManager.default.removeItem(at: f.root)
        await first.flush()
        #expect(await first.loadDetail(for: identity) == nil)
        await second.flush()
    }

    private func identity(_ fixture: Fixture) async throws -> RepositoryCacheIdentity {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        try await fixture.prepareEmptyGroup("cached")
        let record = try fixture.service.store.load(fixture.root)
        let context = try await fixture.service.prepareResourceRead(.group("cached"), in: record)
        return try RepositoryCacheIdentity(context: context)
    }

    private func snapshot(_ head: String, observedAt: Date = Date()) -> RepositoryDetailSnapshot {
        .init(summary: .init(head: head, headOID: String(repeating: "a", count: 40), hasRemotes: false),
              changes: [], commits: [], behindCommits: nil, observedAt: observedAt)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
}

private actor CacheWriteGate {
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var waits = 0
    var pending: Int { continuations.count }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waits += 1; continuations[id] = continuation
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release() {
        let pending = continuations; continuations = [:]
        for continuation in pending.values { continuation.resume() }
    }

    private func cancel(_ id: UUID) { continuations.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

private final class SchedulingCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private final class CacheDiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    var diagnostics: RepositoryReadDiagnostics { .init { [self] event in lock.withLock { values[event.name, default: 0] += event.count } } }
    func count(_ name: String) -> Int { lock.withLock { values[name, default: 0] } }
}

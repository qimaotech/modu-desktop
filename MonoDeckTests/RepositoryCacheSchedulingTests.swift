import Foundation
import Darwin
import Testing
@testable import MonoDeckCore

struct RepositoryCacheSchedulingTests {
    @Test func detailChangesShareTheFirstWriteDeadlineAndPersistOnlyTheLatestContent() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"), diagnostics: events.diagnostics,
                                        waitForWrite: { try await gate.wait() })
        do {
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
        } catch {
            await gate.release(); await cache.flush()
            throw error
        }
    }

    @Test func unchangedContentSkipsEncodingUntilCheckpointAndFlushPreservesTheLatestObservation() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let clock = SchedulingCacheClock()
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"), now: { clock.now }, diagnostics: events.diagnostics,
                                        waitForWrite: { try await gate.wait() })
        do {
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
        } catch {
            await gate.release(); await cache.flush()
            throw error
        }
    }

    @Test func invalidationCancelsAcceptedWritesAndAnOldDeadlineCannotReviveThem() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let gate = CacheWriteGate()
        let events = CacheDiagnosticEvents()
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory, diagnostics: events.diagnostics, waitForWrite: { try await gate.wait() })
        do {
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
        } catch {
            await gate.release(); await cache.flush()
            throw error
        }
    }

    @Test func flushDoesNotRecreateRemovedWorkspaces() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory)
        await cache.saveDetail(snapshot("pending"), for: identity)
        try FileManager.default.removeItem(at: f.root)
        await cache.flush()
        #expect(await cache.loadDetail(for: identity) == nil)
        #expect(!PathSafety.exists(f.root) && !PathSafety.exists(directory))
    }

    @Test func pendingDetailsUseABoundedLRU() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let first = try await identity(f)
        var identities = [first]
        for group in ["second", "third"] {
            try await f.prepareEmptyGroup(group)
            identities.append(try RepositoryCacheIdentity(context: await f.service.prepareResourceRead(.group(group), in: f.service.store.load(f.root))))
        }
        let gate = CacheWriteGate()
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory, maximumDetailCount: 2, waitForWrite: { try await gate.wait() })
        await cache.saveDetail(snapshot("first"), for: identities[0])
        await cache.saveDetail(snapshot("second"), for: identities[1])
        #expect(await cache.loadDetail(for: identities[0])?.summary.head == "first")
        await cache.saveDetail(snapshot("third"), for: identities[2])
        #expect(await cache.detailMemoryStatistics.count == 2)
        await cache.flush()
        let reopened = RepositoryDiskCache(directory: directory)
        #expect(await reopened.loadDetail(for: identities[0])?.summary.head == "first")
        #expect(await reopened.loadDetail(for: identities[1]) == nil)
        #expect(await reopened.loadDetail(for: identities[2])?.summary.head == "third")
        await reopened.flush()
    }

    @Test func flushReleasesPendingDetailsWhenTheCacheIsLocked() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let directory = f.directory.appending(path: "cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appending(path: ".write.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let cache = RepositoryDiskCache(directory: directory)
        await cache.saveDetail(snapshot("blocked"), for: identity)
        await cache.flush()
        #expect(await cache.detailMemoryStatistics.count == 0)
        #expect(await cache.loadDetail(for: identity) == nil)
    }

    @Test func delayedOlderDetailsCannotReplaceAnotherActorsSnapshot() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let directory = f.directory.appending(path: "cache")
        let gate = CacheWriteGate()
        let first = RepositoryDiskCache(directory: directory, waitForWrite: { try await gate.wait() })
        let second = RepositoryDiskCache(directory: directory)
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            await first.saveDetail(snapshot("older", observedAt: observedAt), for: identity)
            try await eventually { await gate.pending == 1 }
            let newer = observedAt.addingTimeInterval(1)
            await second.saveDetail(snapshot("newer", observedAt: newer), for: identity)
            await second.flush()
            await first.flush()
            let reopened = RepositoryDiskCache(directory: directory)
            let restored = try #require(await reopened.loadDetail(for: identity))
            #expect(restored.summary.head == "newer" && restored.observedAt == newer)
            await reopened.flush(); await second.flush()
        } catch {
            await gate.release(); await first.flush(); await second.flush()
            throw error
        }
    }

    @Test func externalWritesRevalidateDeduplicationAndObservationTimes() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let identity = try await identity(f)
        let directory = f.directory.appending(path: "cache")
        let clock = SchedulingCacheClock()
        let first = RepositoryDiskCache(directory: directory, now: { clock.now })
        let second = RepositoryDiskCache(directory: directory, now: { clock.now })
        await first.saveDetail(snapshot("first", observedAt: clock.now), for: identity)
        await first.flush()
        clock.advance(1)
        await second.saveDetail(snapshot("second", observedAt: clock.now), for: identity)
        await second.flush()
        clock.advance(1)
        await first.saveDetail(snapshot("first", observedAt: clock.now), for: identity)
        await first.flush()
        #expect(await second.loadDetail(for: identity)?.summary.head == "first")
        clock.advance(1)
        await second.saveDetail(snapshot("first", observedAt: clock.now), for: identity)
        await second.flush()
        #expect(await first.loadDetail(for: identity)?.observedAt == clock.now)
        await first.flush(); await second.flush()
    }

    private func identity(_ fixture: Fixture) async throws -> RepositoryCacheIdentity {
        try await fixture.prepareEmptyGroup("cached")
        let record = try fixture.service.store.load(fixture.root)
        let context = try await fixture.service.prepareResourceRead(.group("cached"), in: record)
        return try RepositoryCacheIdentity(context: context)
    }

    private func snapshot(_ head: String, observedAt: Date = Date()) -> RepositoryDetailSnapshot {
        .init(summary: .init(head: head, headOID: String(repeating: "a", count: 40), hasRemotes: false),
              changes: [], uniqueCommits: [], behindCommits: nil, observedAt: observedAt)
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

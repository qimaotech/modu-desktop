import Foundation
import Testing
@testable import ModuCore

struct RepositoryDiskCacheTests {
    @Test func successfulDetailsAndHistorySurviveCacheRecreation() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let context = try await prepareContext(f)
        let identity = try RepositoryCacheIdentity(context: context)
        let directory = f.directory.appending(path: "cache")
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let detail = sampleDetail(observedAt: observedAt)
        let history = sampleHistory()
        let key = RepositoryHistoryCacheKey(repository: identity.repository, head: detail.summary.headOID, base: String(repeating: "b", count: 40))
        let cache = RepositoryDiskCache(directory: directory)
        await cache.saveDetail(detail, for: identity)
        await cache.flush()
        await cache.saveHistory(history, for: key)

        let reopened = RepositoryDiskCache(directory: directory)
        let restored = try #require(await reopened.loadDetail(for: identity))
        #expect(restored.observedAt == observedAt)
        #expect(restored.summary == detail.summary)
        #expect(restored.changes == detail.changes)
        #expect(restored.commits == detail.commits && restored.behindCommits == detail.behindCommits)
        let restoredHistory = try #require(await reopened.loadHistory(for: key))
        #expect(restoredHistory.ahead == history.ahead && restoredHistory.behind == history.behind)
    }

    @Test(arguments: ["corrupt", "unsupported-version"])
    func unreadableCacheEntriesBecomeMisses(_ kind: String) async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory)
        await cache.saveDetail(sampleDetail(), for: identity)
        await cache.flush()
        let file = try #require(cacheFiles(in: directory).first)
        if kind == "corrupt" {
            try Data("broken".utf8).write(to: file, options: .atomic)
        } else {
            var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            document["version"] = 999
            try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)
        }
        #expect(await cache.loadDetail(for: identity) == nil)
        await cache.saveDetail(sampleDetail(), for: identity)
        await cache.flush()
        #expect(await cache.loadDetail(for: identity) != nil)
    }

    @Test func directoryConflictsAndOversizedEntriesDoNotPreventLaterReads() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let conflict = f.directory.appending(path: "cache-conflict")
        try Data("existing file".utf8).write(to: conflict)
        let unavailable = RepositoryDiskCache(directory: conflict)
        await unavailable.saveDetail(sampleDetail(), for: identity)
        await unavailable.flush()
        #expect(await unavailable.detailMemoryStatistics.count == 0)
        #expect(await unavailable.loadDetail(for: identity) == nil)
        #expect(try Data(contentsOf: conflict) == Data("existing file".utf8))

        let directory = f.directory.appending(path: "cache")
        let bounded = RepositoryDiskCache(directory: directory, maximumEntryBytes: 8_192)
        var oversized = sampleDetail()
        oversized = RepositoryDetailSnapshot(summary: oversized.summary, changes: oversized.changes,
                                              commits: [.init(id: String(repeating: "a", count: 40), subject: String(repeating: "x", count: 20_000), author: "Author", date: "2026-11-02T00:00:00Z")],
                                              behindCommits: [], observedAt: oversized.observedAt)
        await bounded.saveDetail(oversized, for: identity)
        await bounded.flush()
        #expect(await bounded.detailMemoryStatistics.count == 0)
        #expect(await bounded.loadDetail(for: identity) == nil)
        await bounded.saveDetail(sampleDetail(), for: identity)
        await bounded.flush()
        #expect(await bounded.loadDetail(for: identity) != nil)

        let memoryBounded = RepositoryDiskCache(directory: f.directory.appending(path: "memory-bounded-cache"), maximumMemoryBytes: 8_192)
        await memoryBounded.saveDetail(oversized, for: identity)
        #expect(await memoryBounded.detailMemoryStatistics.estimatedBytes == 0)
        await memoryBounded.saveDetail(sampleDetail(), for: identity)
        await memoryBounded.flush()
        #expect(await memoryBounded.detailMemoryStatistics.estimatedBytes <= 8_192)
        #expect(await memoryBounded.loadDetail(for: identity) != nil)
        await memoryBounded.flush()
    }

    @Test func incompleteResultsKeepSuccessfulDataAndRepositoriesWithoutRemotesAreCacheable() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"))
        let successful = sampleDetail()
        await cache.saveDetail(successful, for: identity)
        await cache.flush()
        var unavailableBase = successful.summary
        unavailableBase.baseError = "Base is temporarily unavailable"
        for summary in [unavailableBase, successful.summary] {
            let incomplete = RepositoryDetailSnapshot(summary: summary, changes: [], commits: nil, behindCommits: [], observedAt: Date())
            await cache.saveDetail(incomplete, for: identity)
            await cache.flush()
            #expect(await cache.loadDetail(for: identity)?.changes == successful.changes)
        }
        let local = RepositoryDetailSnapshot(summary: .init(head: "local", headOID: String(repeating: "c", count: 40), hasRemotes: false),
                                             changes: [], commits: [], behindCommits: nil, observedAt: Date())
        await cache.saveDetail(local, for: identity)
        await cache.flush()
        let restored = try #require(await cache.loadDetail(for: identity))
        #expect(!restored.summary.hasRemotes && restored.summary.head == "local")
        #expect(restored.commits?.isEmpty == true && restored.behindCommits == nil)
    }

    @Test func cacheEntriesNeverFollowSymlinksForReadsOrWrites() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory)
        await cache.saveDetail(sampleDetail(), for: identity)
        await cache.flush()
        let file = try #require(cacheFiles(in: directory).first)
        let target = f.directory.appending(path: "unrelated-data")
        let original = Data("keep unrelated data".utf8)
        try original.write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        #expect(await cache.loadDetail(for: identity) == nil)
        await cache.saveDetail(sampleDetail(), for: identity)
        await cache.flush()
        #expect(try Data(contentsOf: target) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func capacityEvictsLeastRecentlyUsedHistoryAcrossCacheInstances() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let directory = f.directory.appending(path: "cache")
        let clock = DiskCacheTestClock()
        let first = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "1", count: 40), base: String(repeating: "a", count: 40))
        let second = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "2", count: 40), base: String(repeating: "a", count: 40))
        let third = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "3", count: 40), base: String(repeating: "a", count: 40))
        let history = sampleHistory()
        let initial = RepositoryDiskCache(directory: directory, now: { clock.now })
        await initial.saveHistory(history, for: first)
        let file = try #require(cacheFiles(in: directory).first)
        let entryBytes = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let cache = RepositoryDiskCache(directory: directory, maximumBytes: entryBytes * 2 + 32, now: { clock.now })
        clock.advance(1)
        await cache.saveHistory(history, for: second)
        clock.advance(1)
        #expect(await cache.loadHistory(for: first) != nil)
        clock.advance(1)
        await cache.saveHistory(history, for: third)

        #expect(await cache.loadHistory(for: second) == nil)
        #expect(await cache.loadHistory(for: first) != nil)
        #expect(await cache.loadHistory(for: third) != nil)
        let remainingBytes = try cacheFiles(in: directory).reduce(0) { total, file in
            total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(remainingBytes <= entryBytes * 2 + 32)
    }

    @Test func idleCleanupUsesLastAccessInsteadOfTheSnapshotObservationDate() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let clock = DiskCacheTestClock()
        let directory = f.directory.appending(path: "cache")
        let cache = RepositoryDiskCache(directory: directory, maximumIdleAge: 60, now: { clock.now })
        let key = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "a", count: 40), base: String(repeating: "b", count: 40))
        await cache.saveDetail(sampleDetail(observedAt: Date(timeIntervalSince1970: 1)), for: identity)
        await cache.flush()
        clock.advance(30)
        await cache.saveHistory(sampleHistory(), for: key)
        clock.advance(29)
        #expect(await cache.loadDetail(for: identity) != nil)
        clock.advance(36)

        #expect(await cache.loadHistory(for: key) == nil)
        #expect(await cache.loadDetail(for: identity) != nil)
    }

    @Test func replacingTheGitDirectoryAtTheSamePathRejectsOldIdentity() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let originalContext = try await prepareContext(f)
        let originalIdentity = try RepositoryCacheIdentity(context: originalContext)
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"))
        await cache.saveDetail(sampleDetail(), for: originalIdentity)
        await cache.flush()
        let oldGit = f.directory.appending(path: "previous-git")
        let gitDirectory = f.root.appending(path: ".git")
        try FileManager.default.moveItem(at: gitDirectory, to: oldGit)
        try FileManager.default.copyItem(at: oldGit, to: gitDirectory)
        let record = try f.service.store.load(f.root)
        let replacementContext = try await f.service.prepareResourceRead(.group("cached"), in: record)
        let replacementIdentity = try RepositoryCacheIdentity(context: replacementContext)

        #expect(originalIdentity.repository != replacementIdentity.repository)
        #expect(await cache.loadDetail(for: replacementIdentity) == nil)
    }

    @Test func invalidationKeepsUnrelatedRepositoryFamiliesAndDetails() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let other = try await Fixture(createRemote: false); defer { other.remove() }
        let identity = try RepositoryCacheIdentity(context: await prepareContext(f))
        let otherIdentity = try RepositoryCacheIdentity(context: await prepareContext(other))
        let cache = RepositoryDiskCache(directory: f.directory.appending(path: "cache"))
        let first = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "a", count: 40), base: String(repeating: "b", count: 40))
        let second = RepositoryHistoryCacheKey(repository: identity.repository, head: String(repeating: "c", count: 40), base: String(repeating: "b", count: 40))
        let unrelated = RepositoryHistoryCacheKey(repository: otherIdentity.repository, head: first.head, base: first.base)
        await cache.saveDetail(sampleDetail(), for: identity)
        await cache.flush()
        await cache.saveDetail(sampleDetail(), for: otherIdentity)
        await cache.flush()
        for key in [first, second, unrelated] { await cache.saveHistory(sampleHistory(), for: key) }
        await cache.invalidateHistory(for: identity.repository)
        #expect(await cache.loadHistory(for: first) == nil)
        #expect(await cache.loadHistory(for: second) == nil)
        #expect(await cache.loadHistory(for: unrelated) != nil)
        #expect(await cache.loadDetail(for: identity) != nil)
        await cache.invalidateDetail(for: identity)
        #expect(await cache.loadDetail(for: identity) == nil)
        #expect(await cache.loadDetail(for: otherIdentity) != nil)
    }

    @Test func packedReplacementRefsInvalidateMemoizedNormalHistory() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        let context = try await prepareContext(f)
        let session = ResourceReadSession(service: f.service)
        _ = try await f.service.git.run(["pack-refs", "--all"], at: context.path)
        let normal = try await f.service.historyCacheState(context, session: session)
        #expect(normal.reusable)
        #expect(try await f.service.historyCacheState(context, session: session) == normal)
        let head = try #require(try await f.service.git.oid("HEAD", at: context.path))
        let replacement = "refs/replace/" + head
        let tree = try await f.service.git.run(["rev-parse", "HEAD^{tree}"], at: context.path).text
        let replacementOID = try await f.service.git.run(["commit-tree", tree, "-m", "replacement commit"], at: context.path).text
        _ = try await f.service.git.run(["update-ref", replacement, replacementOID], at: context.path)
        _ = try await f.service.git.run(["pack-refs", "--all"], at: context.path)
        #expect(!PathSafety.exists(context.commonDirectory.appending(path: replacement)))
        #expect(try String(contentsOf: context.commonDirectory.appending(path: "packed-refs"), encoding: .utf8).contains(replacement))
        #expect(!(try await f.service.historyCacheState(context, session: session)).reusable)
        _ = try await f.service.git.run(["update-ref", "-d", replacement], at: context.path)
        #expect(try await f.service.historyCacheState(context, session: session).reusable)
    }

    private func prepareContext(_ f: Fixture) async throws -> ResourceReadContext {
        #expect(await f.service.openWorkspace(f.root).status == .success)
        try await f.prepareEmptyGroup("cached")
        return try await f.service.prepareResourceRead(.group("cached"), in: f.service.store.load(f.root))
    }

    private func sampleDetail(observedAt: Date = Date()) -> RepositoryDetailSnapshot {
        let summary = GitSummary(head: "feature", headOID: String(repeating: "a", count: 40), base: "origin/main", baseOID: String(repeating: "b", count: 40))
        return RepositoryDetailSnapshot(summary: summary,
                                        changes: [.init(path: "新目录/new\nname", originalPath: "old\tname", index: "R", workingTree: "M")],
                                        commits: sampleHistory().ahead, behindCommits: sampleHistory().behind, observedAt: observedAt)
    }

    private func sampleHistory() -> RepositoryHistorySnapshot {
        .init(ahead: [.init(id: String(repeating: "a", count: 40), subject: "提交 subject", author: "Author", date: "2026-11-02T00:00:00Z")],
              behind: [.init(id: String(repeating: "b", count: 40), subject: "Base subject", author: "Other author", date: "2026-11-01T00:00:00Z")])
    }

    private func cacheFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
    }
}

private final class DiskCacheTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

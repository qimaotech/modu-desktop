import Foundation
import Testing
@testable import MonoDeckCore

struct RepositoryReadPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MONO_DECK_READ_BENCHMARK"] == "1"))
    func localInspectionColdAndWarmWithManyUntrackedFiles() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        try #require(await fixture.service.openWorkspace(fixture.root).status == .success)
        try #require(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        var record = try fixture.service.store.load(fixture.root)
        let original = record.repositoryURL("repo")
        for index in 1...2 {
            let repository = Repository(url: "https://mono-deck-test.invalid/benchmark-\(index).git")
            let destination = record.repositoryURL(repository.id)
            try FileManager.default.copyItem(at: original, to: destination)
            _ = try await fixture.service.git.run(["remote", "set-url", "origin", repository.url], at: destination)
            record.repositories.append(repository)
        }
        try fixture.service.store.save(record)
        for index in 1...2 { try await fixture.prepareEmptyGroup("benchmark-group-\(index)") }
        record = try fixture.service.store.load(fixture.root)
        for directory in 0..<20 {
            let path = original.appending(path: "untracked-\(directory)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            for file in 0..<100 { try Data("benchmark\n".utf8).write(to: path.appending(path: "file-\(file).txt")) }
        }

        let events = PerformanceReadEvents()
        let service = fixture.service.withDiagnostics(events.diagnostics)
        let resources = Set(service.resources(record))
        let legacy = await measure(events) {
            await service.inspect(record, content: .workingTreeOnly, visibility: .application, concurrency: 2, including: resources)
        }
        try #require(legacy.result.status == .success)
        try report("inspection.legacy", measurement: legacy, properties: ["resources": resources.count, "untracked_files": 2_000])

        let session = ResourceReadSession(service: service, diagnostics: events.diagnostics)
        let cold = await measure(events) { await service.inspectStates(record, including: resources, session: session) }
        try #require(cold.result.status == .success)
        try report("inspection.lightweight.cold", measurement: cold, properties: ["resources": resources.count, "untracked_files": 2_000])
        let warm = await measure(events) { await service.inspectStates(record, including: resources, session: session) }
        try #require(warm.result.status == .success)
        try report("inspection.lightweight.warm", measurement: warm, properties: ["resources": resources.count, "untracked_files": 2_000])
        #expect(warm.events.commandCount < legacy.events.commandCount)
        #expect(cold.events.bytes("command.git.status") < legacy.events.bytes("command.git.status"))
        #expect(warm.events.count("command.git.status") == resources.count)
        #expect(warm.events.count("prepare.hit") == resources.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MONO_DECK_READ_BENCHMARK"] == "1"))
    func repeatedDetailsAndHundredsOfHistoryEntries() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        try #require(await fixture.service.openWorkspace(fixture.root).status == .success)
        try await fixture.prepareEmptyGroup("benchmark")
        let record = try fixture.service.store.load(fixture.root)
        let context = try await fixture.service.prepareResourceRead(.group("benchmark"), in: record)
        let identity = try RepositoryCacheIdentity(context: context)
        let events = PerformanceReadEvents()
        let directory = fixture.directory.appending(path: "benchmark-cache")
        let cache = RepositoryDiskCache(directory: directory, diagnostics: events.diagnostics,
                                        waitForWrite: { try await Task.sleep(for: .seconds(30)) })
        let readerEvents = PerformanceReadEvents()
        let reader = RepositoryDiskCache(directory: directory, diagnostics: readerEvents.diagnostics,
                                         waitForWrite: { try await Task.sleep(for: .seconds(30)) })
        do {
            let snapshot = RepositoryDetailSnapshot(summary: .init(head: "benchmark", headOID: oid(1), hasRemotes: false),
                                                    changes: [], commits: [], behindCommits: nil, observedAt: Date())
            let initial = ContinuousClock.now
            await cache.saveDetail(snapshot, for: identity)
            await cache.flush()
            try report("cache.initial-detail", events: events.take(), elapsed: initial.duration(to: .now))
            let repeated = ContinuousClock.now
            for _ in 0..<100 { await cache.saveDetail(snapshot, for: identity) }
            await cache.flush()
            let unchanged = events.take()
            try report("cache.unchanged-detail", events: unchanged, elapsed: repeated.duration(to: .now), properties: ["saves": 100])
            #expect(unchanged.count("cache.write") == 0 && unchanged.count("cache.encode") == 0 && unchanged.count("cache.scan") == 0)

            let history = RepositoryHistorySnapshot(ahead: (0..<25).map {
                .init(id: oid($0 + 1), subject: "Benchmark commit \($0)", author: "MonoDeck Test", date: "2026-11-02T00:00:00Z")
            }, behind: [])
            let keys = (0..<250).map { RepositoryHistoryCacheKey(repository: identity.repository, head: oid($0 + 100), base: oid(2)) }
            let populated = ContinuousClock.now
            for key in keys { await cache.saveHistory(history, for: key) }
            await cache.flush()
            let writes = events.take()
            try report("cache.history-population", events: writes, elapsed: populated.duration(to: .now), properties: ["entries": keys.count])
            #expect(writes.count("cache.write") == keys.count && writes.count("cache.scan") == 0)

            let reads = ContinuousClock.now
            for key in keys { try #require(await reader.loadHistory(for: key) != nil) }
            let targets = readerEvents.take()
            try report("cache.target-reads", events: targets, elapsed: reads.duration(to: .now), properties: ["entries": keys.count])
            #expect(targets.count("cache.history.hit") == keys.count && targets.count("cache.scan") == 0)
            await reader.flush()
            await cache.flush()
        } catch {
            await reader.flush()
            await cache.flush()
            throw error
        }
    }

    private func measure(_ events: PerformanceReadEvents, operation: () async -> OperationResult) async -> PerformanceMeasurement {
        _ = events.take()
        let start = ContinuousClock.now
        let result = await operation()
        return PerformanceMeasurement(result: result, events: events.take(), elapsed: start.duration(to: .now))
    }

    private func report(_ scenario: String, measurement: PerformanceMeasurement, properties: [String: Int]) throws {
        try report(scenario, events: measurement.events, elapsed: measurement.elapsed, properties: properties)
    }

    private func report(_ scenario: String, events: PerformanceReadEvents.Snapshot, elapsed: Duration, properties: [String: Int] = [:]) throws {
        var payload: [String: Any] = ["scenario": scenario, "counts": events.counts, "output_bytes": events.outputBytes,
                                    "git_commands": events.commandCount, "git_output_bytes": events.commandBytes,
                                    "milliseconds": Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15]
        for (key, value) in properties { payload[key] = value }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("BENCHMARK " + String(decoding: json, as: UTF8.self))
    }

    private func oid(_ value: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 40 - digits.count) + digits
    }
}

private struct PerformanceMeasurement {
    let result: OperationResult
    let events: PerformanceReadEvents.Snapshot
    let elapsed: Duration
}

private final class PerformanceReadEvents: @unchecked Sendable {
    struct Snapshot {
        let counts: [String: Int]
        let outputBytes: [String: Int]
        var commandCount: Int { counts.filter { $0.key.hasPrefix("command.git.") }.values.reduce(0, +) }
        var commandBytes: Int { outputBytes.filter { $0.key.hasPrefix("command.git.") }.values.reduce(0, +) }
        func count(_ name: String) -> Int { counts[name, default: 0] }
        func bytes(_ name: String) -> Int { outputBytes[name, default: 0] }
    }

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var outputBytes: [String: Int] = [:]
    var diagnostics: RepositoryReadDiagnostics {
        .init { [self] event in
            lock.withLock {
                counts[event.name, default: 0] += event.count
                outputBytes[event.name, default: 0] += event.bytes
            }
        }
    }

    func take() -> Snapshot {
        lock.withLock {
            let snapshot = Snapshot(counts: counts, outputBytes: outputBytes)
            counts = [:]; outputBytes = [:]
            return snapshot
        }
    }
}

import Foundation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct ActivationReadSchedulingTests {
    @Test(arguments: [false, true])
    func selectionReusesTenSecondDetailsWithoutExtendingFreshness(_ preloaded: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareEmptyGroup("other")
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let clock = ActivationReadClock(), counts = ActivationReadCounts(), monitor = ActivationResourceMonitor()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: monitor,
                                           now: { clock.now }, diagnostics: counts.diagnostics)
        do {
            if preloaded {
                details.setPreloadScope(in: record, including: [resource])
                details.drainPreload()
                await details.detailPreloadTask?.value
                details.drainPreload()
                await details.snapshotPreloadTask?.value
                #expect(counts.count("detail.preload.completed") == 1)
            } else {
                details.refresh(resource, in: record)
                await details.detailTask?.value
            }
            details.refresh(.group("other"), in: record)
            await details.detailTask?.value
            #expect(monitor.monitoredResource == .group("other"))
            let reads = counts.count("detail.read")
            clock.now = clock.now.advanced(by: .milliseconds(9_999))
            details.refresh(resource, in: record)
            #expect(details.detailTask == nil && !details.snapshotLoading)
            #expect(details.detail.summary != nil && details.detail.uniqueCommits != nil)
            #expect(counts.count("detail.read") == reads && counts.count("detail.selection.hit") == 1)
            #expect(monitor.monitoredResource == resource)

            details.refresh(nil, in: record)
            clock.now = clock.now.advanced(by: .milliseconds(1))
            details.refresh(resource, in: record)
            let expired = try #require(details.detailTask)
            await expired.value
            #expect(counts.count("detail.read") == reads + 1)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func selectionCacheHitsRestoreEventsAndExplicitRequestsBypassCooldown() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let clock = ActivationReadClock(), counts = ActivationReadCounts(), monitor = ActivationResourceMonitor()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: monitor,
                                           now: { clock.now }, diagnostics: counts.diagnostics)
        do {
            details.refresh(resource, in: record)
            await details.detailTask?.value
            details.refresh(nil, in: record)
            details.refresh(resource, in: record)
            #expect(details.detailTask == nil && counts.count("detail.selection.hit") == 1)

            try Data("tracked change".utf8).write(to: record.repositoryURL("repo").appending(path: "README"))
            monitor.emitCandidates(["README"])
            try await eventually { counts.count("detail.read") == 2 && !details.detailLoading }
            #expect(details.detail.changes?.map(\.path) == ["README"])

            details.refresh(resource, in: record, userInitiated: true)
            await details.detailTask?.value
            #expect(counts.count("detail.read") == 3)
            details.refresh(nil, in: record)
            details.invalidate(resources: [resource])
            details.refresh(resource, in: record)
            let invalidated = try #require(details.detailTask)
            await invalidated.value
            #expect(counts.count("detail.read") == 4)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func detailActivationReusesTenSecondResultsButExplicitRequestsBypassThem() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let clock = ActivationReadClock(), counts = ActivationReadCounts()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: ActivationResourceMonitor(),
                                           now: { clock.now }, diagnostics: counts.diagnostics)
        details.refresh(.repository("repo"), in: record)
        await details.detailTask?.value
        #expect(counts.count("detail.read") == 1)
        clock.advance(9)
        details.activate(.repository("repo"), in: record)
        #expect(details.detailTask == nil && counts.count("detail.read") == 1)
        clock.advance(1)
        details.activate(.repository("repo"), in: record)
        await details.detailTask?.value
        #expect(counts.count("detail.read") == 2)
        details.request(.workingTree)
        await details.detailTask?.value
        #expect(counts.count("detail.read") == 3)
        clock.advance(120)
        await Task.yield()
        #expect(details.detailTask == nil && counts.count("detail.read") == 3)
        details.stop(); await details.waitForReads()
    }

    @Test func sideActivationHasItsOwnFreshnessAndIdleDoesNotCreateRequests() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let clock = ActivationReadClock(), counts = ActivationReadCounts()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: ActivationResourceMonitor(),
                                           now: { clock.now }, diagnostics: counts.diagnostics)
        let resource = Resource.repository("repo")
        details.setPreloadScope(in: record, including: [resource])
        details.drainPreload()
        await details.detailPreloadTask?.value
        details.drainPreload()
        await details.snapshotPreloadTask?.value
        #expect(counts.count("sidebar.completed") == 1)
        clock.advance(9)
        details.activatePreload(in: record, including: [resource])
        #expect(details.detailPreloadTask == nil)
        clock.advance(1)
        details.activatePreload(in: record, including: [resource])
        await details.detailPreloadTask?.value
        #expect(counts.count("sidebar.completed") == 2)
        details.activate(resource, in: record)
        await details.detailTask?.value
        #expect(counts.count("detail.read") == 1)
        details.refresh(nil, in: record)
        details.activatePreload(in: record, including: [resource])
        #expect(details.detailPreloadTask == nil)
        clock.advance(120)
        details.drainPreload()
        #expect(details.detailPreloadTask == nil && counts.count("sidebar.completed") == 2)
        details.stop(); await details.waitForReads()
    }

    @Test func failedActivationChecksHaveACooldown() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        var record = try f.service.store.load(f.root)
        record.groups["missing"] = WorktreeGroup()
        try f.service.store.save(record)
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let clock = ActivationReadClock(), counts = ActivationReadCounts()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: ActivationResourceMonitor(),
                                           now: { clock.now }, diagnostics: counts.diagnostics)
        let resource = Resource.group("missing")
        details.refresh(resource, in: record)
        await details.detailTask?.value
        #expect(details.detail.summaryError != nil && counts.count("detail.read") == 1)
        clock.advance(9)
        details.activate(resource, in: record)
        #expect(details.detailTask == nil)
        clock.advance(1)
        details.activate(resource, in: record)
        await details.detailTask?.value
        #expect(counts.count("detail.read") == 2)
        _ = try await f.service.git.run(["worktree", "add", "-b", "missing", record.groupURL("missing").path], at: f.root)
        details.activate(resource, in: record)
        await details.detailTask?.value
        #expect(details.detail.summary != nil && counts.count("detail.read") == 3)
        details.stop(); await details.waitForReads()
    }

    @Test func activationJoinsAnInFlightRead() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let monitor = ActivationResourceMonitor(), gate = ActivationHistoryGate(), counts = ActivationReadCounts()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: monitor, readCommits: { _, _, _ in
            await gate.read()
            return []
        }, diagnostics: counts.diagnostics)
        let resource = Resource.repository("repo")
        details.refresh(resource, in: record)
        do {
            try await eventually { await gate.started }
            details.activate(resource, in: record)
            details.activate(resource, in: record)
            await gate.release()
            await details.detailTask?.value
            #expect(counts.count("detail.read") == 1)
            details.stop(); await details.waitForReads()
        } catch {
            await gate.release()
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func ignoredCandidatesAvoidStatusButTrackedFilesAndOverflowRefresh() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let path = record.repositoryURL("repo")
        try Data("ignored\nREADME\n".utf8).write(to: path.appending(path: ".gitignore"))
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let monitor = ActivationResourceMonitor(), counts = ActivationReadCounts()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: monitor, diagnostics: counts.diagnostics)
        details.refresh(resource, in: record)
        await details.detailTask?.value
        do {
            try Data("ignored".utf8).write(to: path.appending(path: "ignored"))
            monitor.emitCandidates(["ignored"])
            try await eventually { counts.count("events.ignored") == 1 }
            #expect(counts.count("detail.read") == 1)

            try Data("tracked".utf8).write(to: path.appending(path: "README"))
            monitor.emitCandidates(["README"])
            try await eventually { counts.count("detail.read") == 2 && !details.detailLoading }
            #expect(details.detail.changes?.contains { $0.path == "README" } == true)

            monitor.emitCandidates((0...ResourceChangeEvent.maximumCandidateCount).map { "candidate-\($0)" })
            try await eventually { counts.count("detail.read") == 3 && !details.detailLoading }
            monitor.emitCandidates(["../outside"])
            try await eventually { counts.count("detail.read") == 4 && !details.detailLoading }
            monitor.emit([.configuration, .index])
            try await eventually { counts.count("detail.read") == 5 && !details.detailLoading }
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    @Test func switchingBeforeCandidateFilteringInvalidatesTheFormerSelection() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root), resource = Resource.repository("repo")
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let monitor = ActivationResourceMonitor(), counts = ActivationReadCounts()
        let details = GitBrowserModel(service: f.service, defaults: defaults, monitor: monitor, diagnostics: counts.diagnostics)
        details.refresh(resource, in: record)
        await details.detailTask?.value
        do {
            try Data("change".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
            monitor.emitCandidates(["new.txt"])
            try await eventually { counts.count("events.candidates") == 1 }
            details.refresh(nil, in: record)
            details.setPreloadScope(in: record, including: [resource])
            await details.waitForReads()
            details.drainPreload()
            await details.detailPreloadTask?.value
            #expect(details.state(for: resource)?.dirty == true)
            #expect(counts.count("sidebar.completed") == 1)
            details.refresh(resource, in: record)
            let invalidated = try #require(details.detailTask)
            await invalidated.value
            #expect(details.detail.changes?.map(\.path) == ["new.txt"])
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
}

@MainActor private final class ActivationReadClock {
    var now = ContinuousClock.now
    func advance(_ seconds: Int) { now = now.advanced(by: .seconds(seconds)) }
}

private final class ActivationReadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var diagnostics: RepositoryReadDiagnostics { .init { [self] event in lock.withLock { counts[event.name, default: 0] += event.count } } }
    func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
}

private final class ActivationResourceMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (ResourceChangeEvent) -> Void)?
    private var resource: Resource?
    var monitoredResource: Resource? { lock.withLock { resource } }
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool {
        lock.withLock { callback = onChange; resource = context.resource }; return true
    }
    func stop() { lock.withLock { callback = nil; resource = nil } }
    func emit(_ change: ResourceChange) { lock.withLock { callback }?(.init(change: change)) }
    func emitCandidates(_ paths: [String]) { lock.withLock { callback }?(.init(candidatePaths: paths)) }
}

private actor ActivationHistoryGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var started: Bool { !continuations.isEmpty }
    func read() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() { released = true; for continuation in continuations { continuation.resume() }; continuations = [] }
}

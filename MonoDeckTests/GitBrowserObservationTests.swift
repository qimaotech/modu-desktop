import Foundation
import Observation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct GitBrowserObservationTests {
    @Test func sidebarObservationOnlyPublishesChangedResourceStates() async throws {
        try await withDetails { details, _ in
            let resource = Resource.repository("repo"), other = Resource.repository("other")
            let initial = observe(details, resource: resource)
            let clean = ResourceState(resource: resource, available: true, dirty: false)
            details.cache(clean)
            #expect(initial.changed)

            let unchanged = observe(details, resource: resource)
            let otherChanges = observe(details, resource: other)
            details.cache(clean)
            details.invalidateStates(resources: [resource])
            details.cache(.init(resource: other, available: true, dirty: true))
            #expect(!unchanged.changed && otherChanges.changed)

            details.cache(.init(resource: resource, available: false, reason: "Missing", reasonMessage: .resourceIsNotConfigured))
            #expect(unchanged.changed && details.state(for: resource)?.available == false)
            let messageChanges = observe(details, resource: resource)
            details.cache(.init(resource: resource, available: false, reason: "Missing", reasonMessage: .repositoryDirectoryIsMissing))
            #expect(messageChanges.changed)
        }
    }

    @Test func backgroundSnapshotsDoNotNotifyUnchangedSidebarStates() async throws {
        try await withDetails { details, record in
            let resource = Resource.repository("repo")
            details.cache(.init(resource: resource, available: true, dirty: false))
            details.invalidateStates(resources: [resource])
            let changes = observe(details, resource: resource)
            details.setPreloadScope(in: record, including: [resource])
            details.drainPreload()
            await (try #require(details.detailPreloadTask)).value
            #expect(!changes.changed)
            details.drainPreload()
            await (try #require(details.snapshotPreloadTask)).value
            #expect(details.state(for: resource)?.dirty == false && !changes.changed)
        }
    }

    @Test(arguments: ["remove", "replace", "switch"])
    func resourceStructureChangesDiscardOldSidebarStates(_ change: String) async throws {
        try await withDetails { details, record in
            let resource = Resource.repository("repo"), other = Resource.repository("other")
            details.cache(.init(resource: resource, available: true, dirty: true))
            details.cache(.init(resource: other, available: true, dirty: false))
            let changes = observe(details, resource: resource)
            var next = record
            switch change {
            case "remove": next.repositories.removeAll { $0.id == "repo" }
            case "replace": next.repositories[0].url = "https://replacement.invalid/repo.git"
            default: next.root += "/other-workspace"
            }
            details.applyWorkspace(next)
            #expect(changes.changed && details.state(for: resource) == nil)
            #expect(details.state(for: other)?.dirty == (change == "switch" ? nil : false))
        }
    }

    private func observe(_ details: GitBrowserModel, resource: Resource) -> StateChanges {
        let changes = StateChanges()
        withObservationTracking { _ = details.state(for: resource) } onChange: { changes.record() }
        return changes
    }

    private func withDetails(_ body: (GitBrowserModel, WorkspaceRecord) async throws -> Void) async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        var record = try fixture.service.store.load(fixture.root)
        record.repositories.append(Repository(url: "https://mono-deck-test.invalid/other.git"))
        let details = GitBrowserModel(service: fixture.service, defaults: defaults)
        details.applyWorkspace(record)
        do {
            try await body(details, record)
            details.stop(); await details.waitForReads()
        } catch {
            details.stop(); await details.waitForReads()
            throw error
        }
    }
}

private final class StateChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var didChange = false
    var changed: Bool { lock.withLock { didChange } }
    func record() { lock.withLock { didChange = true } }
}

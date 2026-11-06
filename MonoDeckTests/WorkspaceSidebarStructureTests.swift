import Foundation
import Observation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct WorkspaceSidebarStructureTests {
    @Test func membersAndNavigationKeepTheGlobalRepositoryOrder() {
        let structure = WorkspaceSidebarStructure(record: record(root: "/tmp/unused-sidebar-structure"))
        #expect(structure.repositories.map(\.id) == ["repo2", "repo10", "tie-b", "tie-a"])
        #expect(structure.groups.map(\.name) == ["empty", "task2", "task10"])
        #expect(structure.groups[1].members.map(\.id) == ["repo2", "repo10", "tie-a"])
        let groupResources: [Resource] = [
            .group("empty"), .group("task2"),
            .member(groupName: "task2", repositoryID: "repo2"),
            .member(groupName: "task2", repositoryID: "repo10"),
            .member(groupName: "task2", repositoryID: "tie-a"), .group("task10")
        ]
        let expanded: Set<String> = ["task2"]
        let repositories = structure.repositories.map { Resource.repository($0.id) }
        #expect(structure.resources(expandedGroups: expanded) == repositories + groupResources)
        #expect(structure.resources(expandedGroups: expanded, repositoriesExpanded: false) == groupResources)
        #expect(structure.resources(expandedGroups: expanded, groupsExpanded: false) == repositories)
    }

    @Test func workspaceReusesDisplayStructureWhileBusinessDataStaysCurrent() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        var record = record(root: fixture.root.path)
        model.workspace.record = record
        await model.workspace.stopReads()
        let changes = SidebarStructureChanges()
        withObservationTracking { _ = model.workspace.sidebarStructure } onChange: { changes.record() }

        model.workspace.selection = .repository("repo2")
        model.workspace.expandedGroups = ["task2"]
        model.workspace.details.cache(.init(resource: .repository("repo10"), available: true, dirty: true))
        record.repositories[0].url = "https://replacement.invalid/repo10.git"
        model.workspace.record = record
        #expect(!changes.changed)
        #expect(model.workspace.sortedRepositories.first { $0.id == "repo10" }?.url == record.repositories[0].url)

        record.repositories[0].displayNameOverride = "First"
        model.workspace.record = record
        #expect(changes.changed && model.workspace.sidebarStructure.repositories.first?.id == "repo10")
        record.groups["task2"]?.repositoryIDs = ["repo2"]
        model.workspace.record = record
        #expect(model.workspace.sidebarStructure.groups[1].members.map(\.id) == ["repo2"])
        model.workspace.record = nil
        #expect(model.workspace.visibleResources.isEmpty && model.workspace.sidebarStructure.groups.isEmpty)
    }

    private func record(root: String) -> WorkspaceRecord {
        var record = WorkspaceRecord(root: root)
        record.repositories = [
            Repository(url: "https://example.invalid/repo10.git", displayNameOverride: "Service 10"),
            Repository(url: "https://example.invalid/repo2.git", displayNameOverride: "Service 2"),
            Repository(url: "https://example.invalid/tie-b.git", displayNameOverride: "Shared"),
            Repository(url: "https://example.invalid/tie-a.git", displayNameOverride: "Shared")
        ]
        record.groups = [
            "task10": WorktreeGroup(branchName: "task10", repositoryIDs: ["tie-b"]),
            "task2": WorktreeGroup(branchName: "task2", repositoryIDs: ["tie-a", "repo10", "repo2"]),
            "empty": WorktreeGroup(branchName: "empty", repositoryIDs: [])
        ]
        return record
    }
}

private final class SidebarStructureChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var didChange = false
    var changed: Bool { lock.withLock { didChange } }
    func record() { lock.withLock { didChange = true } }
}

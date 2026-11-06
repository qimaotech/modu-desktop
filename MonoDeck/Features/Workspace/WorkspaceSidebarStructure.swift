import Foundation
import MonoDeckCore

struct WorkspaceSidebarStructure {
    struct RepositoryItem: Identifiable, Equatable {
        let id: String
        let title: String
    }

    struct Group: Identifiable {
        let name: String
        let members: [RepositoryItem]
        var id: String { name }
    }

    let repositories: [RepositoryItem]
    let groups: [Group]
    private let input: Input

    init(record: WorkspaceRecord? = nil) { self.init(input: Input(record)) }

    func updated(for record: WorkspaceRecord?) -> WorkspaceSidebarStructure? {
        let next = Input(record)
        guard input != next else { return nil }
        return WorkspaceSidebarStructure(input: next)
    }

    func resources(expandedGroups: Set<String>, repositoriesExpanded: Bool = true, groupsExpanded: Bool = true) -> [Resource] {
        var result: [Resource] = repositoriesExpanded ? repositories.map { .repository($0.id) } : []
        if groupsExpanded {
            for group in groups {
                result.append(.group(group.name))
                if expandedGroups.contains(group.name) {
                    result.append(contentsOf: group.members.map { .member(groupName: group.name, repositoryID: $0.id) })
                }
            }
        }
        return result
    }

    private init(input: Input) {
        self.input = input
        let repositories = input.repositories.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.repositories = repositories
        groups = input.groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let memberIDs = input.groups[name] ?? []
            return Group(name: name, members: repositories.filter { memberIDs.contains($0.id) })
        }
    }

    private struct Input: Equatable {
        let repositories: [RepositoryItem]
        let groups: [String: Set<String>]
        let locale = Locale.current.identifier

        init(_ record: WorkspaceRecord?) {
            repositories = record?.repositories.map { repository in
                let id = repository.id
                return RepositoryItem(id: id, title: repository.displayNameOverride ?? id)
            } ?? []
            groups = record?.groups.mapValues { Set($0.repositoryIDs) } ?? [:]
        }
    }
}

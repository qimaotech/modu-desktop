import Foundation

extension WorkspaceService {
    public func workspaceTree(_ root: URL) async throws -> WorkspaceTreeNode {
        let record = try await read(root)
        let reader = inspectionService(for: .localOnly)
        try await reader.git.checkRepository(record.rootURL, main: true)
        var children: [WorkspaceTreeNode] = []
        var validRepositories = Set<String>()
        if hasTreeDirectory("repositories", in: record) {
            var repositories: [WorkspaceTreeNode] = []
            for repository in record.repositories.sorted(by: { $0.id < $1.id }) {
                if try await reader.isValidTreeResource(.repository(repository.id), in: record) {
                    repositories.append(.init(.mainWorktree, path: repository.id))
                    validRepositories.insert(repository.id)
                }
            }
            children.append(.init(.auxiliaryDirectory, path: "repositories", children: repositories))
        }
        if hasTreeDirectory("worktrees", in: record) {
            var groups: [WorkspaceTreeNode] = []
            for name in record.groups.keys.sorted() {
                guard try await reader.isValidTreeResource(.group(name), in: record) else { continue }
                var members: [WorkspaceTreeNode] = []
                for repository in record.groups[name]!.repositories.sorted() where validRepositories.contains(repository) {
                    if try await reader.isValidTreeResource(.member(name, repository), in: record) {
                        members.append(.init(.linkedWorktree, path: repository))
                    }
                }
                groups.append(.init(.group, path: name, children: members))
            }
            children.append(.init(.auxiliaryDirectory, path: "worktrees", children: groups))
        }
        try checkCancellation()
        return .init(.workspace, path: record.root, children: children)
    }

    private func hasTreeDirectory(_ path: String, in record: WorkspaceRecord) -> Bool {
        (try? PathSafety.child(path, of: record.rootURL, allowMissing: false)) != nil
    }

    private func isValidTreeResource(_ resource: Resource, in record: WorkspaceRecord) async throws -> Bool {
        try checkCancellation()
        do {
            _ = try await checked(resource, in: record)
            try checkCancellation()
            return true
        } catch let error as ModuError where error.code == "cancelled" { throw error }
        catch {
            try checkCancellation()
            return false
        }
    }
}

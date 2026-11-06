import Foundation

extension WorkspaceService {
    public func workspaceTree(_ root: URL) async throws -> WorkspaceTreeNode {
        let record = try await read(root)
        let reader = inspectionService()
        try await reader.git.checkRepository(record.rootURL, main: true)
        var children: [WorkspaceTreeNode] = []
        if hasTreeDirectory("repositories", in: record) {
            var repositories: [WorkspaceTreeNode] = []
            for repository in record.repositories.sorted(by: { $0.id < $1.id }) {
                if try hasTreeWorktree(.repository(repository.id), in: record) {
                    repositories.append(.init(.mainWorktree, path: repository.id))
                }
            }
            children.append(.init(.auxiliaryDirectory, path: "repositories", children: repositories))
        }
        if hasTreeDirectory("worktrees", in: record) {
            var groups: [WorkspaceTreeNode] = []
            for name in record.groups.keys.sorted() {
                guard try hasTreeWorktree(.group(name), in: record) else { continue }
                var members: [WorkspaceTreeNode] = []
                for repository in record.groups[name]!.repositoryIDs.sorted() {
                    if try hasTreeWorktree(.member(groupName: name, repositoryID: repository), in: record) {
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

    private func hasTreeWorktree(_ resource: Resource, in record: WorkspaceRecord) throws -> Bool {
        try checkCancellation()
        do {
            try store.checkBoundary(record.rootURL)
            let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.appending(path: ".git").path)
            let expected: FileAttributeType = resource.kind == .repository ? .typeDirectory : .typeRegular
            return attributes[.type] as? FileAttributeType == expected
        } catch { return false }
    }
}

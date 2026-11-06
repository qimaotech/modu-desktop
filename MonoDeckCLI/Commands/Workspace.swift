import Foundation
import ArgumentParser
import MonoDeckCore

struct Workspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect the local workspace structure.", subcommands: [Tree.self])
    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show registered worktree directories as a read-only tree.",
            discussion: "Does not modify workspace records or fetch repositories. Missing directories, symbolic links, and incompatible .git layouts are omitted. This structural view does not validate Git health or repository ownership. JSON returns the tree in data.tree of the operation result; root paths are absolute and child paths are relative to their parent.")
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService()
            let root = try await options.root(service)
            let tree = try await service.workspaceTree(root)
            finish(.init(command: "workspace.tree", workspace: root.path, data: .init(tree: tree)), json: options.json)
        }
    }
}

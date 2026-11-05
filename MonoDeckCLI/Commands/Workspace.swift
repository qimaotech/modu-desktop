import Foundation
import ArgumentParser
import MonoDeckCore

struct Workspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect the local workspace structure.", subcommands: [Tree.self])
    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show valid registered worktrees as a read-only directory tree.",
            discussion: "Does not modify workspace records or fetch repositories. Missing or invalid resources are omitted. JSON returns the tree in data.tree of the operation result; root paths are absolute and child paths are relative to their parent.")
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService()
            let root = try await options.root(service)
            let tree = try await service.workspaceTree(root)
            finish(.init(command: "workspace.tree", workspace: root.path, data: .init(tree: tree)), json: options.json)
        }
    }
}

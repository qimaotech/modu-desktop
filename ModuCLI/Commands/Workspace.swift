import Foundation
import ArgumentParser
import ModuCore

struct Workspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Inspect.self])
    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show valid registered worktrees as a read-only directory tree.",
            discussion: "Does not modify workspace records or fetch repositories. Missing or invalid resources are omitted. JSON nodes contain type, path, and children; the root path is absolute and each child path is relative to its parent.")
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService()
            let tree = try await service.workspaceTree(try await options.root(service))
            try finish(tree, json: options.json)
        }
    }
}

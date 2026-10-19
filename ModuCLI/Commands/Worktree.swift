import Foundation
import ArgumentParser
import ModuCore
import Darwin

struct Worktree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Create.self, Update.self, Remove.self])
    struct List: AsyncParsableCommand {
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            var result = await service.inspect(root, scope: .worktrees)
            result.command = "worktree.list"
            result.items.removeAll { item in
                if item.resource.kind == .workspace { return item.status != .failed }
                return ![.group, .member].contains(item.resource.kind)
            }
            if result.reasonCode == nil { result.summarize() }
            finish(result, json: options.json)
        }
    }
    struct Create: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Argument var group: String
        @Option(name: .long, parsing: .singleValue) var repo: [String] = []
        mutating func validate() throws { guard !repo.isEmpty else { throw ValidationError("At least one --repo is required.") } }
        mutating func run() async throws {
            let service = WorkspaceService()
            finish(await service.createGroup(group, repositories: repo, at: try options.root(service), progress: reportProgress), json: options.json)
        }
    }
    struct Update: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Argument var group: String
        @Option(name: .long, parsing: .singleValue) var repo: [String] = []
        @Flag(name: .long) var execute = false
        mutating func validate() throws { guard !repo.isEmpty else { throw ValidationError("At least one --repo is required. Remove individual members to retain an empty group.") } }
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            var result = await service.editGroup(group, repositories: repo, at: root, progress: reportProgress)
            if result.status == .confirmationRequired, execute || (!options.json && isatty(STDIN_FILENO) == 1 && confirm(result.plan ?? [])) {
                result = await service.editGroup(group, repositories: repo, at: root, authorization: result.plan, progress: reportProgress)
            }
            finish(result, json: options.json)
        }
    }
    struct Remove: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Argument var group: String
        @Option(name: .long) var repo: String?
        @Flag(name: .long) var execute = false
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            let request: DeleteRequest = repo.map { .member(group: group, repo: $0) } ?? .group(group)
            var result = await service.remove(request, at: root, execute: execute, progress: reportProgress)
            if result.status == .confirmationRequired, !options.json, isatty(STDIN_FILENO) == 1, confirm(result.plan ?? []) {
                result = await service.remove(request, at: root, authorization: result.plan, progress: reportProgress)
            }
            finish(result, json: options.json)
        }
    }
}

import Foundation
import ArgumentParser
import ModuCore
import Darwin

struct Repo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Add.self, Remove.self])
    struct List: AsyncParsableCommand {
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            var result = await service.inspect(root, scope: .repositories)
            result.command = "repo.list"
            result.items.removeAll { item in
                if item.resource.kind == .workspace { return item.status != .failed }
                return item.resource.kind != .repository
            }
            if result.reasonCode == nil { result.summarize() }
            finish(result, json: options.json)
        }
    }
    struct Add: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Argument var url: String
        @Option(name: .long) var name: String?
        mutating func run() async throws {
            let service = WorkspaceService()
            finish(await service.addRepository(.init(url: url, name: name), at: try options.root(service), progress: reportProgress), json: options.json)
        }
    }
    struct Remove: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Argument var repoName: String
        @Flag(name: .long) var execute = false
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            var result = await service.remove(.repository(repoName), at: root, execute: execute, progress: reportProgress)
            if result.status == .confirmationRequired, !options.json, isatty(STDIN_FILENO) == 1, confirm(result.plan ?? []) {
                result = await service.remove(.repository(repoName), at: root, authorization: result.plan, progress: reportProgress)
            }
            finish(result, json: options.json)
        }
    }
}

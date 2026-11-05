import Foundation
import ArgumentParser
import MonoDeckCore

struct Repo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage registered business repositories.", subcommands: [List.self, Add.self, Delete.self])
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered repositories with their local status.")
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try await options.root(service)
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
        static let configuration = CommandConfiguration(abstract: "Clone and register a remote repository.")
        @OptionGroup var options: Options
        @OptionGroup var mutation: MutationOptions
        @Argument var url: String
        @Option(name: .customLong("display-name"), help: ArgumentHelp("An optional display name, independent of the repository ID.", valueName: "display-name")) var displayNameOverride: String?
        mutating func run() async throws {
            let service = WorkspaceService(), root = try await options.root(service)
            let repository = Repository(url: url, displayNameOverride: displayNameOverride)
            await runMutation(options: options, mutation: mutation,
                preview: { await service.addRepository(repository, at: root, dryRun: true) },
                execute: { _ in await service.addRepository(repository, at: root, progress: reportProgress) })
        }
    }
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete managed members and move the main repository to Trash.")
        @OptionGroup var options: Options
        @OptionGroup var mutation: MutationOptions
        @Argument(help: ArgumentHelp("The repository ID, independent of its display name.", valueName: "repository-id")) var repositoryID: String
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try await options.root(service)
            let request = DeleteRequest.repository(repositoryID)
            await runMutation(options: options, mutation: mutation,
                preview: { await service.delete(request, at: root, dryRun: true) },
                execute: { plan in await service.delete(request, at: root, authorization: plan?.deletions, progress: reportProgress) })
        }
    }
}

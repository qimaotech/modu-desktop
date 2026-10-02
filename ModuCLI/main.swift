import Foundation
import ArgumentParser
import ModuCore
import Darwin

struct Modu: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "modu-cli", abstract: "Manage Modu workspaces and worktree groups.", version: "0.1.0", subcommands: [Workspace.self, Repo.self, Worktree.self])
}
struct Options: ParsableArguments {
    @Option(name: .long, help: "An existing workspace root.") var workspace: String?
    @Flag(name: .long, help: "Write one final JSON document to stdout.") var json = false
    func root(_ service: WorkspaceService) throws -> URL { try service.store.locate(explicit: workspace, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) }
}
struct Workspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Inspect.self])
    struct Inspect: AsyncParsableCommand {
        @OptionGroup var options: Options
        mutating func run() async throws { let service = WorkspaceService(); finish(await service.inspect(try options.root(service)), json: options.json) }
    }
}
struct Repo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Add.self, Remove.self])
    struct List: AsyncParsableCommand {
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            var result = await service.inspect(root); result.command = "repo.list"; result.items.removeAll { $0.resource.kind != "repository" }; if result.reasonCode == nil { result.summarize() }
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
            if result.status == "confirmation-required", !options.json, isatty(STDIN_FILENO) == 1, confirm(result.plan ?? []) {
                result = await service.remove(.repository(repoName), at: root, authorization: result.plan, progress: reportProgress)
            }
            finish(result, json: options.json)
        }
    }
}
struct Worktree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Create.self, Update.self, Remove.self])
    struct List: AsyncParsableCommand {
        @OptionGroup var options: Options
        mutating func run() async throws {
            let service = WorkspaceService(); let root = try options.root(service)
            var result = await service.inspect(root); result.command = "worktree.list"; result.items.removeAll { !["group", "member"].contains($0.resource.kind) }; if result.reasonCode == nil { result.summarize() }
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
            if result.status == "confirmation-required", execute || (!options.json && isatty(STDIN_FILENO) == 1 && confirm(result.plan ?? [])) {
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
            if result.status == "confirmation-required", !options.json, isatty(STDIN_FILENO) == 1, confirm(result.plan ?? []) {
                result = await service.remove(request, at: root, authorization: result.plan, progress: reportProgress)
            }
            finish(result, json: options.json)
        }
    }
}
func reportProgress(_ value: OperationProgress) { diagnostic("\(value.target): \(value.phase)") }
func diagnostic(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func confirm(_ targets: [DeletionTarget]) -> Bool {
    for target in targets { diagnostic("\(target.path)\n\(target.risks.joined(separator: "\n"))") }
    diagnostic("Permanently delete the listed worktrees and current local branches? [y/N]")
    var input = Data()
    while !Task.isCancelled {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 100) > 0 {
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) != 1 || byte == 10 { break }
            input.append(byte)
            if input.count > 32 { return false }
        }
    }
    return !Task.isCancelled && ["y", "yes"].contains(String(decoding: input, as: UTF8.self).lowercased())
}
func finish(_ value: OperationResult, json: Bool) -> Never {
    var result = value
    if Task.isCancelled && result.status == "confirmation-required" { result.status = "cancelled"; result.reasonCode = "cancelled" }
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { let data = try encoder.encode(result); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        catch { diagnostic("Could not encode result."); exit(1) }
    } else {
        print("\(result.command): \(result.status)")
        if let message = result.message { print(message) }
        for item in result.items {
            print("\(item.resource.path): \(item.status)\(item.message.map { " — " + $0 } ?? "")")
            for effect in item.effects { print("  \(effect.action): \(effect.target) [\(effect.state)]") }
            if let trash = item.trashPath { print("  Trash: \(trash)") }
        }
        for target in result.plan ?? [] { print("\(target.path)\n\(target.risks.joined(separator: "\n"))") }
    }
    exit(result.exitCode)
}
func normalizedArguments(_ arguments: [String]) -> [String] {
    var regular: [String] = [], global: [String] = [], index = 0
    while index < arguments.count {
        let value = arguments[index]
        if value == "--" { regular += arguments[index...]; break }
        if value == "--json" || value.hasPrefix("--workspace=") { global.append(value) }
        else if value == "--workspace", index + 1 < arguments.count { global += [value, arguments[index + 1]]; index += 1 }
        else { regular.append(value) }
        index += 1
    }
    return regular + global
}
let original = Array(CommandLine.arguments.dropFirst())
let task = Task {
    do {
        var command = try Modu.parseAsRoot(normalizedArguments(original))
        if var command = command as? any AsyncParsableCommand { try await command.run() }
        else { try command.run() }
    } catch {
        if Modu.exitCode(for: error) == .success { Modu.exit(withError: error) }
        if original.contains("--json") || error is ModuError {
            let failure = (error as? ModuError) ?? ModuError("invalid-input", Git.sanitize(Modu.message(for: error)))
            finish(.init(command: normalizedArguments(original).prefix(2).joined(separator: "."), workspace: nil, status: "failed", error: failure), json: original.contains("--json"))
        }
        Modu.exit(withError: error)
    }
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
interrupt.setEventHandler { task.cancel() }; terminate.setEventHandler { task.cancel() }
interrupt.resume(); terminate.resume()
await task.value

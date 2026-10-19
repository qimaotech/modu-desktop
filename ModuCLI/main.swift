import Foundation
import ArgumentParser
import ModuCore
import Darwin

struct Modu: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "modu-cli", abstract: "Manage Modu workspaces and worktree groups.", version: ModuVersion.current, subcommands: [Workspace.self, Repo.self, Worktree.self])
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
            finish(.init(command: normalizedArguments(original).prefix(2).joined(separator: "."), workspace: nil, status: .failed, error: failure), json: original.contains("--json"))
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

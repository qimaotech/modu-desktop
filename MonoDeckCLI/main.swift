import Foundation
import ArgumentParser
import MonoDeckCore
import Darwin

struct MonoDeck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mono-deck", abstract: "Manage MonoDeck workspaces and worktree groups.", version: MonoDeckVersion.current, subcommands: [Workspace.self, Repo.self, Worktree.self])
}
let original = Array(CommandLine.arguments.dropFirst())
let task = Task {
    do {
        if original.first == "--internal-relaunch" {
            guard original.count >= 4, let pid = Int32(original[3]) else {
                throw MonoDeckError("invalid-input", "Invalid relaunch arguments.")
            }
            try await AppRelauncher().run(application: URL(fileURLWithPath: original[1]), directory: URL(fileURLWithPath: original[2]),
                                        parentPID: pid, arguments: Array(original.dropFirst(4)))
            return
        }
        if original.first == "--internal-install-update" {
            guard original.count == 3, let pid = Int32(original[2]) else {
                throw MonoDeckError("invalid-input", "Invalid update installer arguments.")
            }
            try await AppUpdateInstaller().run(directory: URL(fileURLWithPath: original[1]), parentPID: pid)
            return
        }
        var command = try MonoDeck.parseAsRoot(normalizedArguments(original))
        if var command = command as? any AsyncParsableCommand { try await command.run() }
        else { try command.run() }
    } catch {
        if MonoDeck.exitCode(for: error) == .success { MonoDeck.exit(withError: error) }
        if original.contains("--json") || error is MonoDeckError {
            let failure = (error as? MonoDeckError) ?? MonoDeckError("invalid-input", Git.sanitize(MonoDeck.message(for: error)))
            finish(.init(command: normalizedArguments(original).prefix(2).joined(separator: "."), workspace: nil, status: .failed, error: failure), json: original.contains("--json"))
        }
        MonoDeck.exit(withError: error)
    }
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
interrupt.setEventHandler { task.cancel() }; terminate.setEventHandler { task.cancel() }
interrupt.resume(); terminate.resume()
await task.value

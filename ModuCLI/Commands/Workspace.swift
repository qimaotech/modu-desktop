import Foundation
import ArgumentParser
import ModuCore

struct Workspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Inspect.self])
    struct Inspect: AsyncParsableCommand {
        @OptionGroup var options: Options
        mutating func run() async throws { let service = WorkspaceService(); finish(await service.inspect(try options.root(service)), json: options.json) }
    }
}

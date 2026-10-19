import Foundation
import ArgumentParser
import ModuCore

struct Options: ParsableArguments {
    @Option(name: .long, help: "An existing workspace root.") var workspace: String?
    @Flag(name: .long, help: "Write one final JSON document to stdout.") var json = false
    func root(_ service: WorkspaceService) throws -> URL { try service.store.locate(explicit: workspace, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) }
}

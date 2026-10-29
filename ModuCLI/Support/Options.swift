import Foundation
import ArgumentParser
import ModuCore

struct Options: ParsableArguments {
    @Option(name: .long, help: "An existing workspace root.") var workspace: String?
    @Flag(name: .long, help: "Write one final JSON document to stdout.") var json = false
    func root(_ service: WorkspaceService) async throws -> URL { try await service.store.locate(explicit: workspace, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) }
}

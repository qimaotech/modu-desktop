#if DEBUG
import Foundation
@testable import ModuCore

enum MockWorkspacePreparation {
    static func prepare(directory: URL = TestEnvironment.temporaryDirectory.appending(path: "modu-mock-\(UUID().uuidString.lowercased())"),
                        buildCommand: [String] = []) async throws -> MockWorkspaceFixture {
        var arguments = [script.path, "prepare", "--directory", directory.path]
        if !buildCommand.isEmpty { arguments += ["--build"] + buildCommand }
        do {
            let output = try await CommandRunner().run("/usr/bin/python3", arguments, timeout: 30)
            guard output.status == 0 else { throw ModuError("mock-unavailable", String(decoding: output.stderr, as: UTF8.self)) }
            return try MockWorkspaceFixture(workspace: directory.appending(path: "example-workspace"))
        } catch {
            _ = try? await CommandRunner().run("/usr/bin/python3", [script.path, "cleanup", "--directory", directory.path], cancellable: false)
            throw error
        }
    }

    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "script/prepare_mock_workspace.py")
}
#endif

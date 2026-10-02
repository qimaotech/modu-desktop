#if DEBUG
import Foundation

public struct MockWorkspaceFixture: Sendable {
    public let directory: URL
    public let root: URL
    public let identifier: String
    public let service: WorkspaceService

    public init(workspace: URL) throws {
        let root = PathSafety.canonical(workspace)
        let directory = root.deletingLastPathComponent()
        let bases = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")].map(PathSafety.canonical)
        guard root.lastPathComponent == "example-workspace", directory.lastPathComponent.hasPrefix("modu-mock-"),
              bases.contains(where: { directory.path.hasPrefix($0.path + "/") }) else {
            throw ModuError("mock-unavailable", "Expected a prepared workspace inside an owned temporary mock directory.")
        }
        try PathSafety.directory(root)
        let marker = try Self.file("mock-session.json", in: directory)
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: marker))
        let identifier = String(directory.lastPathComponent.dropFirst("modu-mock-".count))
        guard session.version == 1, session.scenario == "linked-worktree-selected", session.ready,
              UUID(uuidString: identifier) != nil, session.identifier == identifier,
              PathSafety.canonical(URL(fileURLWithPath: session.workspace)).path == root.path else {
            throw ModuError("mock-unavailable", "Mock workspace has not been prepared successfully.")
        }
        let config = try Self.file("gitconfig", in: directory)
        let support = try PathSafety.child("support", of: directory, allowMissing: false)
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = config.path
        environment["GIT_ALLOW_PROTOCOL"] = "file"
        environment["HOME"] = directory.appending(path: "home").path
        environment["PATH"] = directory.appending(path: "home/.local/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_AUTHOR_NAME"] = "Jamie Lee"; environment["GIT_AUTHOR_EMAIL"] = "jamie@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Jamie Lee"; environment["GIT_COMMITTER_EMAIL"] = "jamie@example.invalid"
        environment["GIT_AUTHOR_DATE"] = "2026-08-29T00:00:00Z"; environment["GIT_COMMITTER_DATE"] = "2026-08-29T00:00:00Z"
        let trash = directory.appending(path: "trash")
        self.directory = directory; self.root = root; self.identifier = identifier
        service = WorkspaceService(store: .init(support: support, directoryBoundary: directory), git: Git(runner: CommandRunner(environment: environment)), trash: { source in
            try PathSafety.confined(source, to: directory)
            try PathSafety.confined(trash, to: directory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        })
    }

    public func load() async throws -> WorkspaceRecord { try await service.load(root) }

    public func remove() {
        let marker = directory.appending(path: "mock-session.json")
        guard let bytes = try? Data(contentsOf: marker), let session = try? JSONDecoder().decode(Session.self, from: bytes),
              session.identifier == identifier, PathSafety.canonical(URL(fileURLWithPath: session.workspace)).path == root.path else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func file(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appending(path: name)
        guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw ModuError("mock-unavailable", "Expected a regular mock data file: \(file.path)")
        }
        return file
    }

    private struct Session: Decodable {
        let version: Int
        let identifier: String
        let scenario: String
        let workspace: String
        let ready: Bool
    }
}
#endif

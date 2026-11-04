import Foundation

public struct Repository: Codable, Equatable, Identifiable, Sendable {
    public var url: String
    public var name: String?
    public var id: String { (try? RepositoryIdentity(url).name) ?? "invalid-repository" }
    public var displayName: String { name ?? id }
    public init(url: String, name: String? = nil) { self.url = url; self.name = name }
}

public struct WorktreeGroup: Codable, Equatable, Sendable {
    public var createdAt: String
    public var repositories: [String]
    enum CodingKeys: String, CodingKey { case createdAt = "created-at", repositories }
    public init(createdAt: String = ISO8601DateFormatter().string(from: Date()), repositories: [String] = []) {
        self.createdAt = createdAt; self.repositories = repositories
    }
}

public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var root: String
    public var repositories: [Repository] = []
    public var groups: [String: WorktreeGroup] = [:]
    public init(root: String) { self.root = root }
    public var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
    public func repositoryURL(_ name: String) -> URL { rootURL.appending(path: "repositories/\(name)") }
    public func groupURL(_ name: String) -> URL { rootURL.appending(path: "worktrees/\(name)") }
    public func memberURL(_ group: String, _ repo: String) -> URL { groupURL(group).appending(path: repo) }
}

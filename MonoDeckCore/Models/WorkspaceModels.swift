import Foundation

public struct Repository: Codable, Equatable, Identifiable, Sendable {
    public var url: String
    public var displayNameOverride: String?
    public var id: String { (try? RepositoryIdentity(url).id) ?? "invalid-repository" }
    public var displayName: String { displayNameOverride ?? id }
    enum CodingKeys: String, CodingKey { case url, displayNameOverride = "display-name" }
    public init(url: String, displayNameOverride: String? = nil) { self.url = url; self.displayNameOverride = displayNameOverride }
}

public struct WorktreeGroup: Codable, Equatable, Sendable {
    public var createdAt: String
    public var repositoryIDs: [String]
    enum CodingKeys: String, CodingKey { case createdAt = "created-at", repositoryIDs = "repository-ids" }
    public init(createdAt: String = ISO8601DateFormatter().string(from: Date()), repositoryIDs: [String] = []) {
        self.createdAt = createdAt; self.repositoryIDs = repositoryIDs
    }
}

public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public var version: Int = 2
    public var root: String
    public var repositories: [Repository] = []
    public var groups: [String: WorktreeGroup] = [:]
    public init(root: String) { self.root = root }
    public var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
    public func repositoryURL(_ repositoryID: String) -> URL { rootURL.appending(path: "repositories/\(repositoryID)") }
    public func groupURL(_ groupName: String) -> URL { rootURL.appending(path: "worktrees/\(groupName)") }
    public func memberURL(_ groupName: String, _ repositoryID: String) -> URL { groupURL(groupName).appending(path: repositoryID) }
}

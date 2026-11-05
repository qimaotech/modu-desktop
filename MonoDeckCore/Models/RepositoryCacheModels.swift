import Foundation
import Darwin

public struct RepositoryCacheIdentity: Codable, Hashable, Sendable {
    public let repository: RepositoryCacheRepositoryIdentity
    public let resource: Resource
    public let groupCreatedAt: String?
    public let worktree: RepositoryCachePathIdentity
    public let gitDirectory: RepositoryCachePathIdentity

    public init(context: ResourceReadContext) throws {
        try self.init(resource: context.resource, workspace: context.workspace, path: context.path,
                      gitDirectory: context.gitDirectory, commonDirectory: context.commonDirectory)
    }

    init(resource: Resource, workspace: WorkspaceRecord, path: URL, gitDirectory: URL, commonDirectory: URL) throws {
        repository = try RepositoryCacheRepositoryIdentity(resource: resource, workspace: workspace, commonDirectory: commonDirectory)
        self.resource = resource
        groupCreatedAt = resource.groupName.flatMap { workspace.groups[$0]?.createdAt }
        worktree = try RepositoryCachePathIdentity(path)
        self.gitDirectory = try RepositoryCachePathIdentity(gitDirectory)
    }

    public func isCurrent() -> Bool { repository.isCurrent() && worktree.isCurrent() && gitDirectory.isCurrent() }
}

public struct RepositoryCacheRepositoryIdentity: Codable, Hashable, Sendable {
    public let workspace: String
    public let repositoryID: String?
    public let repositoryURL: String?
    public let commonDirectory: RepositoryCachePathIdentity
    enum CodingKeys: String, CodingKey { case workspace, repositoryURL, commonDirectory; case repositoryID = "repository-id" }

    public init(context: ResourceReadContext) throws {
        try self.init(resource: context.resource, workspace: context.workspace, commonDirectory: context.commonDirectory)
    }

    init(resource: Resource, workspace: WorkspaceRecord, commonDirectory: URL) throws {
        self.workspace = PathSafety.identity(workspace.rootURL)
        repositoryID = resource.repositoryID
        repositoryURL = repositoryID.flatMap { repositoryID in workspace.repositories.first { $0.id == repositoryID }?.url }
        self.commonDirectory = try RepositoryCachePathIdentity(commonDirectory)
    }

    func isCurrent() -> Bool { commonDirectory.isCurrent() }
}

public struct RepositoryCachePathIdentity: Codable, Hashable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64

    init(_ url: URL) throws {
        let canonical = PathSafety.canonical(url)
        var metadata = stat()
        guard lstat(canonical.path, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
        path = canonical.path
        device = UInt64(bitPattern: Int64(metadata.st_dev))
        inode = UInt64(metadata.st_ino)
    }

    func isCurrent() -> Bool { (try? Self(URL(fileURLWithPath: path))) == self }
}

public struct RepositoryDetailSnapshot: Codable, Sendable {
    public let summary: GitSummary
    public let changes: [FileChange]
    public let uniqueCommits: [GitCommit]?
    public let behindCommits: [GitCommit]?
    public let observedAt: Date

    public init(summary: GitSummary, changes: [FileChange], uniqueCommits: [GitCommit]?, behindCommits: [GitCommit]?, observedAt: Date) {
        self.summary = summary; self.changes = changes; self.uniqueCommits = uniqueCommits
        self.behindCommits = behindCommits; self.observedAt = observedAt
    }

    func hasSameContent(as other: Self) -> Bool {
        summary == other.summary && changes == other.changes && uniqueCommits == other.uniqueCommits && behindCommits == other.behindCommits
    }

    var isComplete: Bool {
        guard summary.baseError == nil, summary.baseMessage == nil else { return false }
        if summary.hasRemotes { return summary.base != nil && summary.baseOID != nil && uniqueCommits != nil && behindCommits != nil }
        return uniqueCommits != nil
    }

    private enum CodingKeys: String, CodingKey { case summary, changes, behindCommits, observedAt; case uniqueCommits = "unique-commits" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(Summary.self, forKey: .summary).value
        changes = try container.decode([FileChange].self, forKey: .changes)
        uniqueCommits = try container.decodeIfPresent([GitCommit].self, forKey: .uniqueCommits)
        behindCommits = try container.decodeIfPresent([GitCommit].self, forKey: .behindCommits)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Summary(summary), forKey: .summary)
        try container.encode(changes, forKey: .changes)
        try container.encodeIfPresent(uniqueCommits, forKey: .uniqueCommits)
        try container.encodeIfPresent(behindCommits, forKey: .behindCommits)
        try container.encode(observedAt, forKey: .observedAt)
    }

    private struct Summary: Codable {
        let head: String
        let headOID: String
        let hasRemotes: Bool
        let base: String?
        let baseOID: String?

        init(_ value: GitSummary) {
            head = value.head; headOID = value.headOID; hasRemotes = value.hasRemotes
            base = value.base; baseOID = value.baseOID
        }

        var value: GitSummary { GitSummary(head: head, headOID: headOID, hasRemotes: hasRemotes, base: base, baseOID: baseOID) }
    }
}

public struct RepositoryHistorySnapshot: Codable, Sendable {
    public let ahead: [GitCommit]
    public let behind: [GitCommit]

    public init(ahead: [GitCommit], behind: [GitCommit]) { self.ahead = ahead; self.behind = behind }
}

public struct RepositoryHistoryCacheKey: Codable, Hashable, Sendable {
    public let repository: RepositoryCacheRepositoryIdentity
    public let head: String
    public let base: String
    private let queryVersion: Int

    public init(repository: RepositoryCacheRepositoryIdentity, head: String, base: String) {
        self.repository = repository; self.head = head; self.base = base; queryVersion = 1
    }
}

public struct RepositoryHistoryCacheState: Equatable, Sendable {
    public let reusable: Bool
    public let fingerprint: String

    public init(reusable: Bool, fingerprint: String) { self.reusable = reusable; self.fingerprint = fingerprint }
}

public protocol RepositoryDetailCaching: Sendable {
    func loadDetail(for identity: RepositoryCacheIdentity) async -> RepositoryDetailSnapshot?
    func saveDetail(_ value: RepositoryDetailSnapshot, for identity: RepositoryCacheIdentity) async
    func loadHistory(for key: RepositoryHistoryCacheKey) async -> RepositoryHistorySnapshot?
    func saveHistory(_ value: RepositoryHistorySnapshot, for key: RepositoryHistoryCacheKey) async
    func invalidateDetail(for identity: RepositoryCacheIdentity) async
    func invalidateHistory(for repository: RepositoryCacheRepositoryIdentity) async
    func flush() async
}

extension RepositoryDetailCaching {
    public func flush() async {}
}

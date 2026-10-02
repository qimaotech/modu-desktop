import Foundation

public struct ModuError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    public static func wrap(_ error: Error, code: String = "operation-failed") -> ModuError {
        error as? ModuError ?? ModuError(code, Git.sanitize(error.localizedDescription))
    }
}

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

public struct Resource: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var kind: String
    public var repo: String?
    public var group: String?
    public var path: String
    public var id: String { path }
    public init(kind: String, repo: String? = nil, group: String? = nil, path: String) {
        self.kind = kind; self.repo = repo; self.group = group; self.path = path
    }
    public static func repository(_ name: String) -> Resource { .init(kind: "repository", repo: name, path: "repositories/\(name)") }
    public static func group(_ name: String) -> Resource { .init(kind: "group", group: name, path: "worktrees/\(name)") }
    public static func member(_ group: String, _ repo: String) -> Resource { .init(kind: "member", repo: repo, group: group, path: "worktrees/\(group)/\(repo)") }
}

public struct Effect: Codable, Equatable, Sendable {
    public var action: String
    public var target: String
    public var state: String
    public init(_ action: String, _ target: String, state: String = "applied") {
        self.action = action; self.target = target; self.state = state
    }
}

public struct ItemResult: Codable, Sendable {
    public var resource: Resource
    public var status: String = "success"
    public var reasonCode: String?
    public var message: String?
    public var effects: [Effect] = []
    public var data: [String: String]?
    public var trashPath: String?
    public var causeCode: String?
    enum CodingKeys: String, CodingKey {
        case resource, status, message, effects, data
        case reasonCode = "reason-code", trashPath = "trash-path", causeCode = "cause-code"
    }
    public init(_ resource: Resource, status: String = "success", error: ModuError? = nil) {
        self.resource = resource; self.status = status; reasonCode = error?.code; message = error?.message
    }
    static func notProcessed(_ resource: Resource) -> ItemResult {
        ItemResult(resource, status: "skipped", error: ModuError("not-processed", "Not processed because the operation stopped."))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resource, forKey: .resource); try c.encode(status, forKey: .status)
        try c.encode(reasonCode, forKey: .reasonCode); try c.encode(message, forKey: .message)
        try c.encode(effects, forKey: .effects); try c.encodeIfPresent(data, forKey: .data)
        try c.encodeIfPresent(trashPath, forKey: .trashPath); try c.encodeIfPresent(causeCode, forKey: .causeCode)
    }
}

public struct OperationResult: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var command: String
    public var workspace: String?
    public var status: String
    public var reasonCode: String?
    public var message: String?
    public var items: [ItemResult]
    public var plan: [DeletionTarget]?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema-version", command, workspace, status
        case reasonCode = "reason-code", message, items, plan
    }
    public init(command: String, workspace: String?, status: String = "success", items: [ItemResult] = [], error: ModuError? = nil) {
        self.command = command; self.workspace = workspace; self.status = error?.code == "cancelled" ? "cancelled" : status; self.items = items
        reasonCode = error?.code; message = error?.message
    }
    public mutating func summarize(cancelled: Bool = false) {
        let success = items.contains { $0.status == "success" }
        let failed = items.contains { $0.status == "failed" }
        let skipped = items.contains { $0.status == "skipped" }
        if cancelled && !failed { status = "cancelled"; reasonCode = "cancelled" }
        else if failed { status = success ? "partial-success" : "failed" }
        else if skipped { status = success ? "partial-success" : "skipped" }
        else { status = "success" }
    }
    public var exitCode: Int32 {
        if status == "success" { return 0 }
        if status == "cancelled" { return 130 }
        if ["invalid-input", "invalid-configuration", "workspace-not-found", "configuration-missing"].contains(reasonCode ?? "") { return 2 }
        return 1
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(command, forKey: .command)
        try c.encode(workspace, forKey: .workspace); try c.encode(status, forKey: .status)
        try c.encode(reasonCode, forKey: .reasonCode); try c.encode(message, forKey: .message)
        try c.encode(items, forKey: .items); try c.encodeIfPresent(plan, forKey: .plan)
    }
}

public struct DeletionTarget: Codable, Equatable, Sendable, Identifiable {
    public var resource: Resource
    public var path: String
    public var branch: String?
    public var detached: Bool
    public var registered: Bool
    public var exists: Bool
    public var risks: [String]
    public var id: String { resource.id }
}

public struct OperationProgress: Sendable {
    public let target: String
    public let phase: String
    public let completed: Int
    public let total: Int
    public let cancellable: Bool
    public let snapshot: WorkspaceRecord?
    public let counts: (added: Int, skipped: Int, failed: Int)?
    public init(_ target: String, _ phase: String, completed: Int = 0, total: Int = 0, cancellable: Bool = true, snapshot: WorkspaceRecord? = nil, counts: (added: Int, skipped: Int, failed: Int)? = nil) {
        self.target = target; self.phase = phase; self.completed = completed; self.total = total; self.cancellable = cancellable; self.snapshot = snapshot; self.counts = counts
    }
}
public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

public struct FileChange: Identifiable, Sendable, Equatable {
    public var path: String
    public var originalPath: String?
    public var index: String
    public var workingTree: String
    public var id: String { path }
    public var conflict: Bool { index == "U" || workingTree == "U" || ["AA", "DD"].contains(index + workingTree) }
    public static func label(_ status: String) -> String {
        switch status { case "A", "C": "Added"; case "R": "Moved"; case "M", "T": "Modified"; case "D": "Deleted"; case "?": "Untracked"; case "U": "Conflict"; case " ", ".": "—"; default: "Unknown (\(status))" }
    }
}
public struct GitCommit: Identifiable, Sendable {
    public var id: String
    public var subject: String
    public var author: String
    public var date: String
}
public struct GitSummary: Sendable {
    public var head: String
    public var headOID: String
    public var hasRemotes = true
    public var base: String?
    public var baseOID: String?
    public var baseError: String?
}
public struct ResourceState: Sendable {
    public var resource: Resource
    public var available: Bool
    public var dirty: Bool?
    public var reason: String?
    public init(resource: Resource, available: Bool, dirty: Bool? = nil, reason: String? = nil) { self.resource = resource; self.available = available; self.dirty = dirty; self.reason = reason }
}

import Foundation

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
    public var status: OperationStatus = .success
    public var reasonCode: String?
    public var message: String?
    public var userMessage: UserMessage? = nil
    public var effects: [Effect] = []
    public var data: [String: String]?
    public var trashPath: String?
    public var causeCode: String?
    enum CodingKeys: String, CodingKey {
        case resource, status, message, effects, data
        case reasonCode = "reason-code", trashPath = "trash-path", causeCode = "cause-code"
    }
    public init(_ resource: Resource, status: OperationStatus = .success, error: ModuError? = nil) {
        self.resource = resource; self.status = status; reasonCode = error?.code; message = error?.message
        userMessage = error?.userMessage
    }
    static func notProcessed(_ resource: Resource) -> ItemResult {
        ItemResult(resource, status: .skipped, error: ModuError("not-processed", .notProcessedBecauseOperationStopped))
    }
    public var hasWarning: Bool { data?["warning-code"] != nil }
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
    public var status: OperationStatus
    public var reasonCode: String?
    public var message: String?
    public var userMessage: UserMessage? = nil
    public var items: [ItemResult]
    public var plan: [DeletionTarget]?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema-version", command, workspace, status
        case reasonCode = "reason-code", message, items, plan
    }
    public init(command: String, workspace: String?, status: OperationStatus = .success, items: [ItemResult] = [], error: ModuError? = nil) {
        self.command = command; self.workspace = workspace; self.status = error?.code == "cancelled" ? .cancelled : status; self.items = items
        reasonCode = error?.code; message = error?.message
        userMessage = error?.userMessage
    }
    public mutating func summarize(cancelled: Bool = false) {
        let success = items.contains { $0.status == .success }
        let failed = items.contains { $0.status == .failed }
        let skipped = items.contains { $0.status == .skipped }
        if cancelled && !failed { status = .cancelled; reasonCode = "cancelled" }
        else if failed { status = success ? .partialSuccess : .failed }
        else if skipped { status = success ? .partialSuccess : .skipped }
        else { status = .success }
    }
    public var exitCode: Int32 {
        if status == .success { return 0 }
        if status == .cancelled { return 130 }
        if ["invalid-input", "invalid-configuration", "workspace-not-found", "configuration-missing"].contains(reasonCode ?? "") { return 2 }
        return 1
    }
    public var hasWarnings: Bool { items.contains { $0.hasWarning } }
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
    public var riskMessages: [UserMessage] = []
    public var dirty: Bool? = nil
    public var id: String { resource.id }
    enum CodingKeys: String, CodingKey { case resource, path, branch, detached, registered, exists, risks, dirty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resource == rhs.resource && lhs.path == rhs.path && lhs.branch == rhs.branch && lhs.detached == rhs.detached
            && lhs.registered == rhs.registered && lhs.exists == rhs.exists && lhs.risks == rhs.risks && lhs.dirty == rhs.dirty
    }
}

public struct OperationProgress: Sendable {
    public let target: String
    public let phase: OperationPhase
    public let completed: Int
    public let total: Int
    // Whether this phase can be interrupted; cancellation requests are accepted even when false.
    public let cancellable: Bool
    public let snapshot: WorkspaceRecord?
    public let counts: (added: Int, skipped: Int, failed: Int)?
    public init(_ target: String, _ phase: OperationPhase, completed: Int = 0, total: Int = 0, cancellable: Bool = true, snapshot: WorkspaceRecord? = nil, counts: (added: Int, skipped: Int, failed: Int)? = nil) {
        self.target = target; self.phase = phase; self.completed = completed; self.total = total; self.cancellable = cancellable; self.snapshot = snapshot; self.counts = counts
    }
}
public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

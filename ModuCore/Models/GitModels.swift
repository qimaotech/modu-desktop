import Foundation

public struct FileChange: Identifiable, Sendable, Equatable {
    public var path: String
    public var originalPath: String?
    public var index: String
    public var workingTree: String
    public init(path: String, originalPath: String? = nil, index: String, workingTree: String) {
        self.path = path; self.originalPath = originalPath; self.index = index; self.workingTree = workingTree
    }
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
    public init(id: String, subject: String, author: String, date: String) {
        self.id = id; self.subject = subject; self.author = author; self.date = date
    }
}
public struct GitSummary: Sendable {
    public var head: String
    public var headOID: String
    public var hasRemotes = true
    public var base: String?
    public var baseOID: String?
    public var baseError: String?
    public var baseMessage: UserMessage? = nil
    public init(head: String, headOID: String, hasRemotes: Bool = true, base: String? = nil, baseOID: String? = nil, baseError: String? = nil) {
        self.head = head; self.headOID = headOID; self.hasRemotes = hasRemotes
        self.base = base; self.baseOID = baseOID; self.baseError = baseError
    }
}
public struct ResourceState: Sendable {
    public var resource: Resource
    public var available: Bool
    public var dirty: Bool?
    public var reason: String?
    public var reasonMessage: UserMessage?
    public init(resource: Resource, available: Bool, dirty: Bool? = nil, reason: String? = nil, reasonMessage: UserMessage? = nil) { self.resource = resource; self.available = available; self.dirty = dirty; self.reason = reason; self.reasonMessage = reasonMessage }
}

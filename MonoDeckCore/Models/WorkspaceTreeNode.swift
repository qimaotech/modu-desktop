import Foundation

public struct WorkspaceTreeNode: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case workspace
        case auxiliaryDirectory = "auxiliary-directory"
        case group
        case mainWorktree = "main-worktree"
        case linkedWorktree = "linked-worktree"
    }

    public let type: Kind
    public let path: String
    public let children: [WorkspaceTreeNode]?

    public init(_ type: Kind, path: String, children: [WorkspaceTreeNode]? = nil) {
        self.type = type; self.path = path; self.children = children
    }

    private enum CodingKeys: String, CodingKey { case type, path, children }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(path, forKey: .path)
        try container.encode(children, forKey: .children)
    }
}

import Foundation

public enum InspectionScope: Sendable {
    case all, repositories, worktrees

    func includes(_ resource: Resource) -> Bool {
        switch self {
        case .all: true
        case .repositories: resource.kind == .repository
        case .worktrees: resource.kind == .group || resource.kind == .member
        }
    }
}

public struct ResourceSnapshot: Sendable {
    public let resource: Resource
    public var changes: [FileChange]?
    public var changesError: ModuError?
    public var summary: GitSummary?
    public var summaryError: ModuError?
}

import Foundation

public enum Resource: Equatable, Hashable, Identifiable, Sendable {
    case workspace(path: String = ".")
    case cli(path: String)
    case repository(String)
    case group(String)
    case member(String, String)

    public enum Kind: String, Codable, Sendable { case workspace, cli, repository, group, member }

    public var kind: Kind {
        switch self {
        case .workspace: .workspace
        case .cli: .cli
        case .repository: .repository
        case .group: .group
        case .member: .member
        }
    }
    public var repo: String? {
        switch self {
        case .repository(let name), .member(_, let name): name
        default: nil
        }
    }
    public var group: String? {
        switch self {
        case .group(let name), .member(let name, _): name
        default: nil
        }
    }
    public var path: String {
        switch self {
        case .workspace(let path), .cli(let path): path
        case .repository(let name): "repositories/\(name)"
        case .group(let name): "worktrees/\(name)"
        case .member(let group, let repo): "worktrees/\(group)/\(repo)"
        }
    }
    public var id: String { path }
}

extension Resource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, repo, group, path }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let path = try container.decode(String.self, forKey: .path)
        let repo = try container.decodeIfPresent(String.self, forKey: .repo)
        let group = try container.decodeIfPresent(String.self, forKey: .group)
        switch kind {
        case .workspace: self = .workspace(path: path)
        case .cli: self = .cli(path: path)
        case .repository: self = .repository(try container.decode(String.self, forKey: .repo))
        case .group: self = .group(try container.decode(String.self, forKey: .group))
        case .member: self = .member(try container.decode(String.self, forKey: .group), try container.decode(String.self, forKey: .repo))
        }
        guard self.path == path, self.repo == repo, self.group == group else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "Resource fields do not match its kind and derived path.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(repo, forKey: .repo)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(path, forKey: .path)
    }
}

import Foundation
import Darwin

public struct ResourceReadContext: Sendable {
    public let resource: Resource
    public let workspace: WorkspaceRecord
    public let path: URL
    public let gitDirectory: URL
    public let commonDirectory: URL
    let mainDirectory: URL
    private let indexedSubmoduleDirectories: [URL]
    private let submoduleIndexIdentity: SubmoduleIndexIdentity?
    private let submoduleConfigurationIdentity: ReadPathIdentity?
    private let identities: [ReadPathIdentity]

    public var submoduleDirectories: [URL] {
        // A stale index disables event filtering without invalidating normal status reads.
        guard submoduleIndexIdentity != nil, indexIsCurrent else { return [] }
        return indexedSubmoduleDirectories
    }

    init(resource: Resource, workspace: WorkspaceRecord, path: URL, gitDirectory: URL, commonDirectory: URL, main: URL, submodulePaths: [String] = [], submoduleIndexIdentity: SubmoduleIndexIdentity? = nil) throws {
        self.resource = resource; self.workspace = workspace; self.path = path
        self.gitDirectory = gitDirectory; self.commonDirectory = commonDirectory; mainDirectory = main
        self.submoduleIndexIdentity = submoduleIndexIdentity
        submoduleConfigurationIdentity = submoduleIndexIdentity.flatMap { _ in try? ReadPathIdentity(path.appending(path: ".gitmodules")) }
        // A gitlink replaced by an ordinary file must remain observable as a type change.
        indexedSubmoduleDirectories = submodulePaths.compactMap { try? PathSafety.child($0, of: path) }
        var seen = Set<URL>()
        identities = try [path, main, path.appending(path: ".git"), main.appending(path: ".git"), gitDirectory, commonDirectory,
                          gitDirectory.appending(path: "commondir"), commonDirectory.appending(path: "config"), gitDirectory.appending(path: "config.worktree")]
            .filter { seen.insert($0).inserted }.map(ReadPathIdentity.init)
    }

    public func isValid(in record: WorkspaceRecord) -> Bool {
        guard matchesRegistration(in: record),
              let current = try? PathSafety.child(resource.path, of: record.rootURL, allowMissing: false), current == path else { return false }
        return identities.allSatisfy { (try? ReadPathIdentity($0.url)) == $0 }
    }

    var indexIsCurrent: Bool {
        guard let submoduleIndexIdentity else { return true }
        guard let submoduleConfigurationIdentity else { return false }
        return (try? SubmoduleIndexIdentity(gitDirectory.appending(path: "index"))) == submoduleIndexIdentity
            && (try? ReadPathIdentity(submoduleConfigurationIdentity.url)) == submoduleConfigurationIdentity
    }

    func rebinding(to record: WorkspaceRecord) -> ResourceReadContext? {
        guard isValid(in: record) else { return nil }
        return ResourceReadContext(rebinding: self, workspace: record)
    }

    private init(rebinding context: ResourceReadContext, workspace: WorkspaceRecord) {
        resource = context.resource; self.workspace = workspace; path = context.path
        gitDirectory = context.gitDirectory; commonDirectory = context.commonDirectory; mainDirectory = context.mainDirectory
        indexedSubmoduleDirectories = context.indexedSubmoduleDirectories
        submoduleIndexIdentity = context.submoduleIndexIdentity
        submoduleConfigurationIdentity = context.submoduleConfigurationIdentity; identities = context.identities
    }

    private func matchesRegistration(in record: WorkspaceRecord) -> Bool {
        guard workspace.root == record.root else { return false }
        if let name = resource.repositoryID {
            guard let previous = workspace.repositories.first(where: { $0.id == name }),
                  record.repositories.first(where: { $0.id == name })?.url == previous.url else { return false }
        }
        if let name = resource.groupName {
            guard let previous = workspace.groups[name], let current = record.groups[name],
                  previous.createdAt == current.createdAt else { return false }
            if let repository = resource.repositoryID { return current.repositoryIDs.contains(repository) }
            return Set(previous.repositoryIDs) == Set(current.repositoryIDs)
        }
        return resource.repositoryID != nil
    }

}

enum SubmoduleIndexIdentity: Sendable, Equatable {
    case missing
    case file(inode: UInt64, device: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64)

    init(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { self = .missing; return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
        self = .file(inode: UInt64(metadata.st_ino), device: UInt64(bitPattern: Int64(metadata.st_dev)), size: Int64(metadata.st_size),
                     modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
    }
}

struct ReadPathIdentity: Sendable, Equatable {
    let url: URL
    let identity: String
    let inode: UInt64?
    let device: UInt64?
    let contents: Data?

    init(_ url: URL) throws {
        self.url = url
        identity = PathSafety.canonical(url).path
        guard PathSafety.exists(url) else { inode = nil; device = nil; contents = nil; return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        if type == .typeSymbolicLink {
            let resolved = try FileManager.default.attributesOfItem(atPath: identity)[.type] as? FileAttributeType
            guard resolved == .typeRegular || resolved == .typeDirectory else { throw MonoDeckError("unsafe-path", .expectedRealDirectory(url.path)) }
            contents = resolved == .typeRegular ? try Data(contentsOf: url) : Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
        } else {
            guard type == .typeDirectory || type == .typeRegular else { throw MonoDeckError("unsafe-path", .expectedRealDirectory(url.path)) }
            contents = type == .typeRegular ? try Data(contentsOf: url) : nil
        }
    }
}

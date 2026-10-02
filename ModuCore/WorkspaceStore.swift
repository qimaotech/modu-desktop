import Foundation
import CryptoKit
import Darwin
import Yams

public struct WorkspaceStore: Sendable {
    public let support: URL
    private let writer: @Sendable (Data, URL) throws -> Void
    public init(support: URL = WorkspaceStore.defaultSupport, writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) { self.support = support; self.writer = writer }
    public static var defaultSupport: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MODU_TEST_SUPPORT_DIRECTORY"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Modu")
    }
    public func recordURL(_ root: URL) -> URL { support.appending(path: "workspaces/\(key(root)).json") }
    public func lock(_ root: URL) throws -> WorkspaceLock {
        try FileManager.default.createDirectory(at: support.appending(path: "locks"), withIntermediateDirectories: true)
        return try WorkspaceLock(support.appending(path: "locks/\(key(root)).lock"))
    }
    public func load(_ root: URL) throws -> WorkspaceRecord {
        let url = recordURL(root)
        guard PathSafety.exists(url) else { throw ModuError("configuration-missing", "Workspace record is missing: \(url.path)") }
        do {
            let bytes = try Data(contentsOf: url)
            _ = try JSONSerialization.jsonObject(with: bytes)
            try ConfigValidation.validateDocument(String(decoding: bytes, as: UTF8.self), workspace: true)
            let record = try JSONDecoder().decode(WorkspaceRecord.self, from: bytes)
            try validate(record)
            guard PathSafety.identity(record.rootURL) == PathSafety.identity(root) else { throw ModuError("invalid-configuration", "Workspace root does not match its record.") }
            return record
        } catch { throw ModuError("invalid-configuration", "\(url.path): \(ModuError.wrap(error).message)") }
    }
    public func save(_ record: WorkspaceRecord) throws {
        try validate(record)
        let url = recordURL(record.rootURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try writer(encoder.encode(record), url) }
        catch { throw ModuError("configuration-write-failed", "Could not save \(url.path): \(error.localizedDescription)") }
    }
    public func locate(explicit: String?, cwd: URL) throws -> URL {
        if let explicit {
            let root = PathSafety.canonical(URL(fileURLWithPath: explicit, relativeTo: cwd))
            guard PathSafety.exists(root) else { throw ModuError("workspace-not-found", "Workspace not found: \(root.path)") }
            let lease = try lock(root); defer { lease.unlock() }
            _ = try load(root); return root
        }
        var candidate = PathSafety.canonical(cwd)
        while true {
            if PathSafety.exists(recordURL(candidate)) {
                let lease = try lock(candidate); defer { lease.unlock() }
                _ = try load(candidate); return candidate
            }
            if candidate.path == "/" { break }
            candidate.deleteLastPathComponent()
        }
        throw ModuError("workspace-not-found", "No registered workspace contains the current directory. Use --workspace <root>.")
    }
    public func checkNesting(_ root: URL) throws {
        let directory = support.appending(path: "workspaces")
        guard PathSafety.exists(directory) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(WorkspaceRecord.self, from: data), (try? validate(record)) != nil else { continue }
            let other = PathSafety.identity(record.rootURL), value = PathSafety.identity(root)
            if other != value && (other.hasPrefix(value + "/") || value.hasPrefix(other + "/")) { throw ModuError("workspace-nested", "Workspaces can’t be nested: \(record.root)") }
        }
    }
    public func validate(_ record: WorkspaceRecord) throws {
        guard record.version == 1, record.root.hasPrefix("/"), PathSafety.canonical(record.rootURL).path == record.root else { throw ModuError("invalid-configuration", "Invalid version or canonical root path.") }
        var repositories = Set<String>()
        for repo in record.repositories {
            let identity = try RepositoryIdentity(repo.url)
            guard repositories.insert(identity.name.lowercased()).inserted else { throw ModuError("repository-conflict", "Duplicate repository identity: \(identity.name)") }
        }
        var groups = Set<String>()
        for (name, group) in record.groups {
            try PathSafety.groupName(name)
            guard groups.insert(PathSafety.identity(record.groupURL(name))).inserted,
                  ISO8601DateFormatter().date(from: group.createdAt) != nil || Self.fractionalDate(group.createdAt) != nil,
                  group.repositories.count == Set(group.repositories).count,
                  group.repositories.allSatisfy({ name in record.repositories.contains { $0.id == name } }) else { throw ModuError("invalid-configuration", "Invalid group: \(name)") }
        }
    }
    private func key(_ root: URL) -> String { SHA256.hash(data: Data(PathSafety.identity(root).utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func fractionalDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: text)
    }
}

public final class WorkspaceLock: @unchecked Sendable {
    private var descriptor: Int32
    private let mutex = NSLock()
    init(_ path: URL) throws {
        descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ModuError("lock-failed", "Could not open workspace lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(descriptor); descriptor = -1
            throw ModuError(busy ? "workspace-busy" : "lock-failed", busy ? "This workspace is in use by another Modu operation." : "Could not acquire workspace lock.")
        }
    }
    public func unlock() { mutex.withLock { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } } }
    deinit { unlock() }
}

public enum ConfigValidation {
    public static func validateDocument(_ text: String, workspace: Bool) throws {
        guard let mapping = try Yams.compose(yaml: text)?.mapping else { throw ModuError("invalid-configuration", "Expected one configuration document.") }
        try keys(mapping, allowed: workspace ? ["version", "root", "repositories", "groups"] : ["version", "repositories", "groups"])
        for pair in mapping {
            if pair.key.string == "repositories" {
                guard let sequence = pair.value.sequence else { throw ModuError("invalid-configuration", "repositories must be a list.") }
                for repo in sequence {
                    guard let map = repo.mapping else { throw ModuError("invalid-configuration", "Repository must be a mapping.") }
                    try keys(map, allowed: ["url", "name"])
                }
            }
            if pair.key.string == "groups" {
                guard let groups = pair.value.mapping else { throw ModuError("invalid-configuration", "groups must be a mapping.") }
                try keys(groups, allowed: nil)
                for group in groups {
                    guard let map = group.value.mapping else { throw ModuError("invalid-configuration", "Group must be a mapping.") }
                    try keys(map, allowed: ["created-at", "repositories"])
                }
            }
        }
    }
    private static func keys(_ map: Node.Mapping, allowed: Set<String>?) throws {
        var seen = Set<String>()
        for pair in map {
            guard let key = pair.key.string, seen.insert(key).inserted, allowed?.contains(key) != false else { throw ModuError("invalid-configuration", "Unknown or duplicate configuration field.") }
        }
    }
}

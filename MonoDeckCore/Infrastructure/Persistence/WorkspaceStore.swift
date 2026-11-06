import Foundation
import CryptoKit
import Darwin

public struct WorkspaceStore: Sendable {
    public let support: URL
    public let directoryBoundary: URL?
    private let waitForLockRetry: @Sendable () async throws -> Void
    private let writer: @Sendable (Data, URL) throws -> Void
    public init(support: URL = WorkspaceStore.defaultSupport, directoryBoundary: URL? = nil, writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.init(support: support, directoryBoundary: directoryBoundary,
                  waitForLockRetry: { try await Task.sleep(for: .milliseconds(500)) }, writer: writer)
    }
    public init(support: URL = WorkspaceStore.defaultSupport, directoryBoundary: URL? = nil,
                waitForLockRetry: @escaping @Sendable () async throws -> Void,
                writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.support = support; self.directoryBoundary = directoryBoundary.map(PathSafety.canonical); self.writer = writer
        self.waitForLockRetry = waitForLockRetry
    }
    public static var defaultSupport: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MonoDeck")
    }
    public func recordURL(_ root: URL) -> URL { support.appending(path: "workspaces/\(key(root)).json") }
    public func checkBoundary(_ root: URL) throws {
        guard let directoryBoundary else { return }
        for path in [root, support, recordURL(root), support.appending(path: "locks")] {
            try PathSafety.confined(path, to: directoryBoundary)
        }
    }
    public func lock(_ root: URL) async throws -> WorkspaceLock {
        var retries = 0
        while true {
            guard !Task.isCancelled else { throw MonoDeckError("cancelled", .operationCancelled) }
            do { return try tryLock(root) }
            catch let error as MonoDeckError where error.code == "workspace-busy" {
                guard retries < 10 else { throw MonoDeckError("workspace-lock-timeout", .workspaceLockTimedOut) }
                retries += 1
                do { try await waitForLockRetry() }
                catch { throw MonoDeckError("cancelled", .operationCancelled) }
            }
        }
    }
    func tryLock(_ root: URL) throws -> WorkspaceLock {
        try checkBoundary(root)
        try FileManager.default.createDirectory(at: support.appending(path: "locks"), withIntermediateDirectories: true)
        return try WorkspaceLock(support.appending(path: "locks/\(key(root)).lock"))
    }
    public func load(_ root: URL) throws -> WorkspaceRecord {
        try checkBoundary(root)
        let url = recordURL(root)
        guard PathSafety.exists(url) else { throw MonoDeckError("workspace-record-missing", .workspaceRecordIsMissing(url.path)) }
        do {
            let bytes = try Data(contentsOf: url)
            _ = try JSONSerialization.jsonObject(with: bytes)
            try WorkspaceDocumentValidation.validateRecordDocument(String(decoding: bytes, as: UTF8.self))
            let record = try JSONDecoder().decode(WorkspaceRecord.self, from: bytes)
            try validate(record)
            guard PathSafety.identity(record.rootURL) == PathSafety.identity(root) else { throw MonoDeckError("invalid-workspace-record", .workspaceRootDoesNotMatchRecord) }
            return record
        } catch { throw MonoDeckError("invalid-workspace-record", .context(url.path, MonoDeckError.wrap(error).userMessage)) }
    }
    public func save(_ record: WorkspaceRecord) throws {
        try validate(record)
        let url = recordURL(record.rootURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try writer(encoder.encode(record), url) }
        catch { throw MonoDeckError("workspace-record-write-failed", .couldNotSave(url.path, MonoDeckError.wrap(error).userMessage)) }
    }
    public func locate(explicit: String?, cwd: URL) async throws -> URL {
        guard !Task.isCancelled else { throw MonoDeckError("cancelled", .operationCancelled) }
        if let explicit {
            let root = PathSafety.canonical(URL(fileURLWithPath: explicit, relativeTo: cwd))
            guard PathSafety.exists(root) else { throw MonoDeckError("workspace-not-found", .workspaceNotFound(root.path)) }
            _ = try load(root); return root
        }
        var candidate = PathSafety.canonical(cwd)
        while true {
            guard !Task.isCancelled else { throw MonoDeckError("cancelled", .operationCancelled) }
            if PathSafety.exists(recordURL(candidate)) {
                _ = try load(candidate); return candidate
            }
            if candidate.path == "/" { break }
            candidate.deleteLastPathComponent()
        }
        throw MonoDeckError("workspace-not-found", .noRegisteredWorkspaceContainsCurrentDirectoryUseWorkspace)
    }
    public func checkNesting(_ root: URL) throws {
        try checkBoundary(root)
        let directory = support.appending(path: "workspaces")
        guard PathSafety.exists(directory) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(WorkspaceRecord.self, from: data), (try? validate(record)) != nil else { continue }
            let other = PathSafety.identity(record.rootURL), value = PathSafety.identity(root)
            if other != value && (other.hasPrefix(value + "/") || value.hasPrefix(other + "/")) { throw MonoDeckError("workspace-nested", .workspacesCanTBeNested(record.root)) }
        }
    }
    public func validate(_ record: WorkspaceRecord) throws {
        try checkBoundary(record.rootURL)
        guard record.version == 2, record.root.hasPrefix("/"), PathSafety.canonical(record.rootURL).path == record.root else { throw MonoDeckError("invalid-workspace-record", .invalidVersionOrCanonicalRootPath) }
        var repositoryIDs = Set<String>()
        var lowercaseRepositoryIDs = Set<String>()
        for repo in record.repositories {
            let identity = try RepositoryIdentity(repo.url)
            guard lowercaseRepositoryIDs.insert(identity.id.lowercased()).inserted else { throw MonoDeckError("repository-conflict", .duplicateRepositoryID(identity.id)) }
            repositoryIDs.insert(identity.id)
        }
        let dateFormatter = ISO8601DateFormatter()
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var groups = Set<String>()
        for (name, group) in record.groups {
            try PathSafety.groupName(name)
            guard groups.insert(PathSafety.identity(record.groupURL(name))).inserted,
                  dateFormatter.date(from: group.createdAt) != nil || fractionalDateFormatter.date(from: group.createdAt) != nil,
                  group.repositoryIDs.count == Set(group.repositoryIDs).count,
                  group.repositoryIDs.allSatisfy(repositoryIDs.contains) else { throw MonoDeckError("invalid-workspace-record", .invalidGroup(name)) }
        }
    }
    private func key(_ root: URL) -> String { SHA256.hash(data: Data(PathSafety.identity(root).utf8)).map { String(format: "%02x", $0) }.joined() }
}

public final class WorkspaceLock: @unchecked Sendable {
    private var descriptor: Int32
    private let mutex = NSLock()
    init(_ path: URL) throws {
        descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MonoDeckError("lock-failed", .couldNotOpenWorkspaceLock) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(descriptor); descriptor = -1
            throw MonoDeckError(busy ? "workspace-busy" : "lock-failed", busy ? UserMessage.workspaceIsInUseByAnotherMonoDeckOperation : .couldNotAcquireWorkspaceLock)
        }
    }
    public func unlock() { mutex.withLock { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } } }
    deinit { unlock() }
}

import Foundation
import CryptoKit
import Darwin

public actor RepositoryDiskCache: RepositoryDetailCaching {
    public let directory: URL
    private let maximumBytes: Int
    private let maximumEntryBytes: Int
    private let maximumMemoryBytes: Int
    private let maximumDetailCount: Int
    private let maximumIdleAge: TimeInterval
    private let now: @Sendable () -> Date
    private let diagnostics: RepositoryReadDiagnostics?
    private let waitForWrite: @Sendable () async throws -> Void
    private var details: [String: Detail] = [:]
    private var detailUse = 0
    private var pendingDetails = Set<String>()
    private var invalidatedDetails = Set<String>()
    private var invalidatedHistories = Set<RepositoryCacheRepositoryIdentity>()
    private var accesses: [String: Date] = [:]
    private var persistedAccesses: [String: Date] = [:]
    private var pendingAccesses = Set<String>()
    private var maintenanceRequested = false
    private var lastMaintenance: Date?
    private var writer: Task<Void, Never>?
    private var writerID = UUID()
    private var ledger: [String: File]?
    private var ledgerGeneration: String?
    private var ledgerDirectoryStamp: String?

    public init(directory: URL, maximumBytes: Int = 64 * 1_024 * 1_024, maximumEntryBytes: Int = 8 * 1_024 * 1_024,
                maximumMemoryBytes: Int = 32 * 1_024 * 1_024, maximumDetailCount: Int = 64,
                maximumIdleAge: TimeInterval = 30 * 24 * 60 * 60, now: @escaping @Sendable () -> Date = { Date() },
                diagnostics: RepositoryReadDiagnostics? = nil, waitForWrite: (@Sendable () async throws -> Void)? = nil) {
        var ancestor = directory.standardizedFileURL
        var missing: [String] = []
        while !PathSafety.exists(ancestor), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        // Foundation preserves some macOS volume aliases even for existing directories.
        let resolved = realpath(ancestor.path, nil)
        let parent = resolved.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) } ?? PathSafety.canonical(ancestor)
        if let resolved { free(resolved) }
        self.directory = missing.reversed().reduce(parent) { $0.appending(path: $1, directoryHint: .isDirectory) }
        self.maximumBytes = max(0, maximumBytes); self.maximumEntryBytes = max(0, maximumEntryBytes)
        self.maximumMemoryBytes = max(0, maximumMemoryBytes); self.maximumDetailCount = max(0, maximumDetailCount)
        self.maximumIdleAge = max(0, maximumIdleAge); self.now = now; self.diagnostics = diagnostics
        self.waitForWrite = waitForWrite ?? { try await Task.sleep(for: .seconds(1)) }
    }

    public func loadDetail(for identity: RepositoryCacheIdentity) async -> RepositoryDetailSnapshot? {
        guard !Task.isCancelled, identity.isCurrent(), let key = digest(identity), !invalidatedDetails.contains(key) else { return nil }
        if let remembered = details[key], pendingDetails.contains(key), pendingStorageIsUsable() {
            let refreshed = refreshPersistedDetail(remembered, key: key)
            remember(refreshed, key: key)
            diagnostics?.record("cache.detail.hit")
            return refreshed.latest
        }
        guard let loaded = loadDiskDetail(for: identity, key: key), !Task.isCancelled, identity.isCurrent() else {
            if !Task.isCancelled { forgetDetail(key) }
            return nil
        }
        let latest = details[key].flatMap { remembered in
            remembered.latest.hasSameContent(as: loaded.value) && remembered.latest.observedAt > loaded.value.observedAt ? remembered.latest : nil
        } ?? loaded.value
        let detail = makeDetail(identity: identity, latest: latest, persisted: loaded.value, stamp: loaded.stamp)
        remember(detail, key: key)
        return latest
    }

    public func saveDetail(_ value: RepositoryDetailSnapshot, for identity: RepositoryCacheIdentity) async {
        guard !Task.isCancelled, maximumBytes > 0, maximumEntryBytes > 0,
              identity.isCurrent(), value.isComplete, let key = digest(identity) else { return }
        var remembered: Detail
        if let current = details[key] {
            remembered = refreshPersistedDetail(current, key: key)
        } else if !invalidatedDetails.contains(key), let stored = loadDiskDetail(for: identity, key: key, recordingAccess: false) {
            remembered = makeDetail(identity: identity, latest: stored.value, persisted: stored.value, stamp: stored.stamp)
        } else {
            remembered = makeDetail(identity: identity, latest: value)
        }
        guard !Task.isCancelled, identity.isCurrent() else { return }
        let sameContent = value.hasSameContent(as: remembered.latest)
        if value.observedAt > remembered.latest.observedAt || sameContent {
            if !sameContent { remembered.latestCost = memoryCost(value) }
            if value.observedAt >= remembered.latest.observedAt { remembered.latest = value }
        }
        guard remember(remembered, key: key) else { return }
        invalidatedDetails.remove(key)
        let contentChanged = remembered.persisted.map { !remembered.latest.hasSameContent(as: $0) } ?? true
        let checkpointDue = now().timeIntervalSince(remembered.checkpointedAt) >= 60
        if contentChanged || checkpointDue {
            let beginsBatch = pendingDetails.isEmpty
            pendingDetails.insert(key)
            scheduleWriter(reset: beginsBatch)
        } else {
            pendingDetails.remove(key)
            diagnostics?.record("cache.detail.unchanged")
        }
    }

    var detailMemoryStatistics: (count: Int, estimatedBytes: Int) {
        (details.count, details.values.reduce(0) { Self.addingCost($0, $1.memoryCost) })
    }

    public func loadHistory(for key: RepositoryHistoryCacheKey) async -> RepositoryHistorySnapshot? {
        guard !Task.isCancelled, key.repository.isCurrent(), !invalidatedHistories.contains(key.repository), let digest = digest(key) else { return nil }
        let result: RepositoryHistorySnapshot? = load(key: digest, kind: "history", repository: key.repository)
        guard !Task.isCancelled, key.repository.isCurrent() else { return nil }
        return result
    }

    public func saveHistory(_ value: RepositoryHistorySnapshot, for key: RepositoryHistoryCacheKey) async {
        guard !Task.isCancelled, maximumBytes > 0, maximumEntryBytes > 0,
              key.repository.isCurrent(), let digest = digest(key) else { return }
        withMutation(create: true) {
            if self.write(value, key: digest, kind: "history", repository: key.repository) { self.invalidatedHistories.remove(key.repository) }
            self.maintainIfNeeded()
        }
    }

    public func invalidateDetail(for identity: RepositoryCacheIdentity) async {
        guard !Task.isCancelled, let key = digest(identity) else { return }
        forgetDetail(key); invalidatedDetails.insert(key)
        if pendingDetails.isEmpty, pendingAccesses.isEmpty, !maintenanceRequested { cancelWriter() }
        withMutation(create: false) { self.remove(self.entryURL(key: key, kind: "detail")) }
    }

    public func invalidateHistory(for repository: RepositoryCacheRepositoryIdentity) async {
        guard !Task.isCancelled else { return }
        invalidatedHistories.insert(repository)
        withMutation(create: false) {
            for file in self.ledger?.values.filter({ $0.url.lastPathComponent.hasPrefix("history-") }) ?? [] {
                guard !Task.isCancelled else { return }
                guard let data = try? self.read(file.url), let entry = try? JSONDecoder().decode(Header.self, from: data), entry.repository == repository else { continue }
                self.remove(file.url)
            }
        }
    }

    public func flush() async {
        cancelWriter()
        for (key, detail) in details where detail.persisted.map({ !detail.latest.hasSameContent(as: $0) || detail.latest.observedAt != $0.observedAt }) ?? true {
            pendingDetails.insert(key)
        }
        pendingAccesses.formUnion(accesses.keys.filter { accesses[$0] != persistedAccesses[$0] })
        persistPending()
    }

    private func scheduleWriter(reset: Bool = false) {
        if reset { cancelWriter() }
        guard writer == nil else { return }
        let id = UUID(); writerID = id
        let wait = waitForWrite
        writer = Task { [weak self] in
            do { try await wait() } catch { return }
            guard !Task.isCancelled else { return }
            await self?.writeScheduled(id)
        }
    }

    private func cancelWriter() {
        writerID = UUID(); writer?.cancel(); writer = nil
    }

    private func writeScheduled(_ id: UUID) {
        guard writerID == id else { return }
        writer = nil
        persistPending()
    }

    private func persistPending() {
        for key in pendingDetails {
            if details[key]?.identity.isCurrent() != true || invalidatedDetails.contains(key) { forgetDetail(key) }
        }
        guard !pendingDetails.isEmpty || !pendingAccesses.isEmpty || maintenanceRequested else { return }
        let requested = pendingDetails
        pendingDetails = []
        let mutated = withMutation(create: !requested.isEmpty) {
            for key in requested {
                guard let current = self.details[key] else { continue }
                var detail = self.refreshPersistedDetail(current, key: key)
                guard detail.identity.isCurrent(), !self.invalidatedDetails.contains(key) else {
                    self.forgetDetail(key); continue
                }
                if let persisted = detail.persisted, persisted.observedAt >= detail.latest.observedAt {
                    self.remember(detail, key: key)
                    continue
                }
                if self.write(detail.latest, key: key, kind: "detail", repository: detail.identity.repository) {
                    let file = self.entryURL(key: key, kind: "detail")
                    guard self.ledger?[file.lastPathComponent] != nil, let stamp = self.fileStamp(file) else {
                        self.forgetDetail(key); continue
                    }
                    detail.persisted = detail.latest; detail.checkpointedAt = self.now()
                    detail.persistedCost = detail.latestCost; detail.persistedStamp = stamp
                    self.remember(detail, key: key)
                } else { self.forgetDetail(key) }
            }
            self.persistAccesses()
            self.maintainIfNeeded()
        }
        if !mutated { for key in requested { forgetDetail(key) } }
    }

    private func loadDiskDetail(for identity: RepositoryCacheIdentity, key: String, recordingAccess: Bool = true) -> (value: RepositoryDetailSnapshot, stamp: FileStamp)? {
        let file = entryURL(key: key, kind: "detail")
        guard let before = fileStamp(file) else { return nil }
        let value: RepositoryDetailSnapshot? = load(key: key, kind: "detail", repository: identity.repository, recordingAccess: recordingAccess)
        guard let value, value.isComplete, before == fileStamp(file) else { return nil }
        return (value, before)
    }

    private func refreshPersistedDetail(_ current: Detail, key: String) -> Detail {
        guard current.persistedStamp != fileStamp(entryURL(key: key, kind: "detail")) else { return current }
        var detail = current
        let loaded = loadDiskDetail(for: current.identity, key: key, recordingAccess: false)
        detail.persisted = loaded?.value; detail.persistedStamp = loaded?.stamp
        detail.persistedCost = loaded.map { memoryCost($0.value) } ?? 0
        detail.checkpointedAt = now()
        if let loaded, loaded.value.observedAt >= detail.latest.observedAt {
            detail.latest = loaded.value; detail.latestCost = detail.persistedCost
            pendingDetails.remove(key)
        }
        return detail
    }

    private func makeDetail(identity: RepositoryCacheIdentity, latest: RepositoryDetailSnapshot,
                            persisted: RepositoryDetailSnapshot? = nil, stamp: FileStamp? = nil) -> Detail {
        Detail(identity: identity, latest: latest, persisted: persisted, latestCost: memoryCost(latest),
               persistedCost: persisted.map(memoryCost) ?? 0, persistedStamp: stamp, checkpointedAt: now(), lastUse: 0)
    }

    @discardableResult private func remember(_ value: Detail, key: String) -> Bool {
        guard maximumDetailCount > 0, value.memoryCost != Int.max, value.memoryCost <= maximumMemoryBytes else { forgetDetail(key); return false }
        var others = details.filter { $0.key != key }
        while others.count >= maximumDetailCount || exceedsMemoryBudget(Self.addingCost(others.values.reduce(0) { Self.addingCost($0, $1.memoryCost) }, value.memoryCost)) {
            guard let oldest = others.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            others.removeValue(forKey: oldest.key)
            forgetDetail(oldest.key)
        }
        var detail = value
        detailUse += 1; detail.lastUse = detailUse
        details[key] = detail
        return true
    }

    private func exceedsMemoryBudget(_ cost: Int) -> Bool { cost == Int.max || cost > maximumMemoryBytes }

    private func forgetDetail(_ key: String) {
        details.removeValue(forKey: key); pendingDetails.remove(key)
    }

    private func memoryCost(_ value: RepositoryDetailSnapshot) -> Int {
        var cost = MemoryLayout<RepositoryDetailSnapshot>.stride
        cost = Self.addingCost(cost, stringCost(value.summary.head))
        cost = Self.addingCost(cost, stringCost(value.summary.headOID))
        cost = Self.addingCost(cost, stringCost(value.summary.base))
        cost = Self.addingCost(cost, stringCost(value.summary.baseOID))
        cost = Self.addingCost(cost, Self.multiplyingCost(value.changes.count, MemoryLayout<FileChange>.stride))
        for change in value.changes {
            for string in [change.path, change.originalPath, change.index, change.workingTree] { cost = Self.addingCost(cost, stringCost(string)) }
        }
        for commits in [value.commits, value.behindCommits] {
            guard let commits else { continue }
            cost = Self.addingCost(cost, Self.multiplyingCost(commits.count, MemoryLayout<GitCommit>.stride))
            for commit in commits {
                for string in [commit.id, commit.subject, commit.author, commit.date] { cost = Self.addingCost(cost, stringCost(string)) }
            }
        }
        // Charge both snapshots independently even when their arrays share copy-on-write storage.
        return cost
    }

    private func stringCost(_ value: String?) -> Int { value.map { Self.addingCost(32, Self.multiplyingCost($0.utf8.count, 2)) } ?? 0 }

    private static func addingCost(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func multiplyingCost(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private func load<Value: Codable & Sendable>(key: String, kind: String, repository: RepositoryCacheRepositoryIdentity, recordingAccess: Bool = true) -> Value? {
        guard !Task.isCancelled, (try? checkDirectory(create: false)) != nil else { return nil }
        let file = entryURL(key: key, kind: kind)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let persisted = attributes[.modificationDate] as? Date else { return nil }
            let lastAccess = max(persisted, accesses[file.lastPathComponent] ?? persisted)
            guard now().timeIntervalSince(lastAccess) < maximumIdleAge else {
                if recordingAccess { requestMaintenance() }
                return nil
            }
            let data = try read(file)
            let entry = try JSONDecoder().decode(Entry<Value>.self, from: data)
            guard entry.version == 1, entry.key == key, entry.repository == repository, !Task.isCancelled else {
                if kind == "detail", !Task.isCancelled { forgetDetail(key) }
                return nil
            }
            if recordingAccess {
                accesses[file.lastPathComponent] = now()
                if persistedAccesses[file.lastPathComponent] == nil { persistedAccesses[file.lastPathComponent] = persisted }
                if now().timeIntervalSince(persistedAccesses[file.lastPathComponent] ?? persisted) >= 60 {
                    pendingAccesses.insert(file.lastPathComponent); scheduleWriter()
                }
                requestMaintenance()
            }
            diagnostics?.record("cache.\(kind).hit", bytes: data.count)
            return entry.value
        } catch {
            if kind == "detail", !Task.isCancelled { forgetDetail(key) }
            diagnostics?.record("cache.\(kind).miss")
            return nil
        }
    }

    private func requestMaintenance() {
        if lastMaintenance.map({ now().timeIntervalSince($0) >= 300 }) ?? true {
            maintenanceRequested = true; scheduleWriter()
        }
    }

    @discardableResult private func withMutation(create: Bool, _ body: () -> Void) -> Bool {
        guard !Task.isCancelled, (try? checkDirectory(create: create)) != nil else { return false }
        let lock = directory.appending(path: ".write.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        do {
            let generation = try readGeneration()
            let stamp = directoryStamp()
            if ledger == nil || ledgerGeneration != generation || ledgerDirectoryStamp != stamp {
                ledger = Dictionary(uniqueKeysWithValues: files().map { ($0.url.lastPathComponent, $0) })
            }
            let replacement = UUID().uuidString
            let generationURL = directory.appending(path: ".generation")
            if PathSafety.exists(generationURL), !isRegularFile(generationURL) { return false }
            try Data(replacement.utf8).write(to: generationURL, options: .atomic)
            ledgerGeneration = replacement
            body()
            ledgerDirectoryStamp = directoryStamp()
            return true
        } catch { ledger = nil; return false }
    }

    private func write<Value: Codable & Sendable>(_ value: Value, key: String, kind: String, repository: RepositoryCacheRepositoryIdentity) -> Bool {
        guard !Task.isCancelled, maximumBytes > 0, maximumEntryBytes > 0 else { return false }
        do {
            let start = ContinuousClock.now
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(Entry(version: 1, repository: repository, key: key, value: value))
            diagnostics?.record("cache.encode", duration: start.duration(to: .now), bytes: bytes.count)
            guard !Task.isCancelled, bytes.count <= maximumEntryBytes, bytes.count <= maximumBytes else { return false }
            let file = entryURL(key: key, kind: kind)
            if PathSafety.exists(file), !isRegularFile(file) { return false }
            try bytes.write(to: file, options: .atomic)
            let timestamp = now()
            try? FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
            ledger?[file.lastPathComponent] = File(url: file, size: Int64(bytes.count), accessed: timestamp)
            accesses[file.lastPathComponent] = timestamp; persistedAccesses[file.lastPathComponent] = timestamp
            diagnostics?.record("cache.write", bytes: bytes.count)
            evictOverflow()
            return true
        } catch { return false }
    }

    private func persistAccesses() {
        let requested = pendingAccesses; pendingAccesses = []
        for name in requested {
            let file = directory.appending(path: name)
            guard let timestamp = accesses[name], isRegularFile(file) else { continue }
            do {
                try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
                persistedAccesses[name] = timestamp
                if var entry = ledger?[name] { entry.accessed = timestamp; ledger?[name] = entry }
            } catch { }
        }
    }

    private func maintainIfNeeded() {
        guard maintenanceRequested || lastMaintenance.map({ now().timeIntervalSince($0) >= 300 }) ?? true else { return }
        maintenanceRequested = false; lastMaintenance = now()
        for file in Array(ledger?.values ?? Dictionary<String, File>().values) {
            let accessed = max(file.accessed, accesses[file.url.lastPathComponent] ?? file.accessed)
            if now().timeIntervalSince(accessed) >= maximumIdleAge || file.size > maximumEntryBytes { remove(file.url) }
        }
        evictOverflow()
    }

    private func evictOverflow() {
        var total = ledger?.values.reduce(Int64(0)) { $0 + $1.size } ?? 0
        guard total > maximumBytes else { return }
        let candidates = ledger?.values.sorted {
            max($0.accessed, accesses[$0.url.lastPathComponent] ?? $0.accessed) < max($1.accessed, accesses[$1.url.lastPathComponent] ?? $1.accessed)
        } ?? []
        for file in candidates where total > maximumBytes {
            if remove(file.url) { total -= file.size }
        }
    }

    @discardableResult private func remove(_ file: URL) -> Bool {
        guard isRegularFile(file) else { return false }
        do {
            try FileManager.default.removeItem(at: file)
            let name = file.lastPathComponent
            ledger?.removeValue(forKey: name); accesses.removeValue(forKey: name); persistedAccesses.removeValue(forKey: name)
            pendingAccesses.remove(name)
            if name.hasPrefix("detail-") {
                let key = String(name.dropFirst(7).dropLast(5))
                forgetDetail(key)
            }
            return true
        } catch { return false }
    }

    private func checkDirectory(create: Bool) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            current.append(path: component, directoryHint: .isDirectory)
            if !PathSafety.exists(current), create {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let type = try FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
        }
    }

    private func pendingStorageIsUsable() -> Bool {
        var ancestor = directory
        while !PathSafety.exists(ancestor), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        return (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    private func read(_ file: URL, limit: Int? = nil) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= (limit ?? maximumEntryBytes) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        var result = Data(count: Int(metadata.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if Task.isCancelled { throw CancellationError() }
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno)) }
                offset += count
            }
        }
        return result
    }

    private func readGeneration() throws -> String? {
        let file = directory.appending(path: ".generation")
        guard PathSafety.exists(file) else { return nil }
        return String(decoding: try read(file, limit: 128), as: UTF8.self)
    }

    private func directoryStamp() -> String? {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
    }

    private func fileStamp(_ file: URL) -> FileStamp? {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStamp(device: UInt64(bitPattern: Int64(metadata.st_dev)), inode: UInt64(metadata.st_ino), size: metadata.st_size,
                         modifiedSeconds: metadata.st_mtimespec.tv_sec, modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
                         changedSeconds: metadata.st_ctimespec.tv_sec, changedNanoseconds: metadata.st_ctimespec.tv_nsec)
    }

    private func files() -> [File] {
        diagnostics?.record("cache.scan")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.range(of: #"^(detail|history)-[0-9a-f]{64}\.json$"#, options: .regularExpression) != nil,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, let accessed = attributes[.modificationDate] as? Date else { return nil }
            return File(url: url, size: size.int64Value, accessed: accessed)
        }
    }

    private func isRegularFile(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private func entryURL(key: String, kind: String) -> URL { directory.appending(path: "\(kind)-\(key).json") }

    private func digest<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private struct Detail {
        let identity: RepositoryCacheIdentity
        var latest: RepositoryDetailSnapshot
        var persisted: RepositoryDetailSnapshot?
        var latestCost: Int
        var persistedCost: Int
        var persistedStamp: FileStamp?
        var checkpointedAt: Date
        var lastUse: Int
        var memoryCost: Int { RepositoryDiskCache.addingCost(MemoryLayout<Self>.stride, RepositoryDiskCache.addingCost(latestCost, persistedCost)) }
    }

    private struct FileStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    private struct Entry<Value: Codable & Sendable>: Codable {
        let version: Int
        let repository: RepositoryCacheRepositoryIdentity
        let key: String
        let value: Value
    }

    private struct Header: Decodable { let repository: RepositoryCacheRepositoryIdentity }

    private struct File {
        let url: URL
        let size: Int64
        var accessed: Date
    }
}

import Foundation
import CryptoKit
import Darwin

public actor RepositoryDiskCache: RepositoryDetailCaching {
    public let directory: URL
    private let maximumBytes: Int
    private let maximumEntryBytes: Int
    private let maximumIdleAge: TimeInterval
    private let now: @Sendable () -> Date
    private let diagnostics: RepositoryReadDiagnostics?
    private let waitForWrite: @Sendable () async throws -> Void
    private var details: [String: Detail] = [:]
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
        self.maximumIdleAge = max(0, maximumIdleAge); self.now = now; self.diagnostics = diagnostics
        self.waitForWrite = waitForWrite ?? { try await Task.sleep(for: .seconds(1)) }
    }

    public func loadDetail(for identity: RepositoryCacheIdentity) async -> RepositoryDetailSnapshot? {
        guard !Task.isCancelled, identity.isCurrent(), let key = digest(identity), !invalidatedDetails.contains(key) else { return nil }
        if let remembered = details[key], pendingDetails.contains(key), pendingStorageIsUsable() {
            diagnostics?.record("cache.detail.hit")
            return remembered.latest
        }
        let loaded: RepositoryDetailSnapshot? = load(key: key, kind: "detail", repository: identity.repository)
        guard let loaded, loaded.isComplete, !Task.isCancelled, identity.isCurrent() else {
            if !Task.isCancelled { details.removeValue(forKey: key) }
            return nil
        }
        if let remembered = details[key], remembered.latest.hasSameContent(as: loaded) {
            return remembered.latest
        }
        details[key] = Detail(identity: identity, latest: loaded, persisted: loaded, checkpointedAt: now())
        return loaded
    }

    public func saveDetail(_ value: RepositoryDetailSnapshot, for identity: RepositoryCacheIdentity) async {
        guard !Task.isCancelled, maximumBytes > 0, maximumEntryBytes > 0,
              identity.isCurrent(), value.isComplete, let key = digest(identity) else { return }
        if details[key] == nil, !invalidatedDetails.contains(key) {
            let stored: RepositoryDetailSnapshot? = load(key: key, kind: "detail", repository: identity.repository)
            if let stored, stored.isComplete {
                details[key] = Detail(identity: identity, latest: stored, persisted: stored, checkpointedAt: now())
            }
        }
        guard !Task.isCancelled, identity.isCurrent() else { return }
        var remembered = details[key] ?? Detail(identity: identity, latest: value, persisted: nil, checkpointedAt: now())
        remembered.latest = value
        details[key] = remembered
        invalidatedDetails.remove(key)
        let contentChanged = remembered.persisted.map { !value.hasSameContent(as: $0) } ?? true
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
        pendingDetails.remove(key); details.removeValue(forKey: key); invalidatedDetails.insert(key)
        if pendingDetails.isEmpty { cancelWriter() }
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
        pendingDetails = pendingDetails.filter { key in
            guard let detail = details[key], detail.identity.isCurrent(), !invalidatedDetails.contains(key) else {
                details.removeValue(forKey: key)
                return false
            }
            return true
        }
        guard !pendingDetails.isEmpty || !pendingAccesses.isEmpty || maintenanceRequested else { return }
        withMutation(create: !pendingDetails.isEmpty) {
            let requested = self.pendingDetails
            self.pendingDetails = []
            for key in requested {
                guard var detail = self.details[key] else { continue }
                guard detail.identity.isCurrent(), !self.invalidatedDetails.contains(key) else {
                    self.details.removeValue(forKey: key); continue
                }
                if self.write(detail.latest, key: key, kind: "detail", repository: detail.identity.repository) {
                    detail.persisted = detail.latest; detail.checkpointedAt = self.now()
                    self.details[key] = detail
                }
            }
            self.persistAccesses()
            self.maintainIfNeeded()
        }
    }

    private func load<Value: Codable & Sendable>(key: String, kind: String, repository: RepositoryCacheRepositoryIdentity) -> Value? {
        guard !Task.isCancelled, (try? checkDirectory(create: false)) != nil else { return nil }
        let file = entryURL(key: key, kind: kind)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let persisted = attributes[.modificationDate] as? Date else { return nil }
            let lastAccess = max(persisted, accesses[file.lastPathComponent] ?? persisted)
            guard now().timeIntervalSince(lastAccess) < maximumIdleAge else {
                requestMaintenance()
                return nil
            }
            let data = try read(file)
            let entry = try JSONDecoder().decode(Entry<Value>.self, from: data)
            guard entry.version == 1, entry.key == key, entry.repository == repository, !Task.isCancelled else {
                if kind == "detail", !Task.isCancelled { details.removeValue(forKey: key) }
                return nil
            }
            accesses[file.lastPathComponent] = now()
            if persistedAccesses[file.lastPathComponent] == nil { persistedAccesses[file.lastPathComponent] = persisted }
            if now().timeIntervalSince(persistedAccesses[file.lastPathComponent] ?? persisted) >= 60 {
                pendingAccesses.insert(file.lastPathComponent); scheduleWriter()
            }
            requestMaintenance()
            diagnostics?.record("cache.\(kind).hit", bytes: data.count)
            return entry.value
        } catch {
            if kind == "detail", !Task.isCancelled { details.removeValue(forKey: key) }
            diagnostics?.record("cache.\(kind).miss")
            return nil
        }
    }

    private func requestMaintenance() {
        if lastMaintenance.map({ now().timeIntervalSince($0) >= 300 }) ?? true {
            maintenanceRequested = true; scheduleWriter()
        }
    }

    private func withMutation(create: Bool, _ body: () -> Void) {
        guard !Task.isCancelled, (try? checkDirectory(create: create)) != nil else { return }
        let lock = directory.appending(path: ".write.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        do {
            let generation = try readGeneration()
            let stamp = directoryStamp()
            if ledger == nil || ledgerGeneration != generation || ledgerDirectoryStamp != stamp {
                ledger = Dictionary(uniqueKeysWithValues: files().map { ($0.url.lastPathComponent, $0) })
            }
            let replacement = UUID().uuidString
            let generationURL = directory.appending(path: ".generation")
            if PathSafety.exists(generationURL), !isRegularFile(generationURL) { return }
            try Data(replacement.utf8).write(to: generationURL, options: .atomic)
            ledgerGeneration = replacement
            body()
            ledgerDirectoryStamp = directoryStamp()
        } catch { ledger = nil }
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
                details.removeValue(forKey: key); pendingDetails.remove(key)
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
        var checkpointedAt: Date
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

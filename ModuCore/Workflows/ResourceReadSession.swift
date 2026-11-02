import Foundation

public actor ResourceReadSession {
    private let service: WorkspaceService
    private let diagnostics: RepositoryReadDiagnostics?
    private var contexts: [ContextKey: ContextEntry] = [:]
    private var repositories: [FamilyKey: FamilyEntry] = [:]
    private var replacementDecisions: [String: (fingerprint: String, value: Bool)] = [:]
    private var generation = 0

    public init(service: WorkspaceService, diagnostics: RepositoryReadDiagnostics? = nil) {
        self.service = service.inspectionService(); self.diagnostics = diagnostics
    }

    public func prepare(_ resource: Resource, in record: WorkspaceRecord, visibility: GitChangeVisibility = .application,
                        revalidateConfiguration: Bool = false) async throws -> ResourceReadContext {
        try await prepare(resource, in: record, visibility: visibility, revalidateConfiguration: revalidateConfiguration, repositoryProvider: nil)
    }

    func prepareForInspection(_ resource: Resource, in record: WorkspaceRecord, revalidateConfiguration: Bool,
                              repositoryProvider: @escaping @Sendable () async throws -> RepositoryInspection) async throws -> ResourceReadContext {
        try await prepare(resource, in: record, visibility: .all, revalidateConfiguration: revalidateConfiguration, repositoryProvider: repositoryProvider)
    }

    private func prepare(_ resource: Resource, in record: WorkspaceRecord, visibility: GitChangeVisibility,
                         revalidateConfiguration: Bool, repositoryProvider: (@Sendable () async throws -> RepositoryInspection)?) async throws -> ResourceReadContext {
        try service.checkCancellation()
        let token = generation
        let family = FamilyKey(resource: resource, record: record)
        let key = ContextKey(family: family, resource: resource, application: Self.isApplication(visibility))
        var prepared = repositories[family]
        if let current = prepared, !current.isCurrent() { prepared = nil }
        if var current = prepared, revalidateConfiguration {
            let updated = try await ConfigurationSnapshot.capture(git: service.git, at: current.inspection.path,
                                                                    gitDirectory: current.inspection.path.appending(path: ".git"))
            try checkGeneration(token)
            if let updated, updated.output == current.configuration.output {
                current.configuration = updated
                prepared = current
                repositories[family] = prepared
            } else { prepared = nil }
        }
        if let prepared, let entry = contexts[key], entry.familyVersion == prepared.version,
           let rebound = entry.context.rebinding(to: record), entry.configuration.isCurrent() {
            var configuration = entry.configuration
            if revalidateConfiguration {
                let updated = try await ConfigurationSnapshot.capture(git: service.git, at: rebound.path, gitDirectory: rebound.gitDirectory)
                try checkGeneration(token)
                if let updated, updated.output == configuration.output { configuration = updated }
                else { return try await rebuild(resource, record: record, visibility: visibility, family: family, key: key, prepared: prepared, token: token, repositoryProvider: repositoryProvider) }
            }
            let context: ResourceReadContext
            if rebound.indexIsCurrent { context = rebound }
            else {
                context = try await service.refreshSubmoduleRead(rebound, visibility: visibility)
                try checkGeneration(token)
            }
            guard context.isValid(in: record), configuration.isCurrent() else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
            contexts[key] = ContextEntry(context: context, configuration: configuration, familyVersion: prepared.version)
            diagnostics?.record("prepare.hit")
            return context
        }
        return try await rebuild(resource, record: record, visibility: visibility, family: family, key: key, prepared: prepared, token: token, repositoryProvider: repositoryProvider)
    }

    public func invalidate(resources: Set<Resource>) {
        generation += 1
        let names = Set(resources.map(\.repo))
        let affected = Set(repositories.keys.filter { names.contains($0.repository) })
        contexts = contexts.filter { !affected.contains($0.key.family) }
        for family in affected { repositories.removeValue(forKey: family) }
    }

    func cachedReplacementDecision(for commonDirectory: URL, namespace: String, fingerprint: String) -> Bool? {
        guard let cached = replacementDecisions[commonDirectory.path + "\n" + namespace], cached.fingerprint == fingerprint else { return nil }
        return cached.value
    }

    func cacheReplacementDecision(_ value: Bool, for commonDirectory: URL, namespace: String, fingerprint: String) {
        replacementDecisions[commonDirectory.path + "\n" + namespace] = (fingerprint, value)
    }

    private func rebuild(_ resource: Resource, record: WorkspaceRecord, visibility: GitChangeVisibility, family: FamilyKey,
                         key: ContextKey, prepared: FamilyEntry?, token: Int,
                         repositoryProvider: (@Sendable () async throws -> RepositoryInspection)?) async throws -> ResourceReadContext {
        let start = ContinuousClock.now
        let inspection: RepositoryInspection
        let entry: FamilyEntry?
        if let prepared { inspection = prepared.inspection; entry = prepared }
        else {
            if let repositoryProvider { inspection = try await repositoryProvider() }
            else { inspection = try await service.checkedRepository(for: resource, in: record) }
            try checkGeneration(token)
            let configuration = try await ConfigurationSnapshot.capture(git: service.git, at: inspection.path,
                                                                        gitDirectory: inspection.path.appending(path: ".git"))
            try checkGeneration(token)
            if let configuration {
                guard configuration.matches(origin: inspection.origin) else {
                    throw ModuError("origin-mismatch", .repositoryOriginDoesNotMatchWorkspaceRecord(inspection.path.path))
                }
                if let completed = repositories[family], completed.isCurrent(),
                   completed.inspection.path == inspection.path, completed.inspection.commonDirectory == inspection.commonDirectory,
                   completed.inspection.origin == inspection.origin, completed.configuration.output == configuration.output {
                    entry = completed
                } else { entry = try FamilyEntry(inspection: inspection, configuration: configuration) }
                repositories[family] = entry
            } else { entry = nil; repositories.removeValue(forKey: family) }
        }
        let context = try await service.prepareResourceRead(resource, in: record, repository: inspection, visibility: visibility)
        try checkGeneration(token)
        if let entry, entry.isCurrent(),
           let configuration = try await ConfigurationSnapshot.capture(git: service.git, at: context.path, gitDirectory: context.gitDirectory) {
            try checkGeneration(token)
            guard configuration.matches(origin: inspection.origin) else {
                throw ModuError("origin-mismatch", .repositoryOriginDoesNotMatchWorkspaceRecord(context.path.path))
            }
            guard context.isValid(in: record), configuration.isCurrent() else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
            contexts[key] = ContextEntry(context: context, configuration: configuration, familyVersion: entry.version)
        } else { contexts.removeValue(forKey: key) }
        diagnostics?.record("prepare.miss", duration: start.duration(to: .now))
        return context
    }

    private func checkGeneration(_ token: Int) throws {
        guard !Task.isCancelled, token == generation else { throw ModuError("cancelled", .operationCancelled) }
    }

    private static func isApplication(_ visibility: GitChangeVisibility) -> Bool {
        if case .application = visibility { return true }; return false
    }

    private struct FamilyKey: Hashable {
        let workspace: String
        let repository: String?
        let url: String?
        init(resource: Resource, record: WorkspaceRecord) {
            workspace = record.root; repository = resource.repo
            url = resource.repo.flatMap { name in record.repositories.first { $0.id == name }?.url }
        }
    }

    private struct ContextKey: Hashable {
        let family: FamilyKey
        let resource: Resource
        let application: Bool
    }

    private struct ContextEntry {
        let context: ResourceReadContext
        let configuration: ConfigurationSnapshot
        let familyVersion: UUID
    }

    private struct FamilyEntry {
        let inspection: RepositoryInspection
        var configuration: ConfigurationSnapshot
        let paths: [ReadPathIdentity]
        let registrations: RegistrationFingerprint
        let version: UUID

        init(inspection: RepositoryInspection, configuration: ConfigurationSnapshot) throws {
            self.inspection = inspection; self.configuration = configuration; version = UUID()
            paths = try [inspection.path, inspection.path.appending(path: ".git"), URL(fileURLWithPath: inspection.commonDirectory)].map(ReadPathIdentity.init)
            registrations = try RegistrationFingerprint(directory: URL(fileURLWithPath: inspection.commonDirectory).appending(path: "worktrees"))
        }

        func isCurrent() -> Bool {
            configuration.isCurrent() && paths.allSatisfy { (try? ReadPathIdentity($0.url)) == $0 }
                && (try? RegistrationFingerprint(directory: registrations.directory)) == registrations
        }
    }

    private struct RegistrationFingerprint: Equatable {
        let directory: URL
        let paths: [ReadPathIdentity]
        init(directory: URL) throws {
            self.directory = directory
            var files = [directory]
            if PathSafety.exists(directory) {
                try PathSafety.directory(directory)
                let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                for entry in entries { files += [entry, entry.appending(path: "gitdir"), entry.appending(path: "commondir")] }
            }
            paths = try files.map(ReadPathIdentity.init)
        }
    }

    private struct ConfigurationSnapshot {
        let output: Data
        let files: [ReadPathIdentity]
        let origin: String?

        static func capture(git: Git, at path: URL, gitDirectory: URL) async throws -> ConfigurationSnapshot? {
            let output: Data
            do { output = try await git.run(["config", "--null", "--show-origin", "--includes", "--list"], at: path).stdout }
            catch {
                if Task.isCancelled || (error as? ModuError)?.code == "cancelled" { throw error }
                return nil
            }
            let fields = output.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count % 2 == 1, fields.last?.isEmpty == true else { return nil }
            var sources = Set<URL>()
            var origin: String?
            var index = 0
            while index + 1 < fields.count {
                let location = String(decoding: fields[index], as: UTF8.self)
                let pair = fields[index + 1].split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false)
                if pair.first?.elementsEqual("remote.origin.url".utf8) == true, pair.count == 2 {
                    origin = String(decoding: pair[1], as: UTF8.self)
                }
                index += 2
                guard location.hasPrefix("file:") else { return nil }
                let source = String(location.dropFirst(5))
                guard !source.isEmpty else { return nil }
                sources.insert(PathSafety.canonical(URL(fileURLWithPath: source, relativeTo: URL(fileURLWithPath: path.path, isDirectory: true))))
            }
            sources.insert(gitDirectory.appending(path: "HEAD"))
            guard let files = try? sources.sorted(by: { $0.path < $1.path }).map(ReadPathIdentity.init) else { return nil }
            return ConfigurationSnapshot(output: output, files: files, origin: origin)
        }

        func isCurrent() -> Bool { files.allSatisfy { (try? ReadPathIdentity($0.url)) == $0 } }
        func matches(origin expected: String?) -> Bool { expected == nil || origin == expected }
    }
}

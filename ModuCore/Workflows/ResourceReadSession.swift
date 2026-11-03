import Foundation

public actor ResourceReadSession {
    private let service: WorkspaceService
    private let diagnostics: RepositoryReadDiagnostics?
    private var contexts: [ContextKey: ContextEntry] = [:]
    private var repositories: [FamilyKey: FamilyEntry] = [:]
    private var replacementDecisions: [String: (fingerprint: String, value: Bool)] = [:]
    private var configurationLocations: ConfigurationLocations?
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
        var configurationReads: [ConfigurationScope: ConfigurationRead] = [:]
        var prepared = repositories[family]
        if let current = prepared, !current.isCurrent() { prepared = nil }
        if var current = prepared, revalidateConfiguration {
            let updated = try await readConfiguration(for: current.inspection, reads: &configurationReads)
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
                let updated = try await readConfiguration(at: rebound.path, gitDirectory: rebound.gitDirectory,
                                                         commonDirectory: rebound.commonDirectory, reads: &configurationReads)
                try checkGeneration(token)
                if let updated, updated.output == configuration.output { configuration = updated }
                else {
                    return try await rebuild(resource, record: record, visibility: visibility, family: family, key: key, prepared: prepared,
                                             token: token, configurationReads: &configurationReads, repositoryProvider: repositoryProvider)
                }
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
        return try await rebuild(resource, record: record, visibility: visibility, family: family, key: key, prepared: prepared,
                                 token: token, configurationReads: &configurationReads, repositoryProvider: repositoryProvider)
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
                         configurationReads: inout [ConfigurationScope: ConfigurationRead],
                         repositoryProvider: (@Sendable () async throws -> RepositoryInspection)?) async throws -> ResourceReadContext {
        let start = ContinuousClock.now
        let inspection: RepositoryInspection
        let entry: FamilyEntry?
        if let prepared { inspection = prepared.inspection; entry = prepared }
        else {
            if let repositoryProvider { inspection = try await repositoryProvider() }
            else { inspection = try await service.checkedRepository(for: resource, in: record) }
            try checkGeneration(token)
            let configuration = try await readConfiguration(for: inspection, reads: &configurationReads)
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
           let configuration = try await readConfiguration(at: context.path, gitDirectory: context.gitDirectory,
                                                           commonDirectory: context.commonDirectory, reads: &configurationReads) {
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

    private func readConfiguration(for inspection: RepositoryInspection,
                                   reads: inout [ConfigurationScope: ConfigurationRead]) async throws -> ConfigurationSnapshot? {
        let directory = inspection.path.appending(path: ".git")
        let commonDirectory = URL(fileURLWithPath: inspection.commonDirectory)
        // Use Git's spelling across volume aliases, keeping a separate HEAD directory when commondir exists.
        let gitDirectory = PathSafety.exists(directory.appending(path: "commondir")) ? directory : commonDirectory
        return try await readConfiguration(at: inspection.path, gitDirectory: gitDirectory,
                                           commonDirectory: commonDirectory, reads: &reads)
    }

    private func readConfiguration(at path: URL, gitDirectory: URL, commonDirectory: URL,
                                   reads: inout [ConfigurationScope: ConfigurationRead]) async throws -> ConfigurationSnapshot? {
        let scope = ConfigurationScope(path: path, gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        if let remembered = reads[scope] {
            switch remembered {
            case .snapshot(let snapshot) where snapshot.isCurrent(): return snapshot
            case .unavailable: return nil
            case .snapshot: break
            }
        }
        let snapshot = try await captureConfiguration(at: path, gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        reads[scope] = snapshot.map(ConfigurationRead.snapshot) ?? .unavailable
        return snapshot
    }

    private func captureConfiguration(at path: URL, gitDirectory: URL, commonDirectory: URL) async throws -> ConfigurationSnapshot? {
        if configurationLocations == nil {
            let locations = try await ConfigurationLocations.discover(git: service.git, at: path)
            try service.checkCancellation()
            configurationLocations = locations
        }
        guard let configurationLocations, case .available(let locations) = configurationLocations else { return nil }
        return try await ConfigurationSnapshot.capture(git: service.git, at: path, gitDirectory: gitDirectory,
                                                       commonDirectory: commonDirectory, defaultLocations: locations)
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

    private struct ConfigurationScope: Hashable {
        let path: String
        let gitDirectory: String
        let commonDirectory: String

        init(path: URL, gitDirectory: URL, commonDirectory: URL) {
            self.path = path.absoluteURL.path
            self.gitDirectory = gitDirectory.absoluteURL.path
            self.commonDirectory = commonDirectory.absoluteURL.path
        }
    }

    private enum ConfigurationRead {
        case snapshot(ConfigurationSnapshot)
        case unavailable
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

    private enum ConfigurationLocations: Sendable {
        case available([String])
        case unavailable

        static func discover(git: Git, at path: URL) async throws -> Self {
            let environment = git.runner.environment
            guard ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "HOME", "XDG_CONFIG_HOME"].allSatisfy({ key in
                environment[key]?.contains(where: { $0 == "\n" || $0 == "\0" }) != true
            }) else { return .unavailable }
            var locations: [String] = []
            for variable in ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"] {
                let output: CommandOutput
                do { output = try await git.run(["var", variable], at: path, allowFailure: true) }
                catch {
                    if Task.isCancelled || (error as? ModuError)?.code == "cancelled" { throw error }
                    return .unavailable
                }
                if output.status == 1, output.stdout.isEmpty, output.stderr.isEmpty { continue }
                guard output.status == 0, let text = String(data: output.stdout, encoding: .utf8),
                      !text.contains("\0"), text.hasSuffix("\n") else { return .unavailable }
                let paths = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
                guard paths.allSatisfy({ !$0.isEmpty }) else { return .unavailable }
                locations += paths.map(String.init)
            }
            return .available(locations)
        }
    }

    private struct ConfigurationSnapshot {
        let output: Data
        let files: [ReadPathIdentity]
        let origin: String?

        static func capture(git: Git, at path: URL, gitDirectory: URL, commonDirectory: URL,
                            defaultLocations: [String]) async throws -> ConfigurationSnapshot? {
            let output: Data
            do { output = try await git.run(["config", "--null", "--show-origin", "--includes", "--list"], at: path).stdout }
            catch {
                if Task.isCancelled || (error as? ModuError)?.code == "cancelled" { throw error }
                return nil
            }
            guard let entries = parse(output, at: path) else { return nil }
            var sources = Set<URL>()
            var origin: String?
            for location in defaultLocations {
                guard let url = fileURL(location, relativeTo: path) else { return nil }
                sources.insert(url)
            }
            for entry in entries {
                sources.insert(entry.source)
                if entry.key == "remote.origin.url" { origin = entry.value }
            }
            let includes = entries.filter(\.isInclude)
            if !includes.isEmpty {
                let expanded: CommandOutput
                do {
                    expanded = try await git.run(["config", "--null", "--show-origin", "--includes", "--type=path", "--get-regexp",
                                                  #"^(include\.path|includeif\..*\.path)$"#], at: path, allowFailure: true)
                } catch {
                    if Task.isCancelled || (error as? ModuError)?.code == "cancelled" { throw error }
                    return nil
                }
                guard expanded.status == 0, let paths = parse(expanded.stdout, at: path), paths.count == includes.count,
                      zip(paths, includes).allSatisfy({ pair in pair.0.source == pair.1.source && pair.0.key == pair.1.key }) else { return nil }
                for entry in paths {
                    guard let value = entry.value, let url = fileURL(value, relativeTo: entry.source.deletingLastPathComponent()) else { return nil }
                    sources.insert(url)
                }
            }
            // Reftable publishes HEAD changes through tables.list rather than rewriting HEAD.
            sources.formUnion([gitDirectory.appending(path: "HEAD"), gitDirectory.appending(path: "reftable/tables.list"),
                               commonDirectory.appending(path: "reftable/tables.list")])
            guard let files = try? sources.sorted(by: { $0.path < $1.path }).map(ReadPathIdentity.init) else { return nil }
            return ConfigurationSnapshot(output: output, files: files, origin: origin)
        }

        func isCurrent() -> Bool { files.allSatisfy { (try? ReadPathIdentity($0.url)) == $0 } }
        func matches(origin expected: String?) -> Bool { expected == nil || origin == expected }

        private static func parse(_ output: Data, at path: URL) -> [Entry]? {
            let fields = output.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count % 2 == 1, fields.last?.isEmpty == true else { return nil }
            var entries: [Entry] = []
            var index = 0
            while index + 1 < fields.count {
                guard let location = String(data: fields[index], encoding: .utf8) else { return nil }
                guard location.hasPrefix("file:") else { return nil }
                guard let source = fileURL(String(location.dropFirst(5)), relativeTo: path) else { return nil }
                let pair = fields[index + 1].split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = pair.first, let key = String(data: first, encoding: .utf8), !key.isEmpty else { return nil }
                let value: String?
                if pair.count == 2 {
                    guard let text = String(data: pair[1], encoding: .utf8) else { return nil }
                    value = text
                } else { value = nil }
                entries.append(Entry(source: source, key: key, value: value))
                index += 2
            }
            return entries
        }

        private static func fileURL(_ value: String, relativeTo directory: URL) -> URL? {
            guard !value.isEmpty, !value.contains("\0") else { return nil }
            // Keep the source spelling so retargeting a configuration symlink invalidates its identity.
            return URL(fileURLWithPath: value.hasPrefix("/") ? value : directory.path + "/" + value)
        }

        private struct Entry {
            let source: URL
            let key: String
            let value: String?
            var isInclude: Bool { key == "include.path" || key.hasPrefix("includeif.") && key.hasSuffix(".path") }
        }
    }
}

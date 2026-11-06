import Foundation

public struct WorkspaceService: Sendable {
    public let store: WorkspaceStore
    public let git: Git
    var worktreeRemoval: WorktreeRemoval
    let trashDirectory: @Sendable (URL) throws -> URL
    public init(store: WorkspaceStore = .init(), git: Git = .init(), trash: @escaping @Sendable (URL) throws -> URL = { try PathSafety.trash($0) }) { self.store = store; self.git = git; self.trashDirectory = trash; self.worktreeRemoval = .init(runner: git.runner) }

    public func candidate(_ url: URL, requireExistingRecord: Bool = false, recoverUnregisteredResources: Bool = false) async throws -> URL {
        try checkCancellation()
        let root = PathSafety.canonical(url)
        try store.checkBoundary(root)
        let existing = PathSafety.exists(store.recordURL(root))
        guard existing || !requireExistingRecord else { throw MonoDeckError("workspace-record-missing", .workspaceRecordIsMissing(store.recordURL(root).path)) }
        if existing { _ = try store.load(root) }
        _ = try await checkCandidate(root, hasRecord: existing, recoverUnregisteredResources: recoverUnregisteredResources)
        return root
    }

    public func openWorkspace(_ url: URL, skill: URL? = nil, installer: InstallationService = .init(), progress: ProgressHandler = { _ in }) async -> OperationResult {
        await openWorkspaceWithRecord(url, skill: skill, installer: installer, progress: progress).result
    }

    public func openWorkspaceWithRecord(_ url: URL, skill: URL? = nil, installer: InstallationService = .init(), requireExistingRecord: Bool = false, recoverUnregisteredResources: Bool = false, progress: ProgressHandler = { _ in }) async -> (record: WorkspaceRecord?, result: OperationResult, skillError: MonoDeckError?) {
        let root = PathSafety.canonical(url)
        var item = ItemResult(.workspace())
        var result = OperationResult(command: "workspace.open", workspace: root.path)
        var loaded: WorkspaceRecord?
        var skillError: MonoDeckError?
        do {
            let lease = try await store.lock(root); defer { lease.unlock() }
            let existing = PathSafety.exists(store.recordURL(root))
            guard existing || !requireExistingRecord else { throw MonoDeckError("workspace-record-missing", .workspaceRecordIsMissing(store.recordURL(root).path)) }
            var record = existing ? try store.load(root) : WorkspaceRecord(root: root.path)
            var stash: String?
            var pendingCommitPaths: [String] = []
            do {
                let recovered = try await checkCandidate(root, hasRecord: existing, recoverUnregisteredResources: recoverUnregisteredResources)
                progress(.init(root.path, .openingWorkspace))
                if !PathSafety.exists(root.appending(path: ".git")) {
                    _ = try await git.run(["init"], at: root)
                    item.effects.append(.init("git-init", root.path))
                    try await git.checkRepository(root, main: true)
                }
                let tracked = try await git.run(["-c", "core.fsmonitor=false", "ls-files", "-z", "--", "repositories", "worktrees"], at: root)
                guard tracked.stdout.isEmpty else { throw MonoDeckError("path-conflict", .workspaceTracksRepositoriesOrWorktreesRemovePathsFrom) }
                if let recovered {
                    try checkCancellation()
                    progress(.init(root.path, .saving, cancellable: false))
                    try persist(recovered, into: &record)
                    item.effects.append(.init("save-workspace-record", store.recordURL(root).path))
                }
                var updatingSkill = false
                if let skill {
                    do { updatingSkill = try installer.skillNeedsUpdate(from: skill, workspace: root) }
                    catch { skillError = .wrap(error) }
                    let directory = root.appending(path: ".agents/skills/mono-deck-workflow")
                    // Legacy managed links are replaced by the installer without modifying their targets.
                    if skillError == nil, (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) != .typeSymbolicLink {
                        for path in installer.skillPaths(from: skill).map({ ".agents/skills/mono-deck-workflow/\($0)" }) {
                            if try await git.discardWorkspaceFileChanges(path, at: root) {
                                item.effects.append(.init("discard-workspace-file-changes", root.appending(path: path).path))
                            }
                        }
                        updatingSkill = try installer.skillNeedsUpdate(from: skill, workspace: root)
                    }
                }
                if updatingSkill {
                    if try await validateAndClean(&record) { item.effects.append(.init("save-workspace-record", store.recordURL(root).path)) }
                    progress(.init(root.path, .saving, cancellable: false))
                    stash = try await git.stashWorkspaceChanges(at: root)
                    if let stash { item.effects.append(.init("stash-workspace", stash)) }
                }
                if try await git.ensureIgnore(["repositories", "worktrees"], at: root, cancellable: !updatingSkill) { item.effects.append(.init("update-ignore", root.appending(path: ".gitignore").path)) }
                for name in ["repositories", "worktrees"] {
                    let directory = root.appending(path: name)
                    if !PathSafety.exists(directory) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false); item.effects.append(.init("create-directory", directory.path)) }
                }
                if !updatingSkill {
                    if try await validateAndClean(&record) { item.effects.append(.init("save-workspace-record", store.recordURL(root).path)) }
                }
                if !existing && recovered == nil {
                    progress(.init(root.path, .saving, cancellable: false))
                    try persist(record, into: &record)
                    item.effects.append(.init("save-workspace-record", store.recordURL(root).path))
                }
                progress(.init(root.path, .saving, cancellable: false))
                var paths = [".gitignore"]
                if let skill {
                    do {
                        let directory = ".agents/skills/mono-deck-workflow"
                        if try installer.installSkill(from: skill, workspace: root) { item.effects.append(.init("install-skill", root.appending(path: "\(directory)/SKILL.md").path)) }
                        paths += installer.skillPaths(from: skill).map { "\(directory)/\($0)" }
                    } catch { skillError = .wrap(error) }
                }
                let message = updatingSkill ? "chore: update MonoDeck workflow skill" : "chore: initialize MonoDeck workspace"
                if stash != nil { pendingCommitPaths = paths }
                if let oid = try await git.commitWorkspaceFiles(paths, message: message, at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
                pendingCommitPaths = []
            } catch { fail(&item, error) }
            if let stash {
                do {
                    try await git.restoreWorkspaceChanges(stash, unstaging: pendingCommitPaths, at: root)
                    item.effects.append(.init("restore-workspace", stash))
                } catch {
                    let error = MonoDeckError.wrap(error)
                    let prior = item.message.map { $0 + "\n" } ?? ""
                    fail(&item, MonoDeckError(error.code, prior + error.message, userMessage: .joined([item.userMessage, error.userMessage].compactMap { $0 }, separator: "\n")))
                }
            }
            if item.status == .success { loaded = record }
        } catch { fail(&item, error) }
        result.items = [item]; result.summarize(cancelled: item.reasonCode == "cancelled")
        return (loaded, result, skillError)
    }

    public func read(_ root: URL) async throws -> WorkspaceRecord {
        try checkCancellation()
        try PathSafety.directory(root)
        let record = try store.load(root)
        try checkCancellation()
        return record
    }

    public func load(_ root: URL) async throws -> WorkspaceRecord {
        let lease = try await store.lock(root); defer { lease.unlock() }
        try PathSafety.directory(root)
        var record = try store.load(root)
        _ = try await validateAndClean(&record)
        return record
    }
    public func inspect(_ root: URL, scope: InspectionScope = .all, excluding excluded: Resource? = nil, content: InspectionContent = .withSummary) async -> OperationResult {
        do { return await inspect(try await read(root), scope: scope, excluding: excluded, content: content) }
        catch { return .init(command: "workspace.inspect", workspace: root.path, status: .failed, error: .wrap(error)) }
    }
    public func inspect(_ record: WorkspaceRecord, scope: InspectionScope = .all, excluding excluded: Resource? = nil, content: InspectionContent = .withSummary, visibility: GitChangeVisibility = .all, concurrency: Int = 1, including included: Set<Resource>? = nil, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async -> OperationResult {
        await inspectConcurrent(record, scope: scope, excluding: excluded, content: content, visibility: visibility, concurrency: max(1, min(concurrency, 6)), including: included, publish: publish)
    }
    func applyInspectionSnapshot(_ snapshot: ResourceSnapshot, content: InspectionContent, to item: inout ItemResult, at path: URL) throws {
        item.data = ["path": path.path]
        if let error = snapshot.changesError { throw error }
        item.data?["working-tree"] = snapshot.changes?.isEmpty == true ? "clean" : "dirty"
        guard case .withSummary = content else { return }
        if let error = snapshot.summaryError { throw error }
        guard let summary = snapshot.summary else { throw MonoDeckError("resource-unavailable", .repositorySummaryIsUnavailable) }
        item.data?["head"] = summary.head; item.data?["head-oid"] = summary.headOID
        item.data?["base"] = summary.base; item.data?["base-oid"] = summary.baseOID
        item.data?["base-error"] = summary.baseError
    }
    public func resources(_ record: WorkspaceRecord) -> [Resource] {
        record.repositories.map { .repository($0.id) } + record.groups.keys.sorted().flatMap { name in
            [Resource.group(name)] + record.groups[name]!.repositoryIDs.map { .member(groupName: name, repositoryID: $0) }
        }
    }
    public func checked(_ resource: Resource, in record: WorkspaceRecord) async throws -> URL {
        let repository = try await checkedRepository(for: resource, in: record)
        let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
        try await checkWorktree(resource, at: path, repository: repository)
        return path
    }
    func checkedRepository(for resource: Resource, in record: WorkspaceRecord) async throws -> RepositoryInspection {
        try store.checkBoundary(record.rootURL)
        let repository = resource.repositoryID.flatMap { id in record.repositories.first { $0.id == id } }
        let configured: Bool
        switch resource {
        case .repository: configured = repository != nil
        case .group(let name): configured = record.groups[name] != nil
        case .member(let group, let repo): configured = record.groups[group]?.repositoryIDs.contains(repo) == true
        case .workspace, .cli: configured = false
        }
        guard configured else { throw MonoDeckError("target-not-configured", .resourceIsNotConfigured) }
        let main: URL
        let origin: String?
        if let repo = resource.repositoryID {
            guard let repository else { throw MonoDeckError("target-not-configured", .repositoryIsNotConfigured) }
            main = try PathSafety.child("repositories/\(repo)", of: record.rootURL, allowMissing: false)
            origin = repository.url
        } else {
            main = record.rootURL
            origin = nil
        }
        return try await inspectMainRepository(main, origin: origin)
    }
    func inspectMainRepository(_ main: URL, origin: String? = nil) async throws -> RepositoryInspection {
        let metadata = try await git.repositoryMetadata(at: main)
        if let metadata { try await git.checkRepository(main, origin: origin, main: true, topLevel: metadata.topLevel) }
        else { try await git.checkRepository(main, origin: origin, main: true) }
        let registrations = try await git.registrations(at: main)
        let common: String
        if let metadata { common = metadata.commonDirectory }
        else { common = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: main).text }
        return .init(path: main, origin: origin, registrations: registrations, commonDirectory: common)
    }
    func checkWorktree(_ resource: Resource, at path: URL, repository: RepositoryInspection, validateHEAD: Bool = true) async throws {
        guard repository.registrations.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }) else {
            throw MonoDeckError("resource-unavailable", resource.repositoryID == nil ? .groupRootRegistrationIsMissing : .worktreeRegistrationIsMissing(path.path))
        }
        var headValidated = false
        if resource.kind != .repository {
            let metadata = try await git.repositoryMetadata(at: path, validateHEAD: validateHEAD)
            if let metadata { try await git.checkRepository(path, origin: repository.origin, topLevel: metadata.topLevel) }
            else { try await git.checkRepository(path, origin: repository.origin) }
            let actual: String
            if let metadata { actual = metadata.commonDirectory; headValidated = validateHEAD }
            else { actual = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: path).text }
            guard PathSafety.identity(URL(fileURLWithPath: repository.commonDirectory)) == PathSafety.identity(URL(fileURLWithPath: actual)) else {
                throw MonoDeckError("resource-unavailable", resource.repositoryID == nil ? .groupRootBelongsAnotherRepository : .worktreeBelongsAnotherRepository)
            }
        }
        if validateHEAD && !headValidated {
            guard try await git.oid("HEAD", at: path) != nil else { throw MonoDeckError("resource-unavailable", .worktreeHEADIsUnavailable) }
        }
    }
    private func checkCandidate(_ root: URL, hasRecord: Bool, recoverUnregisteredResources: Bool) async throws -> WorkspaceRecord? {
        try PathSafety.directory(root)
        guard FileManager.default.isWritableFile(atPath: root.path) else { throw MonoDeckError("workspace-unwritable", .workspaceIsNotWritable(root.path)) }
        try store.checkNesting(root)
        var needsRecovery = false
        if !hasRecord {
            do { try PathSafety.emptyResourceDirectories(root) }
            catch let error as MonoDeckError where error.code == "workspace-not-empty" && recoverUnregisteredResources { needsRecovery = true }
        }
        if needsRecovery {
            for name in ["repositories", "worktrees"] { try PathSafety.directory(root.appending(path: name), allowMissing: true) }
            return try await recoverWorkspaceRecord(root)
        }
        let top = try await git.run(["rev-parse", "--show-toplevel"], at: root, allowFailure: true)
        if top.status == 0 { try await git.checkRepository(root, main: true) }
        else {
            let bare = try await git.run(["rev-parse", "--is-bare-repository"], at: root, allowFailure: true)
            guard !PathSafety.exists(root.appending(path: ".git")), bare.text != "true" else { throw MonoDeckError("resource-unavailable", .chooseOrdinaryGitMainWorktreeOrDirectoryOutside) }
        }
        for name in ["repositories", "worktrees"] { try PathSafety.directory(root.appending(path: name), allowMissing: true) }
        return nil
    }
    private func validateAndClean(_ record: inout WorkspaceRecord) async throws -> Bool {
        for name in record.groups.keys { try await git.validateRef(name, at: record.rootURL) }
        try checkCancellation()
        return try removeMissingResources(from: &record)
    }
    private func removeMissingResources(from record: inout WorkspaceRecord) throws -> Bool {
        func exists(_ resource: Resource) -> Bool {
            // Keep unsafe or unreadable paths configured so inspection can report the error.
            guard let path = try? PathSafety.child(resource.path, of: record.rootURL) else { return true }
            return PathSafety.exists(path)
        }
        var candidate = record
        candidate.repositories.removeAll { !exists(.repository($0.id)) }
        let repositories = Set(candidate.repositories.map(\.id))
        for (name, group) in record.groups {
            if !exists(.group(name)) { candidate.groups.removeValue(forKey: name) }
            else { candidate.groups[name]?.repositoryIDs = group.repositoryIDs.filter { repositories.contains($0) && exists(.member(groupName: name, repositoryID: $0)) } }
        }
        guard candidate != record else { return false }
        try persist(candidate, into: &record)
        return true
    }
    func persist(_ candidate: WorkspaceRecord, into record: inout WorkspaceRecord) throws {
        do { try store.save(candidate); record = candidate }
        catch {
            let actual: WorkspaceRecord
            do { actual = try store.load(candidate.rootURL) }
            catch { throw MonoDeckError("save-outcome-unknown", .workspaceRecordSaveAndVerificationFailedResourcesWereKept) }
            record = actual
            if actual != candidate { throw error }
        }
    }
    func fail(_ item: inout ItemResult, _ error: Error) {
        let error = MonoDeckError.wrap(error)
        item.status = error.code == "cancelled" ? .cancelled : .failed
        item.reasonCode = error.code; item.message = error.message; item.userMessage = error.userMessage
    }
    func checkCancellation() throws { if Task.isCancelled { throw MonoDeckError("cancelled", .operationCancelledCompletedResourcesWereKept) } }
}

struct RepositoryInspection: Sendable {
    var path: URL
    var origin: String?
    var registrations: [WorktreeRegistration]
    var commonDirectory: String
}

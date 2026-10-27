import Foundation

public struct WorkspaceService: Sendable {
    public let store: WorkspaceStore
    public let git: Git
    let trashDirectory: @Sendable (URL) throws -> URL
    public init(store: WorkspaceStore = .init(), git: Git = .init(), trash: @escaping @Sendable (URL) throws -> URL = { try PathSafety.trash($0) }) { self.store = store; self.git = git; self.trashDirectory = trash }

    public func candidate(_ url: URL, requireExistingRecord: Bool = false) async throws -> URL {
        let root = PathSafety.canonical(url)
        try store.checkBoundary(root)
        let existing = PathSafety.exists(store.recordURL(root))
        guard existing || !requireExistingRecord else { throw ModuError("configuration-missing", .workspaceRecordIsMissing(store.recordURL(root).path)) }
        let lease = try (existing ? store.lock(root) : nil)
        defer { lease?.unlock() }
        if existing { _ = try store.load(root) }
        try await checkCandidate(root, hasRecord: existing)
        return root
    }

    public func openWorkspace(_ url: URL, skill: URL? = nil, installer: InstallationService = .init(), progress: ProgressHandler = { _ in }) async -> OperationResult {
        await openWorkspaceWithRecord(url, skill: skill, installer: installer, progress: progress).result
    }

    public func openWorkspaceWithRecord(_ url: URL, skill: URL? = nil, installer: InstallationService = .init(), requireExistingRecord: Bool = false, progress: ProgressHandler = { _ in }) async -> (record: WorkspaceRecord?, result: OperationResult, skillError: ModuError?) {
        let root = PathSafety.canonical(url)
        var item = ItemResult(.workspace())
        var result = OperationResult(command: "workspace.open", workspace: root.path)
        var loaded: WorkspaceRecord?
        var skillError: ModuError?
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            let existing = PathSafety.exists(store.recordURL(root))
            guard existing || !requireExistingRecord else { throw ModuError("configuration-missing", .workspaceRecordIsMissing(store.recordURL(root).path)) }
            var record = existing ? try store.load(root) : WorkspaceRecord(root: root.path)
            var stash: String?
            var pendingCommitPaths: [String] = []
            do {
                try await checkCandidate(root, hasRecord: existing)
                progress(.init(root.path, .openingWorkspace))
                if !PathSafety.exists(root.appending(path: ".git")) {
                    _ = try await git.run(["init"], at: root)
                    item.effects.append(.init("git-init", root.path))
                    try await git.checkRepository(root, main: true)
                }
                let tracked = try await git.run(["-c", "core.fsmonitor=false", "ls-files", "-z", "--", "repositories", "worktrees"], at: root)
                guard tracked.stdout.isEmpty else { throw ModuError("path-conflict", .workspaceTracksRepositoriesOrWorktreesRemovePathsFrom) }
                var updatingSkill = false
                if let skill {
                    do { updatingSkill = try installer.skillNeedsUpdate(from: skill, workspace: root) }
                    catch { skillError = .wrap(error) }
                    let directory = root.appending(path: ".agents/skills/modu-workflow")
                    // Legacy managed links are replaced by the installer without modifying their targets.
                    if skillError == nil, (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) != .typeSymbolicLink {
                        for path in installer.skillPaths(from: skill).map({ ".agents/skills/modu-workflow/\($0)" }) {
                            if try await git.discardWorkspaceFileChanges(path, at: root) {
                                item.effects.append(.init("discard-workspace-file-changes", root.appending(path: path).path))
                            }
                        }
                        updatingSkill = try installer.skillNeedsUpdate(from: skill, workspace: root)
                    }
                }
                if updatingSkill {
                    if try await validateAndClean(&record) { item.effects.append(.init("save-configuration", store.recordURL(root).path)) }
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
                    if try await validateAndClean(&record) { item.effects.append(.init("save-configuration", store.recordURL(root).path)) }
                }
                if !existing {
                    progress(.init(root.path, .saving, cancellable: false))
                    try persist(record, into: &record)
                    item.effects.append(.init("save-configuration", store.recordURL(root).path))
                }
                progress(.init(root.path, .saving, cancellable: false))
                var paths = [".gitignore"]
                if let skill {
                    do {
                        let directory = ".agents/skills/modu-workflow"
                        if try installer.installSkill(from: skill, workspace: root) { item.effects.append(.init("install-skill", root.appending(path: "\(directory)/SKILL.md").path)) }
                        paths += installer.skillPaths(from: skill).map { "\(directory)/\($0)" }
                    } catch { skillError = .wrap(error) }
                }
                let message = updatingSkill ? "chore: update Modu workflow skill" : "chore: initialize Modu workspace"
                if stash != nil { pendingCommitPaths = paths }
                if let oid = try await git.commitWorkspaceFiles(paths, message: message, at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
                pendingCommitPaths = []
            } catch { fail(&item, error) }
            if let stash {
                do {
                    try await git.restoreWorkspaceChanges(stash, unstaging: pendingCommitPaths, at: root)
                    item.effects.append(.init("restore-workspace", stash))
                } catch {
                    let error = ModuError.wrap(error)
                    let prior = item.message.map { $0 + "\n" } ?? ""
                    fail(&item, ModuError(error.code, prior + error.message, userMessage: .joined([item.userMessage, error.userMessage].compactMap { $0 }, separator: "\n")))
                }
            }
            if item.status == .success { loaded = record }
        } catch { fail(&item, error) }
        result.items = [item]; result.summarize(cancelled: item.reasonCode == "cancelled")
        return (loaded, result, skillError)
    }

    public func load(_ root: URL) async throws -> WorkspaceRecord {
        let lease = try store.lock(root); defer { lease.unlock() }
        try PathSafety.directory(root)
        var record = try store.load(root)
        _ = try await validateAndClean(&record)
        return record
    }
    public func inspect(_ root: URL, scope: InspectionScope = .all, excluding excluded: Resource? = nil) async -> OperationResult {
        do { return await inspect(try await load(root), scope: scope, excluding: excluded) }
        catch { return .init(command: "workspace.inspect", workspace: root.path, status: .failed, error: .wrap(error)) }
    }
    public func inspect(_ record: WorkspaceRecord, scope: InspectionScope = .all, excluding excluded: Resource? = nil, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async -> OperationResult {
        let root = record.rootURL
        do { try store.checkBoundary(root) }
        catch { return .init(command: "workspace.inspect", workspace: root.path, status: .failed, error: .wrap(error)) }
        var result = OperationResult(command: "workspace.inspect", workspace: root.path)
        var workspace = ItemResult(.workspace())
        do { try await git.checkRepository(root, main: true); workspace.data = ["root": record.root] } catch { fail(&workspace, error) }
        result.items.append(workspace)
        for resource in resources(record) where resource != excluded && scope.includes(resource) {
            var item = ItemResult(resource)
            do {
                let snapshot = try await snapshot(resource, in: record)
                await publish(snapshot)
                item.data = ["path": record.rootURL.appending(path: resource.path).path]
                if let error = snapshot.changesError { throw error }
                item.data?["working-tree"] = snapshot.changes?.isEmpty == true ? "clean" : "dirty"
                if let error = snapshot.summaryError { throw error }
                guard let summary = snapshot.summary else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
                item.data?["head"] = summary.head; item.data?["head-oid"] = summary.headOID
                item.data?["base"] = summary.base; item.data?["base-oid"] = summary.baseOID
                item.data?["base-error"] = summary.baseError
            } catch { fail(&item, error) }
            result.items.append(item)
        }
        result.summarize(cancelled: result.items.contains { $0.status == .cancelled })
        return result
    }
    public func resources(_ record: WorkspaceRecord) -> [Resource] {
        record.repositories.map { .repository($0.id) } + record.groups.keys.sorted().flatMap { name in
            [Resource.group(name)] + record.groups[name]!.repositories.map { .member(name, $0) }
        }
    }
    public func checked(_ resource: Resource, in record: WorkspaceRecord) async throws -> URL {
        try store.checkBoundary(record.rootURL)
        guard resources(record).contains(resource) else { throw ModuError("target-not-configured", .resourceIsNotConfigured) }
        let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
        if let repo = resource.repo {
            guard let repository = record.repositories.first(where: { $0.id == repo }) else { throw ModuError("target-not-configured", .repositoryIsNotConfigured) }
            let main = try PathSafety.child("repositories/\(repo)", of: record.rootURL, allowMissing: false)
            try await git.checkRepository(main, origin: repository.url, main: true)
            try await git.checkRepository(path, origin: repository.url)
            let registered = try await git.registrations(at: main)
            guard registered.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }) else { throw ModuError("resource-unavailable", .worktreeRegistrationIsMissing(path.path)) }
            let expected = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: main).text
            let actual = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: path).text
            guard PathSafety.identity(URL(fileURLWithPath: expected)) == PathSafety.identity(URL(fileURLWithPath: actual)) else { throw ModuError("resource-unavailable", .worktreeBelongsAnotherRepository) }
        } else {
            try await git.checkRepository(record.rootURL, main: true)
            let registered = try await git.registrations(at: record.rootURL)
            guard registered.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }) else { throw ModuError("resource-unavailable", .groupRootRegistrationIsMissing) }
            try await git.checkRepository(path)
            let expected = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: record.rootURL).text
            let actual = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: path).text
            guard PathSafety.identity(URL(fileURLWithPath: expected)) == PathSafety.identity(URL(fileURLWithPath: actual)) else { throw ModuError("resource-unavailable", .groupRootBelongsAnotherRepository) }
        }
        guard try await git.oid("HEAD", at: path) != nil else { throw ModuError("resource-unavailable", .worktreeHEADIsUnavailable) }
        return path
    }
    private func checkCandidate(_ root: URL, hasRecord: Bool) async throws {
        try PathSafety.directory(root)
        guard FileManager.default.isWritableFile(atPath: root.path) else { throw ModuError("workspace-unwritable", .workspaceIsNotWritable(root.path)) }
        try store.checkNesting(root)
        if !hasRecord { try PathSafety.emptyResourceDirectories(root) }
        let top = try await git.run(["rev-parse", "--show-toplevel"], at: root, allowFailure: true)
        if top.status == 0 { try await git.checkRepository(root, main: true) }
        else {
            let bare = try await git.run(["rev-parse", "--is-bare-repository"], at: root, allowFailure: true)
            guard !PathSafety.exists(root.appending(path: ".git")), bare.text != "true" else { throw ModuError("resource-unavailable", .chooseOrdinaryGitMainWorktreeOrDirectoryOutside) }
        }
        for name in ["repositories", "worktrees"] { try PathSafety.directory(root.appending(path: name), allowMissing: true) }
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
            else { candidate.groups[name]?.repositories = group.repositories.filter { repositories.contains($0) && exists(.member(name, $0)) } }
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
            catch { throw ModuError("save-outcome-unknown", .configurationSaveAndVerificationFailedResourcesWereKept) }
            record = actual
            if actual != candidate { throw error }
        }
    }
    func fail(_ item: inout ItemResult, _ error: Error) {
        let error = ModuError.wrap(error)
        item.status = error.code == "cancelled" ? .cancelled : .failed
        item.reasonCode = error.code; item.message = error.message; item.userMessage = error.userMessage
    }
    func checkCancellation() throws { if Task.isCancelled { throw ModuError("cancelled", .operationCancelledCompletedResourcesWereKept) } }
}

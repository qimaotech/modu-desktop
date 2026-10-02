import Foundation

public struct WorkspaceService: Sendable {
    public let store: WorkspaceStore
    public let git: Git
    let trashDirectory: @Sendable (URL) throws -> URL
    public init(store: WorkspaceStore = .init(), git: Git = .init(), trash: @escaping @Sendable (URL) throws -> URL = { try PathSafety.trash($0) }) { self.store = store; self.git = git; self.trashDirectory = trash }

    public func candidate(_ url: URL) async throws -> URL {
        let root = PathSafety.canonical(url)
        let existing = PathSafety.exists(store.recordURL(root))
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
        var item = ItemResult(.init(kind: "workspace", path: "."))
        var result = OperationResult(command: "workspace.open", workspace: root.path)
        var loaded: WorkspaceRecord?
        var skillError: ModuError?
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            let existing = PathSafety.exists(store.recordURL(root))
            guard existing || !requireExistingRecord else { throw ModuError("configuration-missing", "Workspace record is missing: \(store.recordURL(root).path)") }
            var record = existing ? try store.load(root) : WorkspaceRecord(root: root.path)
            try await checkCandidate(root, hasRecord: existing)
            progress(.init(root.path, "Opening workspace…"))
            if !PathSafety.exists(root.appending(path: ".git")) {
                _ = try await git.run(["init"], at: root)
                item.effects.append(.init("git-init", root.path))
                try await git.checkRepository(root, main: true)
            }
            let tracked = try await git.run(["-c", "core.fsmonitor=false", "ls-files", "-z", "--", "repositories", "worktrees"], at: root)
            guard tracked.stdout.isEmpty else { throw ModuError("path-conflict", "Workspace tracks repositories/ or worktrees/. Remove those paths from Git outside Modu first.") }
            if try await git.ensureIgnore(["repositories", "worktrees"], at: root) { item.effects.append(.init("update-ignore", root.appending(path: ".gitignore").path)) }
            for name in ["repositories", "worktrees"] {
                let directory = root.appending(path: name)
                if !PathSafety.exists(directory) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false); item.effects.append(.init("create-directory", directory.path)) }
            }
            let cleaned = try await validateAndClean(&record)
            if !existing {
                progress(.init(root.path, "Saving…", cancellable: false))
                try persist(record, into: &record)
                item.effects.append(.init("save-configuration", store.recordURL(root).path))
            } else if cleaned { item.effects.append(.init("save-configuration", store.recordURL(root).path)) }
            progress(.init(root.path, "Saving…", cancellable: false))
            var paths = [".gitignore"]
            if let skill {
                do {
                    let path = ".agents/skills/modu-workflow/SKILL.md"
                    if try installer.installSkill(from: skill, workspace: root) { item.effects.append(.init("install-skill", root.appending(path: path).path)) }
                    paths.append(path)
                } catch { skillError = .wrap(error) }
            }
            if let oid = try await git.commitWorkspaceFiles(paths, message: "chore: initialize Modu workspace", at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
            loaded = record
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
    public func inspect(_ root: URL, excluding excluded: Resource? = nil) async -> OperationResult {
        do { return await inspect(try await load(root), excluding: excluded) }
        catch { return .init(command: "workspace.inspect", workspace: root.path, status: "failed", error: .wrap(error)) }
    }
    public func inspect(_ record: WorkspaceRecord, excluding excluded: Resource? = nil) async -> OperationResult {
        let root = record.rootURL
        var result = OperationResult(command: "workspace.inspect", workspace: root.path)
        var workspace = ItemResult(.init(kind: "workspace", path: "."))
        do { try await git.checkRepository(root, main: true); workspace.data = ["root": record.root] } catch { fail(&workspace, error) }
        result.items.append(workspace)
        for resource in resources(record) where resource != excluded {
            var item = ItemResult(resource)
            do {
                let path = try await checked(resource, in: record)
                item.data = ["path": path.path]
                let origin = record.repositories.first(where: { $0.id == resource.repo })?.url
                item.data?["working-tree"] = try await git.changes(at: path).isEmpty ? "clean" : "dirty"
                let summary = try await git.summary(at: path, origin: origin)
                item.data?["head"] = summary.head; item.data?["head-oid"] = summary.headOID
                item.data?["base"] = summary.base; item.data?["base-oid"] = summary.baseOID
                item.data?["base-error"] = summary.baseError
            } catch { fail(&item, error) }
            result.items.append(item)
        }
        result.summarize()
        return result
    }
    public func resources(_ record: WorkspaceRecord) -> [Resource] {
        record.repositories.map { .repository($0.id) } + record.groups.keys.sorted().flatMap { name in
            [Resource.group(name)] + record.groups[name]!.repositories.map { .member(name, $0) }
        }
    }
    public func checked(_ resource: Resource, in record: WorkspaceRecord) async throws -> URL {
        guard resources(record).contains(resource) else { throw ModuError("target-not-configured", "Resource is not configured.") }
        let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
        if let repo = resource.repo {
            guard let repository = record.repositories.first(where: { $0.id == repo }) else { throw ModuError("target-not-configured", "Repository is not configured.") }
            let main = try PathSafety.child("repositories/\(repo)", of: record.rootURL, allowMissing: false)
            try await git.checkRepository(main, origin: repository.url, main: true)
            try await git.checkRepository(path, origin: repository.url)
            let registered = try await git.registrations(at: main)
            guard registered.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }) else { throw ModuError("resource-unavailable", "Worktree registration is missing: \(path.path)") }
            let expected = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: main).text
            let actual = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: path).text
            guard PathSafety.identity(URL(fileURLWithPath: expected)) == PathSafety.identity(URL(fileURLWithPath: actual)) else { throw ModuError("resource-unavailable", "Worktree belongs to another repository.") }
        } else {
            try await git.checkRepository(record.rootURL, main: true)
            let registered = try await git.registrations(at: record.rootURL)
            guard registered.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }) else { throw ModuError("resource-unavailable", "Group root registration is missing.") }
            try await git.checkRepository(path)
            let expected = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: record.rootURL).text
            let actual = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: path).text
            guard PathSafety.identity(URL(fileURLWithPath: expected)) == PathSafety.identity(URL(fileURLWithPath: actual)) else { throw ModuError("resource-unavailable", "Group root belongs to another repository.") }
        }
        guard try await git.oid("HEAD", at: path) != nil else { throw ModuError("resource-unavailable", "Worktree HEAD is unavailable.") }
        return path
    }
    private func checkCandidate(_ root: URL, hasRecord: Bool) async throws {
        try PathSafety.directory(root)
        guard FileManager.default.isWritableFile(atPath: root.path) else { throw ModuError("workspace-unwritable", "Workspace is not writable: \(root.path)") }
        try store.checkNesting(root)
        if !hasRecord { try PathSafety.emptyResourceDirectories(root) }
        let top = try await git.run(["rev-parse", "--show-toplevel"], at: root, allowFailure: true)
        if top.status == 0 { try await git.checkRepository(root, main: true) }
        else {
            let bare = try await git.run(["rev-parse", "--is-bare-repository"], at: root, allowFailure: true)
            guard !PathSafety.exists(root.appending(path: ".git")), bare.text != "true" else { throw ModuError("resource-unavailable", "Choose an ordinary Git main worktree or a directory outside another repository.") }
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
            catch { throw ModuError("save-outcome-unknown", "Configuration save and verification failed. Resources were kept; inspect the workspace record before retrying.") }
            record = actual
            if actual != candidate { throw error }
        }
    }
    func fail(_ item: inout ItemResult, _ error: Error) {
        let error = ModuError.wrap(error)
        item.status = error.code == "cancelled" ? "cancelled" : "failed"
        item.reasonCode = error.code; item.message = error.message
    }
    func checkCancellation() throws { if Task.isCancelled { throw ModuError("cancelled", "Operation cancelled; completed resources were kept.") } }
}

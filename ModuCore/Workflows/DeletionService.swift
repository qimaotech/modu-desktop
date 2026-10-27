import Foundation

public enum DeleteRequest: Sendable {
    case repository(String)
    case group(String)
    case member(group: String, repo: String)

    public init?(_ resource: Resource) {
        switch resource {
        case .repository(let name): self = .repository(name)
        case .group(let name): self = .group(name)
        case .member(let group, let repo): self = .member(group: group, repo: repo)
        case .workspace, .cli: return nil
        }
    }
}

extension WorkspaceService {
    public func previewDelete(_ request: DeleteRequest, at root: URL) async throws -> [DeletionTarget] {
        let lease = try store.lock(root); defer { lease.unlock() }
        let record = try store.load(root)
        return try await deletionTargets(deleteResources(request, record: record), record: record)
    }
    public func remove(_ request: DeleteRequest, at root: URL, authorization: [DeletionTarget]? = nil, execute: Bool = false, progress: ProgressHandler = { _ in }) async -> OperationResult {
        let command: String
        if case .repository = request { command = "repo.remove" } else { command = "worktree.remove" }
        var result = OperationResult(command: command, workspace: root.path)
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            let targets = try await deletionTargets(deleteResources(request, record: record), record: record, readRisks: execute || authorization == nil)
            if !execute {
                guard let authorization else { result.status = .confirmationRequired; result.reasonCode = "confirmation-required"; result.plan = targets; return result }
                try verifyAuthorization(authorization, actual: targets)
            }
            for (index, target) in targets.enumerated() {
                let item = await delete(target, record: &record, progress: progress)
                result.items.append(item)
                if item.status != .success {
                    result.items += targets.dropFirst(index + 1).map { .notProcessed($0.resource) }
                    break
                }
            }
            result.summarize(cancelled: result.items.contains { $0.status == .cancelled })
        } catch { result = .init(command: command, workspace: root.path, status: .failed, error: .wrap(error)) }
        return result
    }
    func verifyAuthorization(_ expected: [DeletionTarget], actual: [DeletionTarget]) throws {
        guard expected.count == actual.count, zip(expected, actual).allSatisfy({ a, b in a.resource == b.resource && a.path == b.path && a.branch == b.branch && a.detached == b.detached }) else {
            throw ModuError("confirmation-changed", .deletionTargetsOrCheckedOutBranchesChangedNothing)
        }
    }
    public func deleteResources(_ request: DeleteRequest, record: WorkspaceRecord) throws -> [Resource] {
        switch request {
        case .repository(let name):
            guard record.repositories.contains(where: { $0.id == name }) else { throw ModuError("target-not-configured", .repositoryIsNotConfigured) }
            return record.groups.keys.sorted().filter { record.groups[$0]!.repositories.contains(name) }.map { .member($0, name) } + [.repository(name)]
        case .group(let name):
            guard let group = record.groups[name] else { throw ModuError("target-not-configured", .groupIsNotConfigured) }
            return group.repositories.map { .member(name, $0) } + [.group(name)]
        case .member(let group, let repo):
            guard record.groups[group]?.repositories.contains(repo) == true else { throw ModuError("target-not-configured", .memberIsNotConfigured) }
            return [.member(group, repo)]
        }
    }
    func deletionTargets(_ resources: [Resource], record: WorkspaceRecord, readRisks: Bool = true) async throws -> [DeletionTarget] {
        for resource in resources where resource.kind == .repository { try await checkUnmanagedWorktrees(resource.repo!, record: record) }
        var targets: [DeletionTarget] = []
        for offset in stride(from: 0, to: resources.count, by: 6) {
            let batch = try await withThrowingTaskGroup(of: (Int, DeletionTarget).self) { group in
                for index in offset..<min(offset + 6, resources.count) {
                    group.addTask { (index, try await deletionTarget(resources[index], record: record, readRisks: readRisks)) }
                }
                var completed: [(Int, DeletionTarget)] = []
                for try await target in group { completed.append(target) }
                return completed.sorted { $0.0 < $1.0 }.map(\.1)
            }
            targets += batch
        }
        return targets
    }
    private func deletionTarget(_ resource: Resource, record: WorkspaceRecord, readRisks: Bool) async throws -> DeletionTarget {
        let path = try PathSafety.child(resource.path, of: record.rootURL)
        let exists = PathSafety.exists(path)
        if resource.kind == .repository {
            if exists { _ = try await checked(resource, in: record) }
            else if record.groups.values.contains(where: { $0.repositories.contains(resource.repo!) }) { throw ModuError("resource-unavailable", .missingRepositoryStillHasConfiguredMembers) }
            var risks: [UserMessage] = exists ? [.mainRepositoryWillBeMovedTrash] : [.onlyRepositoryDeclarationWillBeRemoved]
            var dirty: Bool?
            if exists && readRisks {
                let changes = try await git.changes(at: path)
                dirty = !changes.isEmpty
                risks.append(changes.isEmpty ? .workingTreeIsClean : .changedPathsWillBeMovedTrash(changes.count))
            }
            return .init(resource: resource, path: path.path, branch: nil, detached: false, registered: exists, exists: exists, risks: risks.map(\.englishDescription), riskMessages: risks, dirty: dirty)
        }
        let repository = resource.repo.map { record.repositoryURL($0) } ?? record.rootURL
        try await git.checkRepository(repository, origin: resource.repo.flatMap { name in record.repositories.first { $0.id == name }?.url }, main: true)
        let registrations = try await git.registrations(at: repository)
        let entry = registrations.first { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }
        guard !exists || entry != nil else { throw ModuError("resource-unavailable", .existingDirectoryHasNoMatchingGitRegistration(path.path)) }
        guard entry?.locked != true else { throw ModuError("worktree-locked", .worktreeIsLocked(path.path)) }
        if let entry, let branch = entry.branch { try await git.checkBranchNotInUse(branch, registrations: registrations, at: repository, excluding: entry.path) }
        if let entry { guard entry.oid.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil, !entry.oid.allSatisfy({ $0 == "0" }), try await git.oid(entry.oid, at: repository) != nil else { throw ModuError("resource-unavailable", .registeredWorktreeHEADIsUnreadable(path.path)) } }
        var risks: [UserMessage] = []
        var dirty: Bool?
        if exists { _ = try await checked(resource, in: record) }
        if exists && readRisks {
            let changes = try await git.changes(at: path)
            dirty = !changes.isEmpty
            risks.append(changes.isEmpty ? .workingTreeIsClean : .changedPathsWillBePermanentlyDeleted(changes.count))
            let ignored = try await git.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory", "-z"], at: path)
            if !ignored.stdout.isEmpty { risks.append(.ignoredFilesWillBePermanentlyDeleted) }
        }
        if let entry, readRisks {
            let local = try await git.run(["rev-list", "--count", entry.oid, "--not", "--remotes", "--"], at: repository).text
            if local != "0" { risks.append(.commitsAreNotReachableFromLocallyKnownRemote(Int(local) ?? 0)) }
            if entry.branch == nil { risks.append(.detachedHEADNoBranchDelete) }
            else { risks.append(.currentLocalBranchWillBePermanentlyDeletedIncluding(entry.branch!)) }
        } else if entry == nil && readRisks { risks.append(.directoryAndRegistrationAreMissingOnlyDeclarationWill) }
        if resource.kind == .group && exists { try await checkNestedRepositories(path, group: resource.group!, record: record) }
        return .init(resource: resource, path: path.path, branch: entry?.branch, detached: entry != nil && entry?.branch == nil, registered: entry != nil, exists: exists, risks: risks.map(\.englishDescription), riskMessages: risks, dirty: dirty)
    }
    func checkUnmanagedWorktrees(_ repo: String, record: WorkspaceRecord) async throws {
        let main = try PathSafety.child("repositories/\(repo)", of: record.rootURL)
        guard PathSafety.exists(main) else { return }
        _ = try await checked(.repository(repo), in: record)
        let allowed = Set([PathSafety.identity(main)] + record.groups.keys.filter { record.groups[$0]!.repositories.contains(repo) }.map { PathSafety.identity(record.memberURL($0, repo)) })
        let others = try await git.registrations(at: main).filter { !allowed.contains(PathSafety.identity(URL(fileURLWithPath: $0.path))) }
        guard others.isEmpty else { throw ModuError("unmanaged-worktree", .unmanagedWorktrees(others.map(\.path))) }
    }
    private func checkNestedRepositories(_ path: URL, group: String, record: WorkspaceRecord) async throws {
        let members = Set((record.groups[group]?.repositories ?? []).map { PathSafety.identity(path.appending(path: $0)) })
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in scanError = error; return false }) else { throw ModuError("resource-unavailable", .couldNotInspectGroupDirectory) }
        while let url = enumerator.nextObject() as? URL {
            try checkCancellation()
            if members.contains(PathSafety.identity(url)) { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == ".git" {
                if PathSafety.identity(url.deletingLastPathComponent()) != PathSafety.identity(path) { throw ModuError("unmanaged-worktree", .groupContainsUnmanagedGitRepository(url.deletingLastPathComponent().path)) }
                enumerator.skipDescendants()
            }
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if PathSafety.exists(url.appending(path: "HEAD")), PathSafety.exists(url.appending(path: "objects")) {
                let bare = try await git.run(["rev-parse", "--is-bare-repository"], at: url, allowFailure: true)
                if bare.status == 0 && bare.text == "true" { throw ModuError("unmanaged-worktree", .groupContainsUnmanagedBareGitRepository(url.path)) }
            }
        }
        if let scanError { throw scanError }
    }
    func delete(_ target: DeletionTarget, record: inout WorkspaceRecord, progress: ProgressHandler) async -> ItemResult {
        var item = ItemResult(target.resource)
        do {
            try checkCancellation()
            let resource = target.resource
            let path = try PathSafety.child(resource.path, of: record.rootURL)
            if resource.kind == .repository {
                try await checkUnmanagedWorktrees(resource.repo!, record: record)
                guard !record.groups.values.contains(where: { $0.repositories.contains(resource.repo!) }) else { throw ModuError("resource-unavailable", .repositoryMembersMustBeRemovedFirst) }
            } else if resource.kind == .group {
                guard record.groups[resource.group!]?.repositories.isEmpty == true else { throw ModuError("resource-unavailable", .groupStillHasMembers) }
                if PathSafety.exists(path) { try await checkNestedRepositories(path, group: resource.group!, record: record) }
            }
            try checkCancellation()
            // Accept cancellation requests while non-cancellable commands finish this resource.
            progress(.init(resource.path, .deleting, cancellable: false))
            if resource.kind == .repository {
                if PathSafety.exists(path) { let trash = try trashDirectory(path); item.trashPath = trash.path; item.effects.append(.init("move-to-trash", path.path)) }
                var candidate = record; candidate.repositories.removeAll { $0.id == resource.repo }
                try persist(candidate, into: &record)
                item.effects.append(.init("remove-declaration", resource.path))
            } else {
                let repository = resource.repo.map { record.repositoryURL($0) } ?? record.rootURL
                if target.registered || target.exists {
                    item.effects.append(.init("remove-worktree", path.path, state: "unknown"))
                    _ = try await git.run(["worktree", "remove", "--force", "--", path.path], at: repository, cancellable: false)
                    item.effects[item.effects.count - 1].state = "applied"
                }
                var candidate = record
                if let repo = resource.repo { candidate.groups[resource.group!]!.repositories.removeAll { $0 == repo } }
                else { candidate.groups.removeValue(forKey: resource.group!) }
                try persist(candidate, into: &record)
                item.effects.append(.init("remove-declaration", resource.path))
                if let branch = target.branch {
                    let present = try await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: repository, allowFailure: true, cancellable: false)
                    if present.status == 0 { _ = try await git.run(["branch", "-D", "--", branch], at: repository, cancellable: false); item.effects.append(.init("delete-branch", branch)) }
                    else if present.status != 1 { throw ModuError("git-failed", .couldNotVerifyBranchDeletion(branch)) }
                }
            }
            progress(.init(resource.path, .deleted, snapshot: record))
        } catch {
            fail(&item, error)
            if let branch = target.branch { item.userMessage = .joined([item.userMessage, .branchTargetCompletedEffectsAreRetained(branch)].compactMap { $0 }, separator: " "); item.message = "\(item.message ?? "") Branch target: \(branch). Completed effects are retained." }
        }
        return item
    }
}

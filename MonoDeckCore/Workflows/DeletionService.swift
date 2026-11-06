import Foundation

public enum DeleteRequest: Sendable {
    case repository(String)
    case group(String)
    case member(groupName: String, repositoryID: String)
    case members(groupName: String, repositoryIDs: [String])

    public init?(_ resource: Resource) {
        switch resource {
        case .repository(let name): self = .repository(name)
        case .group(let name): self = .group(name)
        case .member(let group, let repo): self = .member(groupName: group, repositoryID: repo)
        case .workspace, .cli: return nil
        }
    }
}

extension WorkspaceService {
    public func previewDelete(_ request: DeleteRequest, at root: URL, publish: @Sendable (DeletionTarget) async -> Void = { _ in }) async throws -> [DeletionTarget] {
        let record = try await read(root)
        let reader = inspectionService()
        return try await reader.deletionTargets(deleteResources(request, record: record), record: record, publish: publish)
    }
    public func delete(_ request: DeleteRequest, at root: URL, authorization: [DeletionTarget]? = nil, confirmCurrentTargets: Bool = false, dryRun: Bool = false, progress: ProgressHandler = { _ in }) async -> OperationResult {
        let command: String
        switch request { case .repository: command = "repo.delete"; case .group: command = "group.delete"; case .member, .members: command = "group.member.delete" }
        var result = OperationResult(command: command, workspace: root.path)
        do {
            if dryRun || (authorization == nil && !confirmCurrentTargets) {
                let preview = try await previewDelete(request, at: root)
                result.plan = deletionPlan(preview); result.dryRun = dryRun
                result.status = dryRun ? .success : .confirmationRequired
                if !dryRun { result.reasonCode = "confirmation-required" }
                return result
            }
            let lease = try await store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            let targets = try await deletionTargets(deleteResources(request, record: record), record: record, readRisks: false)
            if let authorization { try verifyAuthorization(authorization, actual: targets) }
            for (index, target) in targets.enumerated() {
                let item = await delete(target, record: &record, progress: progress)
                result.items.append(item)
                if item.status != .success {
                    result.items += targets.dropFirst(index + 1).map { .notProcessed($0.resource) }
                    break
                }
            }
            result.summarize(cancelled: result.items.contains { $0.status == .cancelled })
        } catch { result = .init(command: command, workspace: root.path, status: .failed, error: .wrap(error)); result.dryRun = dryRun }
        return result
    }

    func deletionPlan(_ targets: [DeletionTarget]) -> OperationPlan {
        let actions = targets.flatMap { target -> [PlannedAction] in
            var actions: [PlannedAction] = []
            if target.resource.kind == .repository {
                if target.exists { actions.append(.init("move-to-trash", resource: target.resource, target: target.path)) }
            } else {
                if target.exists || target.gitRegistered { actions.append(.init("remove-worktree", resource: target.resource, target: target.path)) }
            }
            actions.append(.init("remove-record-entry", resource: target.resource, target: target.resource.path))
            if let branch = target.branch { actions.append(.init("delete-branch", resource: target.resource, target: branch)) }
            return actions
        }
        return .init(actions: actions, deletions: targets)
    }
    func verifyAuthorization(_ expected: [DeletionTarget], actual: [DeletionTarget]) throws {
        guard expected.count == actual.count, zip(expected, actual).allSatisfy({ a, b in a.resource == b.resource && a.path == b.path && a.branch == b.branch && a.detached == b.detached }) else {
            throw MonoDeckError("confirmation-changed", .deletionTargetsOrCheckedOutBranchesChangedNothing)
        }
    }
    public func deleteResources(_ request: DeleteRequest, record: WorkspaceRecord) throws -> [Resource] {
        switch request {
        case .repository(let name):
            guard record.repositories.contains(where: { $0.id == name }) else { throw MonoDeckError("target-not-configured", .repositoryIsNotConfigured) }
            return record.groups.keys.sorted().filter { record.groups[$0]!.repositoryIDs.contains(name) }.map { .member(groupName: $0, repositoryID: name) } + [.repository(name)]
        case .group(let name):
            guard let group = record.groups[name] else { throw MonoDeckError("target-not-configured", .groupIsNotConfigured) }
            return group.repositoryIDs.map { .member(groupName: name, repositoryID: $0) } + [.group(name)]
        case .member(let group, let repo):
            guard record.groups[group]?.repositoryIDs.contains(repo) == true else { throw MonoDeckError("target-not-configured", .memberIsNotConfigured) }
            return [.member(groupName: group, repositoryID: repo)]
        case .members(let groupName, let repositoryIDs):
            guard !repositoryIDs.isEmpty else { throw MonoDeckError("invalid-input", .chooseAtLeastOneRepository) }
            guard Set(repositoryIDs).count == repositoryIDs.count else { throw MonoDeckError("invalid-input", .groupMembersMustReferenceDistinctConfiguredRepositories) }
            return try repositoryIDs.flatMap { try deleteResources(.member(groupName: groupName, repositoryID: $0), record: record) }
        }
    }
    func deletionTargets(_ resources: [Resource], record: WorkspaceRecord, readRisks: Bool = true, publish: @Sendable (DeletionTarget) async -> Void = { _ in }) async throws -> [DeletionTarget] {
        for resource in resources where resource.kind == .repository { try await checkUnmanagedWorktrees(resource.repositoryID!, record: record) }
        return try await withThrowingTaskGroup(of: (Int, DeletionTarget).self) { group in
            var targets = [DeletionTarget?](repeating: nil, count: resources.count)
            var next = min(6, resources.count)
            for index in 0..<next {
                group.addTask { (index, try await deletionTarget(resources[index], record: record, readRisks: readRisks)) }
            }
            while let (index, target) = try await group.next() {
                try checkCancellation()
                targets[index] = target
                if next < resources.count {
                    let index = next
                    group.addTask { (index, try await deletionTarget(resources[index], record: record, readRisks: readRisks)) }
                    next += 1
                }
                await publish(target)
            }
            try checkCancellation()
            return targets.compactMap { $0 }
        }
    }
    private func deletionTarget(_ resource: Resource, record: WorkspaceRecord, readRisks: Bool) async throws -> DeletionTarget {
        let path = try PathSafety.child(resource.path, of: record.rootURL)
        let exists = PathSafety.exists(path)
        if resource.kind == .repository {
            if exists { _ = try await checked(resource, in: record) }
            else if record.groups.values.contains(where: { $0.repositoryIDs.contains(resource.repositoryID!) }) { throw MonoDeckError("resource-unavailable", .missingRepositoryStillHasConfiguredMembers) }
            var risks: [UserMessage] = exists ? [.mainRepositoryWillBeMovedTrash] : [.onlyRepositoryRecordEntryWillBeRemoved]
            var dirty: Bool?
            if exists && readRisks {
                let count = try await git.changeCount(at: path)
                dirty = count > 0
                risks.append(count == 0 ? .workingTreeIsClean : .changedPathsWillBeMovedTrash(count))
            }
            return .init(resource: resource, path: path.path, branch: nil, detached: false, gitRegistered: exists, exists: exists, risks: risks.map(\.englishDescription), riskMessages: risks, dirty: dirty)
        }
        let main = try resource.repositoryID.map { try PathSafety.child("repositories/\($0)", of: record.rootURL, allowMissing: false) } ?? record.rootURL
        let repository = try await inspectMainRepository(main)
        let registrations = repository.registrations
        let entry = registrations.first { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(path) }
        guard !exists || entry != nil else { throw MonoDeckError("resource-unavailable", .existingDirectoryHasNoMatchingGitRegistration(path.path)) }
        if let entry, let branch = entry.branch { try await git.checkBranchNotInUse(branch, registrations: registrations, at: repository.path, excluding: entry.path, commonDirectory: repository.commonDirectory) }
        var risks: [UserMessage] = []
        var dirty: Bool?
        if exists { try await checkWorktree(resource, at: path, repository: repository, validateHEAD: false) }
        if exists && readRisks {
            do {
                let count = try await git.changeCount(at: path)
                dirty = count > 0
                risks.append(count == 0 ? .workingTreeIsClean : .changedPathsWillBePermanentlyDeleted(count))
            } catch {
                try checkCancellation()
                let failure = MonoDeckError.wrap(error)
                guard failure.code != "cancelled" else { throw failure }
                risks.append(failure.userMessage)
            }
        }
        if let entry, readRisks {
            if entry.branch == nil { risks.append(.detachedHEADNoBranchDelete) }
            else { risks.append(.currentLocalBranchWillBePermanentlyDeletedIncluding(entry.branch!)) }
        } else if entry == nil && readRisks { risks.append(.missingWorktreeRemovesOnlyRecordEntry) }
        return .init(resource: resource, path: path.path, branch: entry?.branch, detached: entry != nil && entry?.branch == nil, gitRegistered: entry != nil, exists: exists, risks: risks.map(\.englishDescription), riskMessages: risks, dirty: dirty)
    }
    func checkUnmanagedWorktrees(_ repo: String, record: WorkspaceRecord) async throws {
        let main = try PathSafety.child("repositories/\(repo)", of: record.rootURL)
        guard PathSafety.exists(main) else { return }
        let resource = Resource.repository(repo)
        let repository = try await checkedRepository(for: resource, in: record)
        try await checkWorktree(resource, at: main, repository: repository)
        let allowed = Set([PathSafety.identity(main)] + record.groups.keys.filter { record.groups[$0]!.repositoryIDs.contains(repo) }.map { PathSafety.identity(record.memberURL($0, repo)) })
        let others = repository.registrations.filter { !allowed.contains(PathSafety.identity(URL(fileURLWithPath: $0.path))) }
        guard others.isEmpty else { throw MonoDeckError("unmanaged-worktree", .unmanagedWorktrees(others.map(\.path))) }
    }
    func delete(_ target: DeletionTarget, record: inout WorkspaceRecord, progress: ProgressHandler) async -> ItemResult {
        var item = ItemResult(target.resource)
        do {
            try checkCancellation()
            let resource = target.resource
            let path = try PathSafety.child(resource.path, of: record.rootURL)
            if resource.kind == .repository {
                try await checkUnmanagedWorktrees(resource.repositoryID!, record: record)
                guard !record.groups.values.contains(where: { $0.repositoryIDs.contains(resource.repositoryID!) }) else { throw MonoDeckError("resource-unavailable", .repositoryMembersMustBeRemovedFirst) }
            } else if resource.kind == .group {
                guard record.groups[resource.groupName!]?.repositoryIDs.isEmpty == true else { throw MonoDeckError("resource-unavailable", .groupStillHasMembers) }
            }
            try checkCancellation()
            // Accept cancellation requests while non-cancellable commands finish this resource.
            progress(.init(resource.path, .deleting, cancellable: false))
            if resource.kind == .repository {
                if PathSafety.exists(path) { let trash = try trashDirectory(path); item.trashPath = trash.path; item.effects.append(.init("move-to-trash", path.path)) }
                var candidate = record; candidate.repositories.removeAll { $0.id == resource.repositoryID }
                try persist(candidate, into: &record)
                item.effects.append(.init("remove-record-entry", resource.path))
            } else {
                let repository = resource.repositoryID.map { record.repositoryURL($0) } ?? record.rootURL
                if target.gitRegistered || target.exists {
                    item.effects.append(.init("remove-worktree", path.path, state: "unknown"))
                    _ = try await git.run(["worktree", "remove", "--force", "--", path.path], at: repository, cancellable: false)
                    item.effects[item.effects.count - 1].state = "applied"
                }
                var candidate = record
                if let repo = resource.repositoryID { candidate.groups[resource.groupName!]!.repositoryIDs.removeAll { $0 == repo } }
                else { candidate.groups.removeValue(forKey: resource.groupName!) }
                try persist(candidate, into: &record)
                item.effects.append(.init("remove-record-entry", resource.path))
                if let branch = target.branch {
                    do {
                        _ = try await git.run(["branch", "-D", "--", branch], at: repository, cancellable: false)
                        item.effects.append(.init("delete-branch", branch))
                    } catch let failure as MonoDeckError {
                        guard case .gitFailed("branch", 1, _) = failure.userMessage else { throw failure }
                        let present = try await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: repository, allowFailure: true, cancellable: false)
                        guard present.status == 1 else { throw failure }
                    }
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

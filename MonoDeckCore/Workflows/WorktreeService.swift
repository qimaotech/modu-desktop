import Foundation

struct WorktreeCreation {
    var resource: Resource
    var repository: URL
    var destination: URL
    var oid: String
    var branch: String
    var reused: Bool
    var upstream: String?
    var reuseWarning: (message: String, userMessage: UserMessage?, data: [String: String])?
}

extension WorkspaceService {
    public func createGroup(_ groupName: String, repositoryIDs: [String], at root: URL, dryRun: Bool = false, progress: ProgressHandler = { _ in }) async -> OperationResult {
        if dryRun { return await previewGroupChange(groupName, repositoryIDs: repositoryIDs, root: root, change: .create) }
        return await changeGroup(groupName, repositoryIDs: repositoryIDs, root: root, change: .create, authorization: nil, progress: progress)
    }
    public func addGroupMembers(_ groupName: String, repositoryIDs: [String], at root: URL, dryRun: Bool = false, progress: ProgressHandler = { _ in }) async -> OperationResult {
        if dryRun { return await previewGroupChange(groupName, repositoryIDs: repositoryIDs, root: root, change: .addMembers) }
        return await changeGroup(groupName, repositoryIDs: repositoryIDs, root: root, change: .addMembers, authorization: nil, progress: progress)
    }
    public func editGroup(_ groupName: String, repositoryIDs: [String], at root: URL, authorization: [DeletionTarget]? = nil, dryRun: Bool = false, progress: ProgressHandler = { _ in }) async -> OperationResult {
        if dryRun { return await previewGroupChange(groupName, repositoryIDs: repositoryIDs, root: root, change: .edit) }
        return await changeGroup(groupName, repositoryIDs: repositoryIDs, root: root, change: .edit, authorization: authorization, progress: progress)
    }
    private func changeGroup(_ groupName: String, repositoryIDs: [String], root: URL, change: GroupChange, authorization: [DeletionTarget]?, progress: ProgressHandler) async -> OperationResult {
        let command = change.command
        let replace = change == .edit
        var result = OperationResult(command: command, workspace: root.path)
        if replace, authorization == nil {
            let preview = await editGroupPreview(groupName, repositoryIDs: repositoryIDs, at: root)
            guard preview.status == .success else { return preview }
        }
        do {
            let lease = try await store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            try await validateMembers(groupName, repositoryIDs: repositoryIDs, record: record)
            try validateGroupChange(change, groupName: groupName, record: record)
            if !replace && repositoryIDs.isEmpty { throw MonoDeckError("invalid-input", .chooseAtLeastOneRepository) }
            let existing = record.groups[groupName]?.repositoryIDs ?? []
            let removals = replace ? existing.filter { !repositoryIDs.contains($0) }.map { Resource.member(groupName: groupName, repositoryID: $0) } : []
            guard removals.isEmpty || authorization != nil else { throw MonoDeckError("confirmation-changed", .deletionTargetsOrCheckedOutBranchesChangedNothing) }
            let deletion = try await deletionTargets(removals, record: record, readRisks: false)
            if let authorization { try verifyAuthorization(authorization, actual: deletion) }
            let additions = repositoryIDs.filter { !existing.contains($0) }
            if !replace {
                for repo in repositoryIDs where existing.contains(repo) { _ = try await checked(.member(groupName: groupName, repositoryID: repo), in: record) }
            }
            let plans = try await creationPlans(groupName, members: additions, record: record)
            var completedMembers = 0
            let totalMembers = plans.filter { $0.resource.kind == .member }.count
            for (index, plan) in plans.enumerated() {
                let item = await create(plan, record: &record, progress: progress, completed: completedMembers, total: totalMembers)
                if item.status == .success && plan.resource.kind == .member { completedMembers += 1 }
                result.items.append(item)
                if item.status != .success {
                    result.items += (plans.dropFirst(index + 1).map(\.resource) + deletion.map(\.resource)).map(ItemResult.notProcessed)
                    result.summarize(cancelled: item.status == .cancelled); return result
                }
            }
            for (index, target) in deletion.enumerated() {
                let item = await delete(target, record: &record, progress: progress)
                result.items.append(item)
                if item.status != .success {
                    result.items += deletion.dropFirst(index + 1).map { .notProcessed($0.resource) }
                    result.summarize(cancelled: item.status == .cancelled); return result
                }
            }
            if result.items.isEmpty {
                result.items = change == .addMembers ? repositoryIDs.map { ItemResult(.member(groupName: groupName, repositoryID: $0)) } : [ItemResult(.group(groupName))]
            }
            result.summarize()
        } catch { result = .init(command: command, workspace: root.path, status: .failed, error: .wrap(error)) }
        return result
    }

    private func previewGroupChange(_ groupName: String, repositoryIDs: [String], root: URL, change: GroupChange) async -> OperationResult {
        var result = OperationResult(command: change.command, workspace: root.path)
        result.dryRun = true
        do {
            let record = try await read(root)
            let reader = inspectionService()
            try validateGroupChange(change, groupName: groupName, record: record)
            try await reader.validateMembers(groupName, repositoryIDs: repositoryIDs, record: record)
            guard change == .edit || !repositoryIDs.isEmpty else { throw MonoDeckError("invalid-input", .chooseAtLeastOneRepository) }
            let existing = record.groups[groupName]?.repositoryIDs ?? []
            for repositoryID in repositoryIDs where existing.contains(repositoryID) { _ = try await reader.checked(.member(groupName: groupName, repositoryID: repositoryID), in: record) }
            let creations = try await reader.creationPlans(groupName, members: repositoryIDs.filter { !existing.contains($0) }, record: record)
            let removals = change == .edit ? existing.filter { !repositoryIDs.contains($0) }.map { Resource.member(groupName: groupName, repositoryID: $0) } : []
            let targets = try await reader.deletionTargets(removals, record: record)
            var plan = deletionPlan(targets)
            plan.actions = creations.flatMap { creation -> [PlannedAction] in
                var actions = [PlannedAction("create-worktree", resource: creation.resource, target: creation.destination.path)]
                if !creation.reused { actions.insert(.init("create-branch", resource: creation.resource, target: creation.branch), at: 0) }
                actions.append(.init("save-workspace-record", resource: creation.resource, target: creation.resource.path))
                return actions
            } + plan.actions
            result.plan = plan
        } catch { result.status = .failed; let failure = MonoDeckError.wrap(error); result.reasonCode = failure.code; result.message = failure.message; result.userMessage = failure.userMessage; if failure.code == "cancelled" { result.status = .cancelled } }
        return result
    }

    private func validateGroupChange(_ change: GroupChange, groupName: String, record: WorkspaceRecord) throws {
        if change == .create {
            guard record.groups[groupName] == nil else { throw MonoDeckError("group-already-exists", .groupNameConflictsWithExistingGroup) }
        } else {
            guard record.groups[groupName] != nil else { throw MonoDeckError("target-not-configured", .groupIsNotConfigured) }
        }
    }
    func validateMembers(_ groupName: String, repositoryIDs: [String], record: WorkspaceRecord) async throws {
        try await git.validateRef(groupName, at: record.rootURL)
        guard Set(repositoryIDs).count == repositoryIDs.count, repositoryIDs.allSatisfy({ repositoryID in record.repositories.contains { $0.id == repositoryID } }) else { throw MonoDeckError("invalid-input", .groupMembersMustReferenceDistinctConfiguredRepositories) }
        guard !record.groups.keys.contains(where: { $0 != groupName && PathSafety.identity(record.groupURL($0)) == PathSafety.identity(record.groupURL(groupName)) }) else { throw MonoDeckError("group-conflict", .groupNameConflictsWithExistingGroup) }
    }
    func creationPlans(_ groupName: String, members: [String], record: WorkspaceRecord) async throws -> [WorktreeCreation] {
        var plans: [WorktreeCreation] = []
        if record.groups[groupName] == nil {
            try await git.checkRepository(record.rootURL, main: true)
            guard let head = try await git.oid("HEAD", at: record.rootURL) else { throw MonoDeckError("workspace-commit-required", .commitWorkspaceGitignoreBeforeCreatingGroupWorkspaceHas) }
            let plan = try await creationPlan(.group(groupName), repository: record.rootURL, defaultOID: head, record: record)
            try await git.checkRootCommit(plan.oid, members: members, at: record.rootURL)
            plans.append(plan)
        } else if !members.isEmpty {
            let root = try await checked(.group(groupName), in: record)
            guard let oid = try await git.oid("HEAD", at: root) else { throw MonoDeckError("resource-unavailable", .groupRootHEADIsUnavailable) }
            try await git.checkRootCommit(oid, members: members, at: record.rootURL)
        }
        for member in members {
            let repository = try await checked(.repository(member), in: record)
            let plan = try await creationPlan(.member(groupName: groupName, repositoryID: member), repository: repository, defaultOID: nil, record: record)
            let tree = try await git.run(["ls-tree", "-r", "-z", plan.oid], at: repository)
            guard !tree.stdout.split(separator: 0).contains(where: { $0.starts(with: Data("160000 ".utf8)) }) else { throw MonoDeckError("submodule-unsupported", .linkedWorktreesForRepositoriesContainingSubmodulesAreNot(member)) }
            plans.append(plan)
        }
        return plans
    }
    func creationPlan(_ resource: Resource, repository: URL, defaultOID: String?, record: WorkspaceRecord) async throws -> WorktreeCreation {
        let groupName = resource.groupName!
        let destination = try PathSafety.child(resource.path, of: record.rootURL)
        guard !PathSafety.exists(destination) else { throw MonoDeckError("path-conflict", .worktreePathAlreadyExists(destination.path)) }
        let registrations = try await git.registrations(at: repository)
        guard !registrations.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(destination) }) else { throw MonoDeckError("path-conflict", .worktreePathIsAlreadyRegistered) }
        try await git.checkBranchNotInUse(groupName, registrations: registrations, at: repository)
        let local = try await git.oid("refs/heads/\(groupName)", at: repository)
        var upstream: String?
        var start = local ?? defaultOID
        if start == nil {
            if let remote = try await git.oid("refs/remotes/origin/\(groupName)", at: repository) { start = remote; upstream = "origin/\(groupName)" }
            else {
                let base = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: repository, allowFailure: true)
                if base.status == 0, base.text.hasPrefix("refs/remotes/origin/") { start = try await git.oid(base.text, at: repository) }
            }
        }
        guard let start else { throw MonoDeckError("base-unavailable", .noLocalStartingCommitUpdateMainRepositoryFirst(resource.repositoryID ?? groupName)) }
        let warning: (message: String, userMessage: UserMessage?, data: [String: String])?
        if let local { warning = try await branchReuseWarning(groupName, oid: local, defaultOID: defaultOID, at: repository) }
        else { warning = nil }
        return .init(resource: resource, repository: repository, destination: destination, oid: start, branch: groupName, reused: local != nil, upstream: upstream, reuseWarning: warning)
    }
    func create(_ plan: WorktreeCreation, record: inout WorkspaceRecord, createdAt: String? = nil, progress: ProgressHandler, completed: Int = 0, total: Int = 0) async -> ItemResult {
        var item = ItemResult(plan.resource)
        var started = false
        var branchCreationAttempted = false
        do {
            try checkCancellation()
            progress(.init(plan.resource.path, plan.resource.kind == .group ? .creatingGroupRootWorktree : .creating, completed: completed, total: total))
            if !plan.reused {
                // A cancelled update-ref may have committed its reference before its hook exits.
                branchCreationAttempted = true
                _ = try await git.run(["update-ref", "refs/heads/\(plan.branch)", plan.oid, String(repeating: "0", count: plan.oid.count)], at: plan.repository)
            }
            started = true
            // Full refs are detached by worktree add; attach HEAD explicitly to avoid checkout shorthand.
            _ = try await git.run(["worktree", "add", "--detach", "--", plan.destination.path, plan.oid], at: plan.repository)
            _ = try await git.run(["symbolic-ref", "HEAD", "refs/heads/\(plan.branch)"], at: plan.destination)
            if let upstream = plan.upstream {
                _ = try await git.run(["config", "branch.\(plan.branch).remote", "origin"], at: plan.repository)
                _ = try await git.run(["config", "branch.\(plan.branch).merge", "refs/heads/\(upstream.dropFirst(7))"], at: plan.repository)
            }
            try checkCancellation()
            progress(.init(plan.resource.path, .saving, completed: completed, total: total, cancellable: false))
            var candidate = record
            let group = plan.resource.groupName!
            if let repo = plan.resource.repositoryID { candidate.groups[group]!.repositoryIDs.append(repo) }
            else { candidate.groups[group] = WorktreeGroup(createdAt: createdAt ?? ISO8601DateFormatter().string(from: Date())) }
            try persist(candidate, into: &record)
            item.effects = [.init("create-worktree", plan.destination.path), .init("save-workspace-record", plan.resource.path)]
            if !plan.reused { item.effects.append(.init("create-branch", plan.branch)) }
            item.data = plan.reuseWarning?.data; item.message = plan.reuseWarning?.message; item.userMessage = plan.reuseWarning?.userMessage
            progress(.init(plan.resource.path, .created, completed: completed + (plan.resource.kind == .member ? 1 : 0), total: total, snapshot: record))
        } catch {
            fail(&item, error)
            if started || branchCreationAttempted {
                if item.reasonCode == "save-outcome-unknown" {
                    item.effects.append(.init("create-worktree", plan.destination.path, state: "unknown"))
                    if branchCreationAttempted { item.effects.append(.init("create-branch", plan.branch, state: "unknown")) }
                }
                else {
                    progress(.init(plan.resource.path, .cleaningUp, cancellable: false))
                    var worktreePending = started
                    var branchPending = branchCreationAttempted
                    do {
                        if started {
                            let registrations = try await git.run(["worktree", "list", "--porcelain", "-z"], at: plan.repository, cancellable: false)
                            let registered = registrations.stdout.split(separator: 0).contains { String(decoding: $0, as: UTF8.self) == "worktree \(plan.destination.path)" }
                            if registered || PathSafety.exists(plan.destination) {
                                _ = try await git.run(["worktree", "remove", "--force", "--", plan.destination.path], at: plan.repository, cancellable: false)
                                item.effects.append(.init("create-worktree", plan.destination.path, state: "reverted"))
                            }
                            worktreePending = false
                        }
                        if branchCreationAttempted {
                            if try await removeCreatedBranch(plan) { item.effects.append(.init("create-branch", plan.branch, state: "reverted")) }
                            branchPending = false
                        }
                    } catch {
                        item.causeCode = item.reasonCode; item.reasonCode = "cleanup-failed"; item.status = .failed
                        item.userMessage = .joined([item.userMessage, .cleanupFailed(MonoDeckError.wrap(error).userMessage)].compactMap { $0 }, separator: " "); item.message = "\(item.message ?? "") Cleanup failed: \(error.localizedDescription)"
                        if worktreePending { item.effects.append(.init("create-worktree", plan.destination.path, state: "unknown")) }
                        if branchPending { item.effects.append(.init("create-branch", plan.branch, state: "unknown")) }
                    }
                }
            }
        }
        return item
    }

    private func removeCreatedBranch(_ plan: WorktreeCreation) async throws -> Bool {
        let ref = "refs/heads/\(plan.branch)"
        let exists = try await git.run(["show-ref", "--verify", "--quiet", ref], at: plan.repository, allowFailure: true, cancellable: false)
        if exists.status == 1 { return false }
        guard exists.status == 0 else { throw MonoDeckError("git-failed", .couldNotVerifyNewBranch(plan.branch)) }
        let actual = try await git.run(["rev-parse", "--verify", "--end-of-options", ref], at: plan.repository, cancellable: false)
        guard actual.text == plan.oid else { throw MonoDeckError("branch-changed", .newBranchChangedDuringCreationAndWasKept(plan.branch)) }
        _ = try await git.run(["branch", "-D", "--", plan.branch], at: plan.repository, cancellable: false)
        return true
    }

    private func branchReuseWarning(_ branch: String, oid: String, defaultOID: String?, at repository: URL) async throws -> (message: String, userMessage: UserMessage?, data: [String: String])? {
        var data = ["reused-branch": branch, "comparison-base": defaultOID == nil ? "origin/HEAD" : "HEAD"]
        var base = defaultOID == nil ? "origin/HEAD" : "workspace HEAD"
        do {
            let baseOID: String
            if let defaultOID { baseOID = defaultOID }
            else {
                let ref = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: repository, allowFailure: true)
                guard ref.status == 0, ref.text.hasPrefix("refs/remotes/origin/"), let oid = try await git.oid(ref.text, at: repository) else {
                    throw MonoDeckError("base-unavailable", .originHEADDoesNotIdentifyValidComparisonCommit)
                }
                baseOID = oid; base = String(ref.text.dropFirst("refs/remotes/".count)); data["comparison-base"] = base
            }
            let count = try await git.run(["rev-list", "--count", "\(oid)..\(baseOID)", "--"], at: repository).text
            guard let behind = Int(count), behind >= 0 else { throw MonoDeckError("git-output-invalid", .couldNotReadBranchComparisonCount) }
            guard behind > 0 else { return nil }
            data["warning-code"] = "branch-behind-base"; data["behind-count"] = String(behind)
            return ("Reused branch '\(branch)' is \(behind) \(behind == 1 ? "commit" : "commits") behind '\(base)'. Its commits were kept.", .branchReuseBehind(branch, behind, base, isWorkspace: defaultOID != nil), data)
        } catch let error as MonoDeckError where error.code == "cancelled" { throw error }
        catch {
            try checkCancellation()
            data["warning-code"] = "branch-comparison-unavailable"; data["comparison-error"] = MonoDeckError.wrap(error).message
            return ("Reused branch '\(branch)', but its comparison with '\(base)' is unavailable. \(MonoDeckError.wrap(error).message)", .branchReuseComparisonUnavailable(branch, base, MonoDeckError.wrap(error).userMessage, isWorkspace: defaultOID != nil), data)
        }
    }
}

extension WorkspaceService {
    public func editGroupPreview(_ groupName: String, repositoryIDs: [String], at root: URL) async -> OperationResult {
        do {
            let record = try await read(root)
            let reader = inspectionService()
            try await reader.validateMembers(groupName, repositoryIDs: repositoryIDs, record: record)
            guard let group = record.groups[groupName] else { throw MonoDeckError("target-not-configured", .groupIsNotConfigured) }
            let removals = group.repositoryIDs.filter { !repositoryIDs.contains($0) }.map { Resource.member(groupName: groupName, repositoryID: $0) }
            let targets = try await reader.deletionTargets(removals, record: record)
            var result = OperationResult(command: "group.edit", workspace: root.path, status: targets.isEmpty ? .success : .confirmationRequired)
            result.plan = deletionPlan(targets); return result
        } catch { return .init(command: "group.edit", workspace: root.path, status: .failed, error: .wrap(error)) }
    }
}

private enum GroupChange {
    case create, edit, addMembers
    var command: String {
        switch self { case .create: "group.create"; case .edit: "group.edit"; case .addMembers: "group.member.add" }
    }
}

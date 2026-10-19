import Foundation

struct WorktreeCreation {
    var resource: Resource
    var repository: URL
    var destination: URL
    var oid: String
    var branch: String
    var reused: Bool
    var upstream: String?
    var reuseWarning: (message: String, data: [String: String])?
}

extension WorkspaceService {
    public func createGroup(_ name: String, repositories: [String], at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        await changeGroup(name, repositories: repositories, root: root, replace: false, authorization: nil, progress: progress)
    }
    public func editGroup(_ name: String, repositories: [String], at root: URL, authorization: [DeletionTarget]? = nil, progress: ProgressHandler = { _ in }) async -> OperationResult {
        await changeGroup(name, repositories: repositories, root: root, replace: true, authorization: authorization, progress: progress)
    }
    private func changeGroup(_ name: String, repositories: [String], root: URL, replace: Bool, authorization: [DeletionTarget]?, progress: ProgressHandler) async -> OperationResult {
        let command = replace ? "worktree.update" : "worktree.create"
        var result = OperationResult(command: command, workspace: root.path)
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            try await validateMembers(name, repositories: repositories, record: record)
            if replace && record.groups[name] == nil { throw ModuError("target-not-configured", "Group is not configured.") }
            if !replace && repositories.isEmpty { throw ModuError("invalid-input", "Choose at least one repository.") }
            let existing = record.groups[name]?.repositories ?? []
            let removals = replace ? existing.filter { !repositories.contains($0) }.map { Resource.member(name, $0) } : []
            let deletion = try await deletionTargets(removals, record: record, readRisks: authorization == nil)
            if !deletion.isEmpty {
                guard let authorization else { result.status = .confirmationRequired; result.reasonCode = "confirmation-required"; result.plan = deletion; return result }
                try verifyAuthorization(authorization, actual: deletion)
            }
            let additions = repositories.filter { !existing.contains($0) }
            if !replace {
                for repo in repositories where existing.contains(repo) { _ = try await checked(.member(name, repo), in: record) }
            }
            let plans = try await creationPlans(name, members: additions, record: record)
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
            if result.items.isEmpty { result.items = [ItemResult(.group(name))] }
            result.summarize()
        } catch { result = .init(command: command, workspace: root.path, status: .failed, error: .wrap(error)) }
        return result
    }
    func validateMembers(_ name: String, repositories: [String], record: WorkspaceRecord) async throws {
        try await git.validateRef(name, at: record.rootURL)
        guard Set(repositories).count == repositories.count, repositories.allSatisfy({ name in record.repositories.contains { $0.id == name } }) else { throw ModuError("invalid-input", "Group members must reference distinct configured repositories.") }
        guard !record.groups.keys.contains(where: { $0 != name && PathSafety.identity(record.groupURL($0)) == PathSafety.identity(record.groupURL(name)) }) else { throw ModuError("group-conflict", "Group name conflicts with an existing group.") }
    }
    func creationPlans(_ name: String, members: [String], record: WorkspaceRecord) async throws -> [WorktreeCreation] {
        var plans: [WorktreeCreation] = []
        if record.groups[name] == nil {
            try await git.checkRepository(record.rootURL, main: true)
            guard let head = try await git.oid("HEAD", at: record.rootURL) else { throw ModuError("workspace-commit-required", "Commit the workspace .gitignore before creating this group. The workspace has no first commit.") }
            let plan = try await creationPlan(.group(name), repository: record.rootURL, defaultOID: head, record: record)
            try await git.checkRootCommit(plan.oid, members: members, at: record.rootURL)
            plans.append(plan)
        } else if !members.isEmpty {
            let root = try await checked(.group(name), in: record)
            guard let oid = try await git.oid("HEAD", at: root) else { throw ModuError("resource-unavailable", "Group root HEAD is unavailable.") }
            try await git.checkRootCommit(oid, members: members, at: record.rootURL)
        }
        for member in members {
            let repository = try await checked(.repository(member), in: record)
            let plan = try await creationPlan(.member(name, member), repository: repository, defaultOID: nil, record: record)
            let tree = try await git.run(["ls-tree", "-r", "-z", plan.oid], at: repository)
            guard !tree.stdout.split(separator: 0).contains(where: { $0.starts(with: Data("160000 ".utf8)) }) else { throw ModuError("submodule-unsupported", "Linked worktrees for repositories containing submodules are not supported: \(member)") }
            plans.append(plan)
        }
        return plans
    }
    func creationPlan(_ resource: Resource, repository: URL, defaultOID: String?, record: WorkspaceRecord) async throws -> WorktreeCreation {
        let name = resource.group!
        let destination = try PathSafety.child(resource.path, of: record.rootURL)
        guard !PathSafety.exists(destination) else { throw ModuError("path-conflict", "Worktree path already exists: \(destination.path)") }
        let registrations = try await git.registrations(at: repository)
        guard !registrations.contains(where: { PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(destination) }) else { throw ModuError("path-conflict", "Worktree path is already registered.") }
        try await git.checkBranchNotInUse(name, registrations: registrations, at: repository)
        let local = try await git.oid("refs/heads/\(name)", at: repository)
        var upstream: String?
        var start = local ?? defaultOID
        if start == nil {
            if let remote = try await git.oid("refs/remotes/origin/\(name)", at: repository) { start = remote; upstream = "origin/\(name)" }
            else {
                let base = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: repository, allowFailure: true)
                if base.status == 0, base.text.hasPrefix("refs/remotes/origin/") { start = try await git.oid(base.text, at: repository) }
            }
        }
        guard let start else { throw ModuError("base-unavailable", "No local starting commit. Update the main repository first: \(resource.repo ?? name)") }
        let warning: (message: String, data: [String: String])?
        if let local { warning = try await branchReuseWarning(name, oid: local, defaultOID: defaultOID, at: repository) }
        else { warning = nil }
        return .init(resource: resource, repository: repository, destination: destination, oid: start, branch: name, reused: local != nil, upstream: upstream, reuseWarning: warning)
    }
    func create(_ plan: WorktreeCreation, record: inout WorkspaceRecord, createdAt: String? = nil, progress: ProgressHandler, completed: Int = 0, total: Int = 0) async -> ItemResult {
        var item = ItemResult(plan.resource)
        var started = false
        var branchCreationAttempted = false
        do {
            try checkCancellation()
            progress(.init(plan.resource.path, plan.resource.kind == .group ? .creatingWorkspaceWorktree : .creating, completed: completed, total: total))
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
            let group = plan.resource.group!
            if let repo = plan.resource.repo { candidate.groups[group]!.repositories.append(repo) }
            else { candidate.groups[group] = WorktreeGroup(createdAt: createdAt ?? ISO8601DateFormatter().string(from: Date())) }
            try persist(candidate, into: &record)
            item.effects = [.init("create-worktree", plan.destination.path), .init("save-configuration", plan.resource.path)]
            if !plan.reused { item.effects.append(.init("create-branch", plan.branch)) }
            item.data = plan.reuseWarning?.data; item.message = plan.reuseWarning?.message
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
                        item.message = "\(item.message ?? "") Cleanup failed: \(error.localizedDescription)"
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
        guard exists.status == 0 else { throw ModuError("git-failed", "Could not verify the new branch: \(plan.branch)") }
        let actual = try await git.run(["rev-parse", "--verify", "--end-of-options", ref], at: plan.repository, cancellable: false)
        guard actual.text == plan.oid else { throw ModuError("branch-changed", "The new branch changed during creation and was kept: \(plan.branch)") }
        _ = try await git.run(["branch", "-D", "--", plan.branch], at: plan.repository, cancellable: false)
        return true
    }

    private func branchReuseWarning(_ branch: String, oid: String, defaultOID: String?, at repository: URL) async throws -> (message: String, data: [String: String])? {
        var data = ["reused-branch": branch, "comparison-base": defaultOID == nil ? "origin/HEAD" : "HEAD"]
        var base = defaultOID == nil ? "origin/HEAD" : "workspace HEAD"
        do {
            let baseOID: String
            if let defaultOID { baseOID = defaultOID }
            else {
                let ref = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: repository, allowFailure: true)
                guard ref.status == 0, ref.text.hasPrefix("refs/remotes/origin/"), let oid = try await git.oid(ref.text, at: repository) else {
                    throw ModuError("base-unavailable", "origin/HEAD does not identify a valid comparison commit.")
                }
                baseOID = oid; base = String(ref.text.dropFirst("refs/remotes/".count)); data["comparison-base"] = base
            }
            let count = try await git.run(["rev-list", "--count", "\(oid)..\(baseOID)", "--"], at: repository).text
            guard let behind = Int(count), behind >= 0 else { throw ModuError("git-output-invalid", "Could not read the branch comparison count.") }
            guard behind > 0 else { return nil }
            data["warning-code"] = "branch-behind-base"; data["behind-count"] = String(behind)
            return ("Reused branch '\(branch)' is \(behind) \(behind == 1 ? "commit" : "commits") behind '\(base)'. Its commits were kept.", data)
        } catch let error as ModuError where error.code == "cancelled" { throw error }
        catch {
            try checkCancellation()
            data["warning-code"] = "branch-comparison-unavailable"; data["comparison-error"] = ModuError.wrap(error).message
            return ("Reused branch '\(branch)', but its comparison with '\(base)' is unavailable. \(ModuError.wrap(error).message)", data)
        }
    }
}

extension WorkspaceService {
    public func editGroupPreview(_ name: String, repositories: [String], at root: URL) async -> OperationResult {
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            let record = try store.load(root)
            try await validateMembers(name, repositories: repositories, record: record)
            guard let group = record.groups[name] else { throw ModuError("target-not-configured", "Group is not configured.") }
            let removals = group.repositories.filter { !repositories.contains($0) }.map { Resource.member(name, $0) }
            let targets = try await deletionTargets(removals, record: record)
            var result = OperationResult(command: "worktree.update", workspace: root.path, status: targets.isEmpty ? .success : .confirmationRequired)
            result.plan = targets; return result
        } catch { return .init(command: "worktree.update", workspace: root.path, status: .failed, error: .wrap(error)) }
    }
}

import Foundation

extension WorkspaceService {
    public func addRepository(_ repository: Repository, at root: URL, dryRun: Bool = false, progress: ProgressHandler = { _ in }) async -> OperationResult {
        if dryRun { return await previewRepositoryAddition(repository, at: root) }
        var result = OperationResult(command: "repo.add", workspace: root.path)
        var staging: RepositoryStaging?
        do {
            _ = try RepositoryIdentity(repository.url)
            result.items = [try await add(repository, at: root, staging: &staging, progress: progress)]
        } catch { result = .init(command: result.command, workspace: root.path, status: .failed, error: .wrap(error)) }
        finishRepositoryStaging(staging, items: &result.items)
        if !result.items.isEmpty { result.summarize(cancelled: result.items.contains { $0.status == .cancelled }) }
        return result
    }

    private func previewRepositoryAddition(_ repository: Repository, at root: URL) async -> OperationResult {
        var result = OperationResult(command: "repo.add", workspace: root.path)
        result.dryRun = true
        do {
            _ = try RepositoryIdentity(repository.url)
            let record = try await read(root)
            try await checkRepositoryWorkspace(root)
            let resource = Resource.repository(repository.id)
            if let existing = record.repositories.first(where: { $0.id.lowercased() == repository.id.lowercased() }) {
                guard existing.url == repository.url, repository.displayNameOverride == nil || existing.displayNameOverride == repository.displayNameOverride else { throw MonoDeckError("repository-conflict", .repositoryIDIsAlreadyRegistered(repository.id)) }
                _ = try await checked(.repository(existing.id), in: record)
                result.plan = .init()
            } else {
                let target = try PathSafety.child(resource.path, of: root)
                guard !PathSafety.exists(target) else { throw MonoDeckError("path-conflict", .repositoryTargetAlreadyExists(target.path)) }
                result.plan = .init(actions: [.init("clone", resource: resource, target: repository.url), .init("save-workspace-record", resource: resource, target: target.path)])
            }
            result.plan?.actions.append(.init("maintain-workspace-ignore", resource: .workspace(), target: root.appending(path: ".gitignore").path))
        } catch { result = .init(command: result.command, workspace: root.path, status: .failed, error: .wrap(error)); result.dryRun = true }
        return result
    }

    func add(_ repository: Repository, at root: URL, staging: inout RepositoryStaging?, progress: ProgressHandler) async throws -> ItemResult {
        let start = try await beginRepositoryAddition(repository, at: root, staging: &staging, progress: progress)
        let container: RepositoryStaging
        switch start {
        case .finished(let item): return item
        case .prepare(let staging): container = staging
        }
        let preparation = await prepareRepository(repository, in: container, progress: progress)
        switch preparation {
        case .failed(let item): return item
        case .ready(let prepared):
            var item: ItemResult
            do {
                let lease = try await store.lock(root); defer { lease.unlock() }
                var record = try store.load(root)
                item = await publishRepository(prepared, record: &record, progress: progress)
            } catch {
                item = ItemResult(.repository(repository.id)); fail(&item, error)
            }
            cleanupRepositoryPreparation(prepared, item: &item, reportEffects: item.status != .success, progress: progress)
            return item
        }
    }

    private func beginRepositoryAddition(_ repository: Repository, at root: URL, staging: inout RepositoryStaging?, progress: ProgressHandler) async throws -> RepositoryAdditionStart {
        let lease = try await store.lock(root); defer { lease.unlock() }
        let record = try store.load(root)
        var item = ItemResult(.repository(repository.id))
        do {
            try checkCancellation()
            progress(.init(repository.id, .checkingRepository))
            try await checkRepositoryWorkspace(root)
            if let existing = await existingRepository(repository, in: record, commitIgnore: true, progress: progress) { return .finished(existing) }
            let target = try PathSafety.child("repositories/\(repository.id)", of: root)
            guard !PathSafety.exists(target) else { throw MonoDeckError("path-conflict", .repositoryTargetAlreadyExists(target.path)) }
            let container: RepositoryStaging
            if let existing = staging { container = existing }
            else { container = try RepositoryStaging(at: root); staging = container }
            try container.validate()
            return .prepare(container)
        } catch { fail(&item, error); return .finished(item) }
    }

    func prepareRepository(_ repository: Repository, in staging: RepositoryStaging, reportCleanupEffects: Bool = true, progress: ProgressHandler) async -> RepositoryPreparation {
        var item = ItemResult(.repository(repository.id))
        var directory: RepositoryDirectory?
        do {
            try checkCancellation()
            try staging.validate()
            let branch = try await remoteDefault(repository.url, at: staging.workspace.url)
            let clone = try staging.makeDirectory(repository.id)
            directory = clone
            progress(.init(repository.id, .cloning))
            _ = try await git.run(["clone", "--no-recurse-submodules", "--no-checkout", "--origin", "origin", "--", repository.url, clone.url.path], at: staging.workspace.url, timeout: 1800)
            try staging.validate(); try clone.validate()
            guard try await git.oid("refs/remotes/origin/\(branch)", at: clone.url) != nil else { throw MonoDeckError("remote-head-unavailable", .remoteDefaultBranchDoesNotIdentifyCommit) }
            _ = try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/\(branch)"], at: clone.url)
            _ = try await git.run(["checkout", "-B", branch, "refs/remotes/origin/\(branch)"], at: clone.url)
            _ = try await git.run(["branch", "--set-upstream-to=origin/\(branch)", "--", branch], at: clone.url)
            try checkCancellation()
            try staging.validate(); try clone.validate()
            return .ready(.init(repository: repository, staging: staging, directory: clone))
        } catch {
            fail(&item, error)
            if let directory {
                cleanupRepositoryPreparation(.init(repository: repository, staging: staging, directory: directory), item: &item, reportEffects: reportCleanupEffects, progress: progress)
            }
            return .failed(item)
        }
    }

    func publishRepository(_ prepared: PreparedRepository, record: inout WorkspaceRecord, commitIgnore: Bool = true, progress: ProgressHandler) async -> ItemResult {
        let repository = prepared.repository
        let repositoryID = repository.id
        var item = ItemResult(.repository(repositoryID))
        var published: RepositoryDirectory?
        do {
            try checkCancellation()
            try prepared.staging.validate(); try prepared.directory.validate()
            try await checkRepositoryWorkspace(record.rootURL)
            if let existing = await existingRepository(repository, in: record, commitIgnore: commitIgnore, progress: progress) { return existing }
            let target = try PathSafety.child("repositories/\(repositoryID)", of: record.rootURL)
            guard !PathSafety.exists(target) else { throw MonoDeckError("path-conflict", .repositoryTargetIsOccupied) }
            try await git.checkRepository(prepared.directory.url, origin: repository.url, main: true)
            try checkCancellation()
            try prepared.staging.validate(); try prepared.directory.validate()
            progress(.init(repositoryID, .saving, cancellable: false))
            try FileManager.default.moveItem(at: prepared.directory.url, to: target)
            published = prepared.directory.relocated(to: target)
            var candidate = record; candidate.repositories.append(repository)
            try persist(candidate, into: &record)
            published = nil
            item.effects.append(.init("clone", target.path)); item.effects.append(.init("save-workspace-record", repositoryID))
            item.data = ["disposition": "added"]
            try await finishRepositoryIgnore(repositoryID, at: record.rootURL, commit: commitIgnore, item: &item)
            progress(.init(repositoryID, .added, snapshot: record))
        } catch {
            fail(&item, error)
            if let published, PathSafety.exists(published.url) {
                if item.reasonCode == "save-outcome-unknown" { item.effects.append(.init("clone", published.url.path, state: "unknown")) }
                else {
                    progress(.init(item.resource.path, .cleaningUp, cancellable: false))
                    do {
                        try published.validate()
                        item.trashPath = try trashDirectory(published.url).path
                        item.effects.append(.init("clone", published.url.path, state: "reverted"))
                    } catch { repositoryCleanupFailed(&item, error: error, path: published.url) }
                }
            }
        }
        return item
    }

    func cleanupRepositoryPreparation(_ prepared: PreparedRepository, item: inout ItemResult, reportEffects: Bool, causeCode: String? = nil, progress: ProgressHandler) {
        var cleanupPath = prepared.staging.directory.url
        do {
            try prepared.staging.validate()
            guard PathSafety.exists(prepared.directory.url) else { return }
            cleanupPath = prepared.directory.url
            try prepared.directory.validate()
            progress(.init(item.resource.path, .cleaningUp, cancellable: false))
            let trash = try trashDirectory(prepared.directory.url)
            if reportEffects { item.trashPath = trash.path; item.effects.append(.init("clone", prepared.directory.url.path, state: "reverted")) }
        } catch { repositoryCleanupFailed(&item, error: error, path: cleanupPath, causeCode: causeCode) }
    }

    func finishRepositoryStaging(_ staging: RepositoryStaging?, items: inout [ItemResult], causeCode: String? = nil) {
        guard let staging, !items.contains(where: { $0.reasonCode == "cleanup-failed" }) else { return }
        do { try staging.removeEmptyContainer() }
        catch {
            if items.isEmpty { items.append(.init(.workspace())) }
            repositoryCleanupFailed(&items[items.count - 1], error: error, path: staging.directory.url, causeCode: causeCode)
        }
    }

    private func existingRepository(_ repository: Repository, in record: WorkspaceRecord, commitIgnore: Bool, progress: ProgressHandler) async -> ItemResult? {
        let repositoryID = repository.id
        guard let existing = record.repositories.first(where: { $0.id.lowercased() == repositoryID.lowercased() }) else { return nil }
        var item = ItemResult(.repository(repositoryID))
        do {
            guard existing.url == repository.url, repository.displayNameOverride == nil || existing.displayNameOverride == repository.displayNameOverride else { throw MonoDeckError("repository-conflict", .repositoryIDIsAlreadyRegistered(repositoryID)) }
            _ = try await checked(.repository(existing.id), in: record)
            item.data = ["disposition": "already-exists"]
            progress(.init(repositoryID, .saving, cancellable: false))
            try await finishRepositoryIgnore(repositoryID, at: record.rootURL, commit: commitIgnore, item: &item)
        } catch { fail(&item, error) }
        return item
    }

    private func checkRepositoryWorkspace(_ root: URL) async throws {
        do { try await git.checkRepository(root, main: true) }
        catch let error as MonoDeckError where error.code == "cancelled" { throw error }
        catch { throw MonoDeckError("workspace-unavailable", .workspaceRepositoryIsUnavailable(MonoDeckError.wrap(error).userMessage)) }
    }

    private func repositoryCleanupFailed(_ item: inout ItemResult, error: Error, path: URL, causeCode: String? = nil) {
        if item.reasonCode != "cleanup-failed" { item.causeCode = causeCode ?? item.reasonCode }
        item.reasonCode = "cleanup-failed"; item.status = .failed
        item.userMessage = .joined([item.userMessage, .cleanupFailed(MonoDeckError.wrap(error).userMessage)].compactMap { $0 }, separator: " ")
        item.message = "\(item.message ?? "") Cleanup failed: \(error.localizedDescription)"
        item.effects.append(.init("clone", path.path, state: "unknown"))
    }

    private func finishRepositoryIgnore(_ repositoryID: String, at root: URL, commit: Bool, item: inout ItemResult) async throws {
        if try await git.ensureIgnore([repositoryID], at: root, cancellable: false) { item.effects.append(.init("update-ignore", root.appending(path: ".gitignore").path)) }
        if commit, let oid = try await git.commitWorkspaceFiles([".gitignore"], message: "chore: ignore MonoDeck repository \(repositoryID)", at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
    }
    func remoteDefault(_ url: String, at root: URL) async throws -> String {
        try await checkRemoteBoundary(url, at: root)
        let output = try await git.run(["ls-remote", "--symref", "--", url, "HEAD"], at: root)
        guard let line = output.text.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") && $0.hasSuffix("\tHEAD") }) else { throw MonoDeckError("remote-head-unavailable", .remoteHasNoValidDefaultBranch) }
        let branch = String(line.dropFirst(16).dropLast(5))
        guard try await git.run(["check-ref-format", "refs/heads/\(branch)"], at: root, allowFailure: true).status == 0 else { throw MonoDeckError("remote-head-unavailable", .remoteDefaultBranchIsInvalid) }
        return branch
    }

    func checkRemoteBoundary(_ url: String, at root: URL) async throws {
        guard let boundary = store.directoryBoundary else { return }
        let resolved = try await git.run(["ls-remote", "--get-url", "--", url], at: root).text
        guard let remote = URL(string: resolved), remote.isFileURL else {
            throw MonoDeckError("unsafe-path", .repositoryRemoteMustResolveLocalPathInsideTemporary(boundary.path))
        }
        try PathSafety.confined(remote, to: boundary)
    }

    public func updateRepositories(at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "repo.update", workspace: root.path)
        do {
            let record = try store.load(root)
            result.items = record.repositories.map { .notProcessed(.repository($0.id)) }
            progress(.init("", .updatingRepositories, total: record.repositories.count))
            await withTaskGroup(of: (Int, ItemResult).self) { group in
                var next = 0, completed = 0
                for index in 0..<min(6, record.repositories.count) {
                    guard group.addTaskUnlessCancelled(operation: {
                        (index, await updateRepository(record.repositories[index], in: record))
                    }) else { break }
                    next += 1
                }
                while let (index, item) = await group.next() {
                    result.items[index] = item
                    completed += 1
                    progress(.init(record.repositories[index].displayName, .updatingRepositories,
                                   completed: completed, total: record.repositories.count))
                    if next < record.repositories.count {
                        let index = next
                        if group.addTaskUnlessCancelled(operation: {
                            (index, await updateRepository(record.repositories[index], in: record))
                        }) { next += 1 }
                    }
                }
            }
            result.summarize(cancelled: result.items.contains { $0.status == .cancelled || $0.reasonCode == "not-processed" })
        } catch { result = .init(command: result.command, workspace: root.path, status: .failed, error: .wrap(error)) }
        return result
    }

    private func updateRepository(_ repository: Repository, in record: WorkspaceRecord) async -> ItemResult {
        var item = ItemResult(.repository(repository.id))
        do {
            try checkCancellation()
            let path = try PathSafety.child(item.resource.path, of: record.rootURL)
            guard PathSafety.exists(path) else {
                return ItemResult(item.resource, status: .skipped, error: MonoDeckError("resource-missing", .repositoryDirectoryIsMissing))
            }
            try await git.checkRepository(path, origin: repository.url, main: true)
            let directory = try RepositoryDirectory(path)
            let gitDirectory = try RepositoryDirectory(path.appending(path: ".git"))
            let state = try await repositoryUpdateState(at: path)
            guard state.changes.isEmpty else {
                return ItemResult(item.resource, status: .skipped, error: MonoDeckError("working-tree-dirty", .workingTreeHasChanges))
            }
            guard let branch = state.branch else {
                return ItemResult(item.resource, status: .skipped, error: MonoDeckError("detached-head", .detachedHEAD))
            }
            let base = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true)
            guard base.status == 0, base.text.hasPrefix("refs/remotes/origin/"),
                  try await git.oid(base.text, at: path) != nil else {
                throw MonoDeckError("base-unavailable", .baseBranchIsUnavailableFixOriginHEADIn)
            }
            let remoteBranch = "refs/heads/" + base.text.dropFirst("refs/remotes/origin/".count)
            guard branch == remoteBranch else {
                return ItemResult(item.resource, status: .skipped, error: MonoDeckError("not-default-branch", .currentBranchIsNotBaseBranch))
            }
            guard let before = state.headOID else { throw MonoDeckError("resource-unavailable", .headIsUnavailable) }
            let context = RepositoryUpdateContext(directory: directory, gitDirectory: gitDirectory, origin: repository.url,
                                                  branch: branch, base: base.text, head: before)
            try context.validateIdentity()
            try checkCancellation()
            try await checkRemoteBoundary(repository.url, at: path)
            item.effects.append(.init("update-refs", path.path, state: "unknown"))
            _ = try await git.run(["fetch", "--no-recurse-submodules", "origin", "+\(remoteBranch):\(base.text)"], at: path)
            item.effects[item.effects.count - 1].state = "applied"
            try await validateRepositoryUpdate(context)
            item.effects.append(.init("fast-forward", path.path, state: "unknown"))
            _ = try await git.run(["merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", base.text], at: path)
            item.effects[item.effects.count - 1].state = "applied"
            let after = try await git.oid("HEAD", at: path)
            item.data = ["disposition": before == after ? "up-to-date" : "updated"]
        } catch {
            fail(&item, error)
            if !item.effects.isEmpty {
                let path = record.repositoryURL(repository.id)
                let head = try? await git.run(["rev-parse", "--verify", "HEAD"], at: path, allowFailure: true, cancellable: false)
                let status = try? await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: path, allowFailure: true, cancellable: false)
                var actual: [String: String] = [:]
                if head?.status == 0 { actual["actual-head"] = head?.text }
                if status?.status == 0 { actual["working-tree"] = status?.stdout.isEmpty == true ? "clean" : "dirty" }
                if !actual.isEmpty { item.data = actual }
            }
        }
        return item
    }

    private func validateRepositoryUpdate(_ context: RepositoryUpdateContext) async throws {
        try checkCancellation()
        try context.validateIdentity()
        let path = context.directory.url
        let state = try await repositoryUpdateState(at: path)
        guard state.changes.isEmpty else { throw MonoDeckError("repository-changed", .repositoryChangedDuringUpdate) }
        try await git.checkRepository(path, main: true)
        let origin = try await git.run(["config", "--get", "remote.origin.url"], at: path, allowFailure: true)
        let base = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true)
        guard origin.status == 0, origin.text == context.origin,
              state.branch == context.branch,
              base.status == 0, base.text == context.base,
              try await git.oid(context.base, at: path) != nil,
              state.headOID == context.head else {
            throw MonoDeckError("repository-changed", .repositoryChangedDuringUpdate)
        }
        try context.validateIdentity()
        try checkCancellation()
    }

    private func repositoryUpdateState(at path: URL) async throws -> (changes: [FileChange], branch: String?, headOID: String?) {
        let state = try Git.parseWorkingState(await git.run(["status", "--porcelain=v2", "--branch", "--no-ahead-behind", "-z", "--untracked-files=normal"], at: path).stdout)
        var branch = state.branch.map { "refs/heads/\($0)" }
        // Git's status markers can also be legal branch names or describe refs outside refs/heads.
        if state.branch == nil || state.branch == "(null)" {
            let ref = try await git.run(["symbolic-ref", "--quiet", "HEAD"], at: path, allowFailure: true)
            guard ref.status == 0 || ref.status == 1 else { throw MonoDeckError("git-failed", .couldNotReadCurrentBranch) }
            branch = ref.status == 0 ? ref.text : nil
        }
        return (state.changes, branch, state.headOID)
    }
}

private struct RepositoryUpdateContext: Sendable {
    let directory: RepositoryDirectory
    let gitDirectory: RepositoryDirectory
    let origin: String
    let branch: String
    let base: String
    let head: String

    func validateIdentity() throws {
        do { try directory.validate(); try gitDirectory.validate() }
        catch { throw MonoDeckError("repository-changed", .repositoryChangedDuringUpdate) }
    }
}

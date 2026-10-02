import Foundation

extension WorkspaceService {
    public func addRepository(_ repository: Repository, at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "repo.add", workspace: root.path)
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            result.items = [await add(repository, record: &record, progress: progress)]
            result.summarize(cancelled: result.items.contains { $0.status == "cancelled" })
        } catch { result = .init(command: result.command, workspace: root.path, status: "failed", error: .wrap(error)) }
        return result
    }
    func add(_ repository: Repository, record: inout WorkspaceRecord, commitIgnore: Bool = true, progress: ProgressHandler) async -> ItemResult {
        var item = ItemResult(.repository(repository.id))
        var newDirectory: URL?
        do {
            try checkCancellation()
            let name = try RepositoryIdentity(repository.url).name
            item.resource = .repository(name)
            do { try await git.checkRepository(record.rootURL, main: true) }
            catch { throw ModuError("workspace-unavailable", "Workspace repository is unavailable: \(ModuError.wrap(error).message)") }
            let target = try PathSafety.child("repositories/\(name)", of: record.rootURL)
            if let existing = record.repositories.first(where: { $0.id.lowercased() == name.lowercased() }) {
                guard existing.url == repository.url, repository.name == nil || existing.name == repository.name else { throw ModuError("repository-conflict", "Repository name is already registered: \(name)") }
                _ = try await checked(.repository(existing.id), in: record)
                item.data = ["disposition": "already-exists"]
                progress(.init(name, "Saving…", cancellable: false))
                try await finishRepositoryIgnore(name, at: record.rootURL, commit: commitIgnore, item: &item)
                return item
            }
            guard !PathSafety.exists(target) else { throw ModuError("path-conflict", "Repository target already exists: \(target.path)") }
            progress(.init(name, "Checking repository…"))
            let branch = try await remoteDefault(repository.url, at: record.rootURL)
            let temp = record.rootURL.appending(path: "repositories/.modu-clone-\(UUID().uuidString)")
            newDirectory = temp
            progress(.init(name, "Cloning…"))
            _ = try await git.run(["clone", "--no-recurse-submodules", "--no-checkout", "--origin", "origin", "--", repository.url, temp.path], at: record.rootURL, timeout: 1800)
            guard try await git.oid("refs/remotes/origin/\(branch)", at: temp) != nil else { throw ModuError("remote-head-unavailable", "Remote default branch does not identify a commit.") }
            _ = try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/\(branch)"], at: temp)
            _ = try await git.run(["checkout", "-B", branch, "refs/remotes/origin/\(branch)", "--"], at: temp)
            _ = try await git.run(["branch", "--set-upstream-to=origin/\(branch)", "--", branch], at: temp)
            try checkCancellation()
            guard !PathSafety.exists(target) else { throw ModuError("path-conflict", "Repository target is occupied.") }
            try FileManager.default.moveItem(at: temp, to: target); newDirectory = target
            progress(.init(name, "Saving…", cancellable: false))
            var candidate = record; candidate.repositories.append(repository)
            try persist(candidate, into: &record)
            newDirectory = nil
            item.effects.append(.init("clone", target.path)); item.effects.append(.init("save-configuration", name))
            item.data = ["disposition": "added"]
            try await finishRepositoryIgnore(name, at: record.rootURL, commit: commitIgnore, item: &item)
            progress(.init(name, "Added", snapshot: record))
        } catch {
            fail(&item, error)
            if let directory = newDirectory, PathSafety.exists(directory) {
                if item.reasonCode == "save-outcome-unknown" { item.effects.append(.init("clone", directory.path, state: "unknown")) }
                else {
                    progress(.init(item.resource.path, "Cleaning up…", cancellable: false))
                    do { let trash = try trashDirectory(directory); item.trashPath = trash.path; item.effects.append(.init("clone", directory.path, state: "reverted")) }
                    catch { item.causeCode = item.reasonCode; item.reasonCode = "cleanup-failed"; item.message = "\(item.message ?? "") Cleanup failed: \(error.localizedDescription)"; item.effects.append(.init("clone", directory.path, state: "unknown")) }
                }
            }
        }
        return item
    }
    private func finishRepositoryIgnore(_ name: String, at root: URL, commit: Bool, item: inout ItemResult) async throws {
        if try await git.ensureIgnore([name], at: root, cancellable: false) { item.effects.append(.init("update-ignore", root.appending(path: ".gitignore").path)) }
        if commit, let oid = try await git.commitWorkspaceFiles([".gitignore"], message: "chore: ignore Modu repository \(name)", at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
    }
    func remoteDefault(_ url: String, at root: URL) async throws -> String {
        let output = try await git.run(["ls-remote", "--symref", "--", url, "HEAD"], at: root)
        guard let line = output.text.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") && $0.hasSuffix("\tHEAD") }) else { throw ModuError("remote-head-unavailable", "Remote has no valid default branch.") }
        let branch = String(line.dropFirst(16).dropLast(5))
        guard try await git.run(["check-ref-format", "refs/heads/\(branch)"], at: root, allowFailure: true).status == 0 else { throw ModuError("remote-head-unavailable", "Remote default branch is invalid.") }
        return branch
    }

    public func updateRepositories(at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "repo.update", workspace: root.path)
        do {
            let lease = try store.lock(root); defer { lease.unlock() }
            let record = try store.load(root)
            result.items = record.repositories.map { .notProcessed(.repository($0.id)) }
            progress(.init("", "Updating repositories…", total: record.repositories.count))
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
                    progress(.init(record.repositories[index].displayName, "Updating repositories…",
                                   completed: completed, total: record.repositories.count))
                    if next < record.repositories.count {
                        let index = next
                        if group.addTaskUnlessCancelled(operation: {
                            (index, await updateRepository(record.repositories[index], in: record))
                        }) { next += 1 }
                    }
                }
            }
            result.summarize(cancelled: result.items.contains { $0.status == "cancelled" || $0.reasonCode == "not-processed" })
        } catch { result = .init(command: result.command, workspace: root.path, status: "failed", error: .wrap(error)) }
        return result
    }

    private func updateRepository(_ repository: Repository, in record: WorkspaceRecord) async -> ItemResult {
        var item = ItemResult(.repository(repository.id))
        do {
            try checkCancellation()
            let path = try PathSafety.child(item.resource.path, of: record.rootURL)
            guard PathSafety.exists(path) else {
                return ItemResult(item.resource, status: "skipped", error: ModuError("resource-missing", "Repository directory is missing."))
            }
            try await git.checkRepository(path, origin: repository.url, main: true)
            let status = try await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"], at: path)
            guard status.stdout.isEmpty else {
                return ItemResult(item.resource, status: "skipped", error: ModuError("working-tree-dirty", "Working tree has changes."))
            }
            let branch = try await git.run(["symbolic-ref", "--quiet", "HEAD"], at: path, allowFailure: true)
            if branch.status == 1 {
                return ItemResult(item.resource, status: "skipped", error: ModuError("detached-head", "Detached HEAD."))
            }
            guard branch.status == 0 else { throw ModuError("git-failed", "Could not read the current branch.") }
            let base = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true)
            guard base.status == 0, base.text.hasPrefix("refs/remotes/origin/"),
                  try await git.oid(base.text, at: path) != nil else {
                throw ModuError("base-unavailable", "Base branch is unavailable. Fix origin/HEAD in an external Git tool and retry.")
            }
            let remoteBranch = "refs/heads/" + base.text.dropFirst("refs/remotes/origin/".count)
            guard branch.text == remoteBranch else {
                return ItemResult(item.resource, status: "skipped", error: ModuError("not-default-branch", "Current branch is not the Base branch."))
            }
            guard let before = try await git.oid("HEAD", at: path) else { throw ModuError("resource-unavailable", "HEAD is unavailable.") }
            try checkCancellation()
            item.effects.append(.init("update-refs", path.path, state: "unknown"))
            _ = try await git.run(["fetch", "--no-recurse-submodules", "origin", "+\(remoteBranch):\(base.text)"], at: path)
            item.effects[item.effects.count - 1].state = "applied"
            guard let oid = try await git.oid("FETCH_HEAD", at: path) else { throw ModuError("base-unavailable", "Fetched Base branch is unavailable.") }
            item.effects.append(.init("fast-forward", path.path, state: "unknown"))
            _ = try await git.run(["merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", oid], at: path)
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
}

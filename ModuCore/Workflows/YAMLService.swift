import Foundation
import Yams

private struct WorkspaceExport: Codable {
    var version: Int
    var repositories: [Repository]
    var groups: [String: WorktreeGroup]
}

extension WorkspaceService {
    public func exportYAML(at root: URL, to destination: URL) async throws {
        let text = try await exportYAML(at: root)
        if let boundary = store.directoryBoundary { try PathSafety.confined(destination, to: boundary) }
        try Data(text.utf8).write(to: destination, options: .atomic)
    }
    public func exportYAML(at root: URL) async throws -> String {
        let record = try await read(root)
        return try YAMLEncoder().encode(WorkspaceExport(version: 1, repositories: record.repositories, groups: record.groups))
    }
    public func importRepositories(_ urls: [String], at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "repo.import-yaml", workspace: root.path)
        var staging: RepositoryStaging?
        do {
            guard !urls.isEmpty else { throw ModuError("invalid-input", .noCompleteSupportedGitRepositoryURLsWereFound) }
            let identities = try Dictionary(grouping: Set(urls), by: { try RepositoryIdentity($0).name.lowercased() })
            _ = try store.load(root)
            var seen = Set<String>()
            var stopped = false
            for (index, url) in urls.enumerated() {
                let repo = Repository(url: url)
                var item = ItemResult(.repository(repo.id))
                if stopped || Task.isCancelled { item = .notProcessed(item.resource); stopped = true }
                else if !seen.insert(url).inserted { item.status = .skipped; item.reasonCode = "duplicate-url"; item.message = "Duplicate URL."; item.userMessage = .duplicateURL }
                else if identities[repo.id.lowercased()]!.count > 1 { item.status = .failed; item.reasonCode = "repository-conflict"; item.message = "Different URLs derive the same repository name: \(repo.id)"; item.userMessage = .repositoryNameCollision(repo.id) }
                else {
                    progress(.init(repo.id, .importingRepositories, completed: index, total: urls.count))
                    let counts = importCounts(result.items)
                    let report: ProgressHandler = { value in progress(.init(value.target, value.phase, completed: index, total: urls.count, cancellable: value.cancellable, snapshot: value.snapshot, counts: counts)) }
                    do { item = try await add(repo, at: root, staging: &staging, progress: report) }
                    catch { fail(&item, error); stopped = true }
                    if item.status == .success, item.data?["disposition"] == "already-exists" { item.status = .skipped; item.reasonCode = "already-exists" }
                    if ["workspace-unavailable", "ignore-unavailable", "ignore-write-failed", "workspace-commit-failed", "configuration-write-failed", "save-outcome-unknown", "cleanup-failed", "cancelled"].contains(item.reasonCode ?? "") { stopped = true }
                }
                result.items.append(item)
                if item.reasonCode != "not-processed" { progress(.init(repo.id, .importingRepositories, completed: index + 1, total: urls.count, counts: importCounts(result.items))) }
            }
            result.summarize(cancelled: result.items.contains { $0.status == .cancelled || $0.reasonCode == "not-processed" })
        } catch {
            let failure = ModuError.wrap(error, code: "invalid-input")
            let pending = failure.code == "cancelled" ? urls.map { ItemResult.notProcessed(.repository(Repository(url: $0).id)) } : []
            result = .init(command: result.command, workspace: root.path, status: .failed, items: pending, error: failure)
        }
        let cleanupCause = repositoryImportFailureCause(result)
        finishRepositoryStaging(staging, items: &result.items, causeCode: cleanupCause)
        clearCancelledImportFailure(&result)
        if !result.items.isEmpty { result.summarize(cancelled: result.status == .cancelled || result.items.contains { $0.status == .cancelled || $0.reasonCode == "not-processed" }) }
        return result
    }
    private func importCounts(_ items: [ItemResult]) -> (added: Int, skipped: Int, failed: Int) {
        (items.filter { $0.data?["disposition"] == "added" }.count,
         items.filter { ["already-exists", "duplicate-url"].contains($0.reasonCode ?? "") }.count,
         items.filter { $0.status == .failed }.count)
    }
    public static func repositoryURLs(in text: String) throws -> [String] {
        guard let node = try Yams.compose(yaml: text) else { return [] }
        var result: [String] = []
        // Yams resolves aliases while composing, so count every visit to the expanded nodes.
        var remainingNodes = 10_000
        func visit(_ node: Node, depth: Int = 0) throws {
            guard remainingNodes > 0, depth <= 100 else {
                throw ModuError("invalid-input", .yamlTooComplexToImport)
            }
            remainingNodes -= 1
            if let map = node.mapping { for pair in map { try visit(pair.value, depth: depth + 1) } }
            else if let sequence = node.sequence { for child in sequence { try visit(child, depth: depth + 1) } }
            else if let value = node.string {
                let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if (try? RepositoryIdentity(raw)) != nil { result.append(raw) }
                else if raw.hasPrefix("https://") || raw.hasPrefix("ssh://"), let c = URLComponents(string: raw), c.password != nil || (c.scheme == "https" && c.user != nil) || (c.query?.lowercased().contains("token") == true) { throw ModuError("invalid-input", .yamlContainsRepositoryURLWithEmbeddedCredentialsRemove) }
            }
        }
        try visit(node)
        return result
    }
    public func importWorkspaceYAML(_ text: String, at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "workspace.import-yaml", workspace: root.path)
        var desired = WorkspaceRecord(root: root.path)
        var staging: RepositoryStaging?
        var prepared: [PreparedRepository] = []
        do {
            try ConfigValidation.validateDocument(text, workspace: false)
            let document = try YAMLDecoder().decode(WorkspaceExport.self, from: text)
            desired.version = document.version; desired.repositories = document.repositories; desired.groups = document.groups
            try store.validate(desired)
            staging = try await beginWorkspaceImport(desired, at: root)
            var failure: ItemResult?
            if let staging {
                for repo in desired.repositories {
                    progress(.init(repo.id, .checkingRepository, total: desired.repositories.count))
                    switch await prepareRepository(repo, in: staging, reportCleanupEffects: false, progress: progress) {
                    case .ready(let repository): prepared.append(repository)
                    case .failed(let item): failure = item
                    }
                    if failure != nil { break }
                }
            }
            if let failure {
                result.items = pendingWorkspaceImportItems(desired)
                result.items[prepared.count] = failure
                result.summarize(cancelled: failure.status == .cancelled || Task.isCancelled)
            } else {
                result = try await publishWorkspaceImport(desired, prepared: prepared, staging: staging, progress: progress)
            }
        } catch {
            result = .init(command: result.command, workspace: root.path, status: .failed, error: .wrap(error, code: "invalid-input"))
            if staging != nil { result.items = pendingWorkspaceImportItems(desired) }
        }
        let cleanupCause = repositoryImportFailureCause(result)
        for repository in prepared {
            guard let index = result.items.firstIndex(where: { $0.resource == .repository(repository.repository.id) }) else { continue }
            cleanupRepositoryPreparation(repository, item: &result.items[index], reportEffects: false, causeCode: cleanupCause, progress: progress)
        }
        finishRepositoryStaging(staging, items: &result.items, causeCode: cleanupCause)
        clearCancelledImportFailure(&result)
        if result.reasonCode == nil || result.items.contains(where: { $0.reasonCode == "cleanup-failed" }) {
            result.summarize(cancelled: result.status == .cancelled)
        }
        return result
    }

    private func beginWorkspaceImport(_ desired: WorkspaceRecord, at root: URL) async throws -> RepositoryStaging? {
        let lease = try await store.lock(root); defer { lease.unlock() }
        let record = try store.load(root)
        try checkWorkspaceImportDestination(record, staging: nil)
        try await git.checkRepository(root, main: true)
        for group in desired.groups.keys.sorted() {
            try await validateMembers(group, repositories: desired.groups[group]!.repositories, record: desired)
        }
        for name in ["repositories", "worktrees"] { try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true) }
        return desired.repositories.isEmpty ? nil : try RepositoryStaging(at: root)
    }

    private func publishWorkspaceImport(_ desired: WorkspaceRecord, prepared: [PreparedRepository], staging: RepositoryStaging?, progress: ProgressHandler) async throws -> OperationResult {
        let root = desired.rootURL
        let lease = try await store.lock(root); defer { lease.unlock() }
        var record = try store.load(root)
        try checkWorkspaceImportDestination(record, staging: staging)
        try await git.checkRepository(root, main: true)
        var result = OperationResult(command: "workspace.import-yaml", workspace: root.path)
        var stopped = false
        for repository in prepared {
            if stopped || Task.isCancelled {
                result.items.append(.notProcessed(.repository(repository.repository.id))); stopped = true; continue
            }
            let item = await publishRepository(repository, record: &record, commitIgnore: false, progress: progress)
            result.items.append(item); stopped = item.status != .success
        }
        if !stopped || !record.repositories.isEmpty {
            var item = ItemResult(.workspace())
            progress(.init(root.path, .saving, cancellable: false))
            do {
                if let oid = try await git.commitWorkspaceFiles([".gitignore"], message: "chore: import Modu workspace repositories", at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
            } catch { fail(&item, error); stopped = true }
            if !item.effects.isEmpty || item.status != .success { result.items.append(item) }
        }
        if Task.isCancelled && !desired.groups.isEmpty { stopped = true }
        for name in desired.groups.keys.sorted() {
            let group = desired.groups[name]!
            let resources = [Resource.group(name)] + group.repositories.map { Resource.member(name, $0) }
            if stopped { result.items += resources.map(ItemResult.notProcessed); continue }
            do {
                progress(.init(Resource.group(name).path, .checkingRepository))
                let plans = try await creationPlans(name, members: group.repositories, record: record)
                for plan in plans {
                    if stopped { result.items.append(.notProcessed(plan.resource)); continue }
                    let item = await create(plan, record: &record, createdAt: group.createdAt, progress: progress)
                    result.items.append(item); stopped = item.status != .success
                }
            } catch {
                var item = ItemResult(.group(name)); fail(&item, error)
                result.items.append(item); result.items += resources.dropFirst().map(ItemResult.notProcessed); stopped = true
            }
        }
        result.summarize(cancelled: result.items.contains { $0.status == .cancelled } || (Task.isCancelled && stopped))
        return result
    }

    private func checkWorkspaceImportDestination(_ record: WorkspaceRecord, staging: RepositoryStaging?) throws {
        guard record.repositories.isEmpty && record.groups.isEmpty else { throw ModuError("workspace-not-empty", .importRequiresEmptyWorkspaceChooseAnotherWorkspaceIn) }
        try staging?.validate()
        try PathSafety.emptyResourceDirectories(record.rootURL, excluding: staging.map { [$0.directory.url] } ?? [])
    }

    private func pendingWorkspaceImportItems(_ desired: WorkspaceRecord) -> [ItemResult] {
        desired.repositories.map { .notProcessed(.repository($0.id)) } + desired.groups.keys.sorted().flatMap { name in
            [ItemResult.notProcessed(.group(name))] + desired.groups[name]!.repositories.map { .notProcessed(.member(name, $0)) }
        }
    }

    private func repositoryImportFailureCause(_ result: OperationResult) -> String? {
        if let reason = result.reasonCode { return reason }
        if let failed = result.items.first(where: { $0.status == .failed }) {
            return failed.reasonCode == "cleanup-failed" ? failed.causeCode ?? failed.reasonCode : failed.reasonCode
        }
        return result.status == .cancelled || Task.isCancelled ? "cancelled" : nil
    }

    private func clearCancelledImportFailure(_ result: inout OperationResult) {
        guard result.reasonCode == "cancelled", result.items.contains(where: { $0.reasonCode == "cleanup-failed" }) else { return }
        result.reasonCode = nil; result.message = nil; result.userMessage = nil
    }
}

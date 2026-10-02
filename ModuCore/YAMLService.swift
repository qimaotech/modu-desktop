import Foundation
import Yams

private struct WorkspaceExport: Codable {
    var version: Int
    var repositories: [Repository]
    var groups: [String: WorktreeGroup]
}

extension WorkspaceService {
    public func exportYAML(at root: URL) async throws -> String {
        let record = try await load(root)
        return try YAMLEncoder().encode(WorkspaceExport(version: 1, repositories: record.repositories, groups: record.groups))
    }
    public func importRepositoryYAML(_ text: String, at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "repo.import-yaml", workspace: root.path)
        do {
            let urls = try Self.repositoryURLs(in: text)
            guard !urls.isEmpty else { throw ModuError("invalid-input", "No complete, supported Git repository URLs were found in this YAML file.") }
            let lease = try store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            let identities = Dictionary(grouping: Set(urls), by: { (try! RepositoryIdentity($0)).name.lowercased() })
            var seen = Set<String>()
            var stopped = false
            for (index, url) in urls.enumerated() {
                let repo = Repository(url: url)
                var item = ItemResult(.repository(repo.id))
                if stopped || Task.isCancelled { item = .notProcessed(item.resource); stopped = true }
                else if !seen.insert(url).inserted { item.status = "skipped"; item.reasonCode = "duplicate-url"; item.message = "Duplicate URL." }
                else if identities[repo.id.lowercased()]!.count > 1 { item.status = "failed"; item.reasonCode = "repository-conflict"; item.message = "Different URLs derive the same repository name: \(repo.id)" }
                else {
                    progress(.init(repo.id, "Importing repositories…", completed: index, total: urls.count))
                    let counts = importCounts(result.items)
                    let report: ProgressHandler = { value in progress(.init(value.target, value.phase, completed: index, total: urls.count, cancellable: value.cancellable, snapshot: value.snapshot, counts: counts)) }
                    item = await add(repo, record: &record, progress: report)
                    if item.status == "success", item.data?["disposition"] == "already-exists" { item.status = "skipped"; item.reasonCode = "already-exists" }
                    if ["workspace-unavailable", "ignore-unavailable", "ignore-write-failed", "workspace-commit-failed", "configuration-write-failed", "save-outcome-unknown", "cleanup-failed", "cancelled"].contains(item.reasonCode ?? "") { stopped = true }
                }
                result.items.append(item)
                if item.reasonCode != "not-processed" { progress(.init(repo.id, "Importing repositories…", completed: index + 1, total: urls.count, counts: importCounts(result.items))) }
            }
            result.summarize(cancelled: Task.isCancelled || result.items.contains { $0.status == "cancelled" })
        } catch { result = .init(command: result.command, workspace: root.path, status: "failed", error: .wrap(error, code: "invalid-input")) }
        return result
    }
    private func importCounts(_ items: [ItemResult]) -> (added: Int, skipped: Int, failed: Int) {
        (items.filter { $0.data?["disposition"] == "added" }.count,
         items.filter { ["already-exists", "duplicate-url"].contains($0.reasonCode ?? "") }.count,
         items.filter { $0.status == "failed" }.count)
    }
    public static func repositoryURLs(in text: String) throws -> [String] {
        guard let node = try Yams.compose(yaml: text) else { return [] }
        var result: [String] = []
        var anchors: [String: Node] = [:]
        func collect(_ node: Node) {
            if case .alias = node { return }
            if let anchor = node.anchor { anchors[anchor.rawValue] = node }
            if let map = node.mapping { for pair in map { collect(pair.key); collect(pair.value) } }
            else if let sequence = node.sequence { for child in sequence { collect(child) } }
        }
        collect(node)
        var visiting = Set<String>()
        func visit(_ node: Node) throws {
            if case .alias(let alias) = node {
                guard let target = anchors[alias.anchor.rawValue], visiting.insert(alias.anchor.rawValue).inserted else { throw ModuError("invalid-input", "YAML contains an unresolved or recursive alias.") }
                defer { visiting.remove(alias.anchor.rawValue) }
                try visit(target); return
            }
            if let map = node.mapping { for pair in map { try visit(pair.value) } }
            else if let sequence = node.sequence { for child in sequence { try visit(child) } }
            else if let value = node.string {
                let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if (try? RepositoryIdentity(raw)) != nil { result.append(raw) }
                else if raw.hasPrefix("https://") || raw.hasPrefix("ssh://"), let c = URLComponents(string: raw), c.password != nil || (c.scheme == "https" && c.user != nil) || (c.query?.lowercased().contains("token") == true) { throw ModuError("invalid-input", "YAML contains a repository URL with embedded credentials. Remove credentials and retry.") }
            }
        }
        try visit(node)
        return result
    }
    public func importWorkspaceYAML(_ text: String, at root: URL, progress: ProgressHandler = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "workspace.import-yaml", workspace: root.path)
        do {
            try ConfigValidation.validateDocument(text, workspace: false)
            let document = try YAMLDecoder().decode(WorkspaceExport.self, from: text)
            var desired = WorkspaceRecord(root: root.path)
            desired.version = document.version; desired.repositories = document.repositories; desired.groups = document.groups
            try store.validate(desired)
            let lease = try store.lock(root); defer { lease.unlock() }
            var record = try store.load(root)
            guard record.repositories.isEmpty && record.groups.isEmpty else { throw ModuError("workspace-not-empty", "Import requires an empty workspace. Choose another workspace in Settings. Existing files and configuration were not changed.") }
            try PathSafety.emptyResourceDirectories(root)
            try await git.checkRepository(root, main: true)
            for group in desired.groups.keys.sorted() {
                try await validateMembers(group, repositories: desired.groups[group]!.repositories, record: desired)
            }
            for name in ["repositories", "worktrees"] { try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true) }
            var stopped = false
            for repo in desired.repositories {
                if stopped { result.items.append(.notProcessed(.repository(repo.id))); continue }
                let item = await add(repo, record: &record, commitIgnore: false, progress: progress)
                result.items.append(item); stopped = item.status != "success"
            }
            if !stopped || !record.repositories.isEmpty {
                var item = ItemResult(.init(kind: "workspace", path: "."))
                progress(.init(root.path, "Saving…", cancellable: false))
                do {
                    if let oid = try await git.commitWorkspaceFiles([".gitignore"], message: "chore: import Modu workspace repositories", at: root) { item.effects.append(.init("commit-workspace-files", oid)) }
                } catch { fail(&item, error); stopped = true }
                if !item.effects.isEmpty || item.status != "success" { result.items.append(item) }
            }
            if Task.isCancelled && !desired.groups.isEmpty { stopped = true }
            for name in desired.groups.keys.sorted() {
                let group = desired.groups[name]!
                let resources = [Resource.group(name)] + group.repositories.map { Resource.member(name, $0) }
                if stopped { result.items += resources.map(ItemResult.notProcessed); continue }
                do {
                    let plans = try await creationPlans(name, members: group.repositories, record: record)
                    for plan in plans {
                        if stopped { result.items.append(.notProcessed(plan.resource)); continue }
                        let item = await create(plan, record: &record, createdAt: group.createdAt, progress: progress)
                        result.items.append(item); stopped = item.status != "success"
                    }
                } catch {
                    var item = ItemResult(.group(name)); fail(&item, error); result.items.append(item)
                    result.items += resources.dropFirst().map(ItemResult.notProcessed); stopped = true
                }
            }
            result.summarize(cancelled: result.items.contains { $0.status == "cancelled" } || (Task.isCancelled && stopped))
        } catch { result = .init(command: result.command, workspace: root.path, status: "failed", error: .wrap(error, code: "invalid-input")) }
        return result
    }
}

import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class RepositoryDetailModel {
    private let service: WorkspaceService
    private var workspace: WorkspaceRecord?
    private var selection: Resource?
    private(set) var detail = RepositoryDetailState()
    private(set) var detailLoading = false
    var states: [String: ResourceState] = [:]
    private(set) var detailTask: Task<Void, Never>?
    private(set) var detailPreloadTask: Task<Void, Never>?
    private var generation = 0
    private var detailCache: [Resource: RepositoryDetailState] = [:]
    private var commitCache: [String: CommitPage] = [:]
    // Inspection snapshots skip one background reread; selecting a resource always refreshes it.
    private var freshSnapshots: [Resource: ResourceSnapshot] = [:]
    @ObservationIgnored var onIdle: (() -> Void)?
    @ObservationIgnored var onCommitsError: ((ModuError) -> Void)?
    private var currentURL: URL? {
        guard let workspace, let selection else { return nil }
        return try? PathSafety.child(selection.path, of: workspace.rootURL, allowMissing: false)
    }

    init(service: WorkspaceService) { self.service = service }

    func refresh(_ selection: Resource?, in workspace: WorkspaceRecord?) {
        self.selection = selection; self.workspace = workspace
        cancelPreload()
        detailTask?.cancel(); generation += 1
        detail = selection.flatMap { detailCache[$0] } ?? RepositoryDetailState()
        guard let selection, let workspace else {
            detailLoading = false; onIdle?(); return
        }
        freshSnapshots.removeValue(forKey: selection)
        detailLoading = true
        let token = generation, root = workspace.root, cached = detail
        detailTask = Task(priority: .userInitiated) {
            let loaded = await readDetail(selection, in: workspace, cached: cached) { @MainActor [self] partial in
                guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
                detail = partial; detailCache[selection] = partial
                updateState(selection, from: partial)
            }
            guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
            if let loaded {
                detail = loaded; detailCache[selection] = loaded; updateState(selection, from: loaded)
                if loaded.summary?.baseOID != nil, let error = loaded.commitsError { onCommitsError?(error) }
            }
            detailLoading = false
            onIdle?()
        }
    }
    func loadMore() {
        guard !detailLoading, let selection, let root = workspace?.root,
              let path = currentURL, let summary = detail.summary, let base = summary.baseOID,
              let commits = detail.commits, detail.canLoadMore else { return }
        let token = generation, key = "\(root)|\(selection.repo ?? "")|\(summary.headOID)|\(base)"
        cancelPreload()
        detailLoading = true
        detailTask = Task {
            defer {
                if !Task.isCancelled, self.generation == token, self.workspace?.root == root {
                    detailCache[selection] = detail; detailLoading = false; onIdle?()
                }
            }
            do {
                let more = try await service.git.commits(at: path, head: summary.headOID, base: base, skip: commits.count)
                guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
                let page = CommitPage(commits: commits + more, canLoadMore: more.count == 30)
                commitCache[key] = page; detail.commits = page.commits; detail.canLoadMore = page.canLoadMore; detail.commitsError = nil
            } catch {
                guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
                detail.commitsError = .wrap(error)
                onCommitsError?(.wrap(error))
            }
        }
    }
    func cache(_ snapshot: ResourceSnapshot) {
        guard selection != snapshot.resource else { return }
        detailCache[snapshot.resource] = RepositoryDetailState(snapshot: snapshot, cached: detailCache[snapshot.resource])
        freshSnapshots[snapshot.resource] = snapshot
    }

    func restore(_ detail: RepositoryDetailState, for resource: Resource) { detailCache[resource] = detail }

    func preload(in workspace: WorkspaceRecord) {
        guard detailPreloadTask == nil, !detailLoading else { return }
        self.workspace = workspace
        let resources = service.resources(workspace).filter { detailCache[$0] == nil || freshSnapshots[$0] != nil }
        guard !resources.isEmpty else { return }
        detailPreloadTask = Task(priority: .utility) {
            defer { if !Task.isCancelled { detailPreloadTask = nil } }
            for resource in resources {
                guard !Task.isCancelled, self.workspace == workspace else { return }
                guard let loaded = await readDetail(resource, in: workspace, snapshot: freshSnapshots[resource]), !Task.isCancelled,
                      self.workspace == workspace else { return }
                freshSnapshots.removeValue(forKey: resource)
                detailCache[resource] = loaded
                updateState(resource, from: loaded)
            }
        }
    }

    func cancelPreload() {
        detailPreloadTask?.cancel(); detailPreloadTask = nil
    }

    func invalidate() {
        cancelPreload()
        detailTask?.cancel(); generation += 1; detailLoading = false
        detailCache = [:]; commitCache = [:]; freshSnapshots = [:]
    }

    private func readDetail(_ resource: Resource, in workspace: WorkspaceRecord, cached: RepositoryDetailState? = nil, snapshot fresh: ResourceSnapshot? = nil, publish: @Sendable (RepositoryDetailState) async -> Void = { _ in }) async -> RepositoryDetailState? {
        var loaded = cached ?? RepositoryDetailState()
        let snapshot: ResourceSnapshot
        do {
            if let fresh { snapshot = fresh }
            else {
                snapshot = try await service.snapshot(resource, in: workspace) { partial in
                    await publish(RepositoryDetailState(snapshot: partial, cached: cached))
                }
            }
        } catch {
            guard !Task.isCancelled else { return nil }
            return RepositoryDetailState(summaryError: .wrap(error), changesError: .wrap(error), commitsError: .wrap(error))
        }
        guard !Task.isCancelled else { return nil }
        loaded = RepositoryDetailState(snapshot: snapshot, cached: cached)
        let path = workspace.rootURL.appending(path: resource.path)
        if let value = snapshot.summary {
            loaded.summary = value; loaded.summaryError = nil
            if let base = value.baseOID {
                let key = "\(workspace.root)|\(resource.repo ?? "")|\(value.headOID)|\(base)"
                if let cached = commitCache[key] {
                    loaded.commits = cached.commits; loaded.canLoadMore = cached.canLoadMore; loaded.commitsError = nil
                } else {
                    await publish(loaded)
                    do {
                        let values = try await service.git.commits(at: path, head: value.headOID, base: base)
                        guard !Task.isCancelled else { return nil }
                        let page = CommitPage(commits: values, canLoadMore: values.count == 30)
                        commitCache[key] = page; loaded.commits = page.commits; loaded.canLoadMore = page.canLoadMore; loaded.commitsError = nil
                    } catch { loaded.commitsError = .wrap(error) }
                }
            } else { loaded.commits = value.hasRemotes ? nil : []; loaded.canLoadMore = false; loaded.commitsError = value.baseError.map { ModuError("base-unavailable", $0, userMessage: value.baseMessage) } }
        } else {
            loaded.commits = nil; loaded.canLoadMore = false; loaded.commitsError = snapshot.summaryError
        }
        return Task.isCancelled ? nil : loaded
    }

    private func updateState(_ resource: Resource, from detail: RepositoryDetailState) {
        states[resource.id] = ResourceState(resource: resource, available: detail.changesError == nil, dirty: detail.changes.map { !$0.isEmpty }, reason: detail.changesError?.message, reasonMessage: detail.changesError?.userMessage)
    }
}

struct RepositoryDetailState: Sendable {
    var summary: GitSummary?
    var summaryError: ModuError?
    var changes: [FileChange]?
    var changesError: ModuError?
    var commits: [GitCommit]?
    var commitsError: ModuError?
    var canLoadMore = false
}

extension RepositoryDetailState {
    init(snapshot: ResourceSnapshot, cached: RepositoryDetailState? = nil) {
        self = cached ?? .init()
        changes = snapshot.changes; changesError = snapshot.changesError
        if snapshot.summary != nil || snapshot.summaryError != nil {
            summary = snapshot.summary; summaryError = snapshot.summaryError
        }
    }
}

private struct CommitPage {
    var commits: [GitCommit]
    var canLoadMore: Bool
}

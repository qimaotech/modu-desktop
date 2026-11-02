import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class RepositoryDetailModel {
    private let service: WorkspaceService
    private let defaults: UserDefaults
    private let monitor: any ResourceChangeMonitoring
    private let readCommits: @Sendable (URL, String, String) async throws -> [GitCommit]
    private var workspace: WorkspaceRecord?
    private var selection: Resource?
    var collapsedPaths = Set<String>() {
        didSet {
            guard let key = collapsedPathsPreferenceKey else { return }
            let paths = collapsedPaths.sorted()
            if defaults.stringArray(forKey: key) != paths { defaults.set(paths, forKey: key) }
        }
    }
    private(set) var detail = RepositoryDetailState()
    private(set) var changesLoading = false
    private(set) var summaryLoading = false
    var hasActiveReads: Bool { detailTask != nil || detailPreloadTask != nil || cancellationDrain != nil || monitoring || fallbackTask != nil }
    var snapshotLoading: Bool { changesLoading || summaryLoading }
    var detailLoading: Bool { detailTask != nil }
    var states: [String: ResourceState] = [:]
    private(set) var detailTask: Task<Void, Never>?
    private(set) var detailPreloadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var changeBurstStart: ContinuousClock.Instant?
    private var pendingChange: ResourceChange?
    private var cancellationDrain: Task<Void, Never>?
    private var drainID = UUID()
    private var generation = 0
    private var preloadGeneration = 0
    private var pendingPreload = Set<Resource>()
    private var readContext: ResourceReadContext?
    private var monitoring = false
    private var suspended = false
    private var active = true
    private var detailWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var detailCache: [Resource: RepositoryDetailState] = [:]
    private var preloadedSnapshots: [Resource: RepositoryDetailState] = [:]
    private var commitCache: [String: [GitCommit]] = [:]
    private var behindCommitCache: [String: [GitCommit]] = [:]
    @ObservationIgnored var onIdle: (() -> Void)?
    @ObservationIgnored var onCommitsError: ((ModuError) -> Void)?
    private var collapsedPathsPreferenceKey: String? {
        guard let workspace, let selection else { return nil }
        return "detail.\(workspace.root).\(selection.id).collapsedPaths"
    }

    init(service: WorkspaceService, defaults: UserDefaults, monitor: any ResourceChangeMonitoring = ResourceChangeMonitor(),
         readCommits: (@Sendable (URL, String, String) async throws -> [GitCommit])? = nil) {
        self.service = service; self.defaults = defaults; self.monitor = monitor
        self.readCommits = readCommits ?? { path, head, base in
            try await service.git.commits(at: path, head: head, base: base, limit: nil)
        }
    }

    func refresh(_ selection: Resource?, in workspace: WorkspaceRecord?) {
        if self.selection != selection || self.workspace != workspace {
            _ = cancelCurrent()
            self.selection = selection; self.workspace = workspace
            detail = selection.flatMap { detailCache[$0] } ?? RepositoryDetailState()
            collapsedPaths = Set(collapsedPathsPreferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
        }
        guard selection != nil, workspace != nil else { onIdle?(); return }
        request(.structure)
    }

    func request(_ change: ResourceChange) {
        guard selection != nil, workspace != nil else { return }
        pendingChange = max(pendingChange ?? change, change)
        cancelPreload()
        startRefresh()
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active { request(.structure) }
        else { debounceTask?.cancel(); debounceTask = nil; changeBurstStart = nil; cancelPreload() }
    }

    func pause() -> [Task<Void, Never>] {
        suspended = true
        pendingChange = .structure
        return cancelCurrent()
    }

    func resume() {
        suspended = false
        startRefresh()
    }

    func stop() -> [Task<Void, Never>] {
        suspended = true; pendingChange = nil
        return cancelCurrent()
    }

    func waitForDetail() async {
        guard detailTask != nil, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, detailTask != nil else { continuation.resume(); return }
                detailWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.detailWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    func cache(_ snapshot: ResourceSnapshot) {
        guard selection != snapshot.resource else { return }
        let loaded = RepositoryDetailState(snapshot: snapshot, cached: detailCache[snapshot.resource])
        preloadedSnapshots[snapshot.resource] = loaded
        updateState(snapshot.resource, from: loaded)
    }

    func restore(_ detail: RepositoryDetailState, for resource: Resource) { detailCache[resource] = detail }

    func preload(in workspace: WorkspaceRecord, force: Bool = false) {
        guard detailPreloadTask == nil, !snapshotLoading, !suspended, active else { return }
        self.workspace = workspace
        let resources = Set(service.resources(workspace))
        pendingPreload.formIntersection(resources)
        pendingPreload.formUnion(resources.filter { force || (detailCache[$0] == nil && preloadedSnapshots[$0] == nil) })
        if let selection { pendingPreload.remove(selection) }
        guard !pendingPreload.isEmpty, cancellationDrain == nil else { return }
        let requested = pendingPreload
        let token = preloadGeneration
        detailPreloadTask = Task(priority: .utility) {
            _ = await service.inspect(workspace, excluding: selection, policy: .localOnly, visibility: .application, concurrency: 2, including: requested) { @MainActor [weak self] snapshot in
                guard let self, !Task.isCancelled, self.preloadGeneration == token, self.workspace == workspace else { return }
                self.cache(snapshot)
                self.pendingPreload.remove(snapshot.resource)
            }
            if !Task.isCancelled, preloadGeneration == token { detailPreloadTask = nil }
        }
    }

    func cancelPreload() {
        let task = detailPreloadTask
        task?.cancel(); detailPreloadTask = nil; preloadGeneration += 1
        if let task { _ = drainCancelledTasks([task]) }
    }

    func invalidate() {
        _ = cancelCurrent()
        detailCache = [:]; preloadedSnapshots = [:]; commitCache = [:]; behindCommitCache = [:]; pendingPreload = []
        pendingChange = .structure
    }

    private func startRefresh() {
        guard detailTask == nil, !suspended, active, pendingChange != nil, let selection, let workspace else { return }
        let token = generation
        changesLoading = true
        detailTask = Task(priority: .userInitiated) {
            guard isCurrent(token, resource: selection, root: workspace.root) else { return }
            while active, !suspended, let change = pendingChange {
                pendingChange = nil
                changesLoading = true
                await readSnapshot(selection, in: workspace, change: change, token: token)
                guard isCurrent(token, resource: selection, root: workspace.root) else { return }
            }
            guard isCurrent(token, resource: selection, root: workspace.root) else { return }
            detailTask = nil; changesLoading = false; summaryLoading = false
            finishDetail()
            onIdle?()
        }
    }

    private func readSnapshot(_ resource: Resource, in workspace: WorkspaceRecord, change: ResourceChange, token: Int) async {
        guard isCurrent(token, resource: resource, root: workspace.root) else { return }
        var next = preloadedSnapshots[resource] ?? detail
        do {
            let context: ResourceReadContext
            if change != .structure, let existing = readContext, existing.isValid(in: workspace) { context = existing }
            else {
                stopMonitoring()
                context = try await service.prepareResourceRead(resource, in: workspace, visibility: .application)
                guard isCurrent(token, resource: resource, root: workspace.root) else { return }
                readContext = context
            }
            if !monitoring { startMonitoring(context, token: token) }
            let state = try await service.workingState(context, visibility: .application)
            guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            let headChanged = next.summary?.headOID != state.headOID || next.summary?.head != state.head
            next.changes = state.changes; next.changesError = nil
            changesLoading = false
            if change >= .summary || headChanged || next.summary == nil {
                summaryLoading = true
                next.summary = try await service.summary(context, workingState: state)
                guard isCurrent(token, resource: resource, root: workspace.root) else { return }
                next.summaryError = nil
            }
            summaryLoading = false
            if pendingChange == nil { onIdle?() }
            next = await readHistory(next, resource: resource, in: workspace, token: token)
        } catch {
            guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            let error = ModuError.wrap(error)
            if changesLoading { next.changes = nil; next.changesError = error }
            next.summary = nil; next.summaryError = error
            next.commits = nil; next.behindCommits = nil; next.commitsError = error; next.comparisonError = nil
            readContext = nil; stopMonitoring(); startFallback(token: token)
        }
        guard isCurrent(token, resource: resource, root: workspace.root) else { return }
        detail = next
        detailCache[resource] = next; preloadedSnapshots.removeValue(forKey: resource)
        changesLoading = false; summaryLoading = false
        updateState(resource, from: next)
        if let error = next.commitsError, next.summary?.baseOID != nil { onCommitsError?(error) }
        finishDetail()
    }

    private func readHistory(_ initial: RepositoryDetailState, resource: Resource, in workspace: WorkspaceRecord, token: Int) async -> RepositoryDetailState {
        guard isCurrent(token, resource: resource, root: workspace.root) else { return initial }
        var next = initial
        guard let summary = next.summary else { return next }
        guard let base = summary.baseOID else {
            next.commits = summary.hasRemotes ? nil : []
            next.commitsError = summary.baseError.map { ModuError("base-unavailable", $0, userMessage: summary.baseMessage) }
            next.behindCommits = nil; next.comparisonError = nil
            return next
        }
        let key = historyKey(summary, root: workspace.root, resource: resource)
        let path = workspace.rootURL.appending(path: resource.path)
        async let ahead = readHistoryRange(at: path, head: summary.headOID, base: base, cached: commitCache[key])
        async let behind = readHistoryRange(at: path, head: base, base: summary.headOID, cached: behindCommitCache[key])
        let results = await (ahead, behind)
        guard isCurrent(token, resource: resource, root: workspace.root) else { return next }
        switch results.0 {
        case .success(let commits):
            commitCache[key] = commits; next.commits = commits; next.commitsError = nil
        case .failure(let error): next.commits = nil; next.commitsError = error
        }
        switch results.1 {
        case .success(let commits):
            behindCommitCache[key] = commits; next.behindCommits = commits; next.comparisonError = nil
        case .failure(let error): next.behindCommits = nil; next.comparisonError = error
        }
        return next
    }

    private func readHistoryRange(at path: URL, head: String, base: String, cached: [GitCommit]?) async -> Result<[GitCommit], ModuError> {
        if let cached { return .success(cached) }
        do { return .success(try await readCommits(path, head, base)) }
        catch { return .failure(.wrap(error)) }
    }

    private func startMonitoring(_ context: ResourceReadContext, token: Int) {
        let excluded = context.resource.kind == .group ? (context.workspace.groups[context.resource.group ?? ""]?.repositories ?? []).map { context.workspace.memberURL(context.resource.group!, $0) } : []
        monitoring = monitor.start(context, excludedDirectories: excluded) { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.suspended else { return }
                self.received(change)
            }
        }
        if monitoring { fallbackTask?.cancel(); fallbackTask = nil }
        else { startFallback(token: token) }
    }

    private func received(_ change: ResourceChange) {
        pendingChange = max(pendingChange ?? change, change)
        guard active, !suspended else { return }
        let now = ContinuousClock.now
        if changeBurstStart == nil { changeBurstStart = now }
        let deadline = min(now.advanced(by: .milliseconds(150)), changeBurstStart!.advanced(by: .seconds(1)))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self else { return }
            self.changeBurstStart = nil; self.debounceTask = nil
            self.cancelPreload(); self.startRefresh()
        }
    }

    private func startFallback(token: Int) {
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == token else { return }
                if self.active, !self.suspended { self.request(.structure) }
            }
        }
    }

    private func stopMonitoring() {
        monitor.stop(); monitoring = false
        fallbackTask?.cancel(); fallbackTask = nil
        debounceTask?.cancel(); debounceTask = nil; changeBurstStart = nil
    }

    private func cancelCurrent() -> [Task<Void, Never>] {
        let tasks = [detailTask].compactMap { $0 }
        for task in tasks { task.cancel() }
        detailTask = nil; cancelPreload()
        generation += 1; readContext = nil
        stopMonitoring()
        changesLoading = false; summaryLoading = false
        finishDetail()
        return drainCancelledTasks(tasks).map { [$0] } ?? []
    }

    private func drainCancelledTasks(_ tasks: [Task<Void, Never>]) -> Task<Void, Never>? {
        let previous = cancellationDrain
        guard !tasks.isEmpty || previous != nil else { return nil }
        let id = UUID(); drainID = id
        let drain = Task { [weak self] in
            await previous?.value
            for task in tasks { await task.value }
            guard let self, self.drainID == id else { return }
            self.cancellationDrain = nil
            self.onIdle?()
        }
        cancellationDrain = drain
        return drain
    }

    private func isCurrent(_ token: Int, resource: Resource, root: String) -> Bool {
        !Task.isCancelled && generation == token && selection == resource && workspace?.root == root
    }

    private func historyKey(_ summary: GitSummary, root: String, resource: Resource) -> String {
        "\(root)|\(resource.repo ?? "")|\(summary.headOID)|\(summary.baseOID ?? "")"
    }

    private func finishDetail() {
        let waiters = detailWaiters; detailWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
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
    var behindCommits: [GitCommit]?
    var comparisonError: ModuError?
}

extension RepositoryDetailState {
    init(snapshot: ResourceSnapshot, cached: RepositoryDetailState? = nil) {
        self = cached ?? .init()
        changes = snapshot.changes; changesError = snapshot.changesError
        if snapshot.summary != nil || snapshot.summaryError != nil {
            if summary?.headOID != snapshot.summary?.headOID || summary?.baseOID != snapshot.summary?.baseOID || snapshot.summaryError != nil {
                commits = nil; commitsError = nil
                behindCommits = nil; comparisonError = nil
            }
            summary = snapshot.summary; summaryError = snapshot.summaryError
        }
    }
}

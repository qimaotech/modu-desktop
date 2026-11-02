import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class RepositoryDetailModel {
    private let service: WorkspaceService
    private let defaults: UserDefaults
    private let monitor: any ResourceChangeMonitoring
    private let readCommits: @Sendable (URL, String, String) async throws -> [GitCommit]
    private let now: @MainActor () -> ContinuousClock.Instant
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
    func state(for resource: Resource) -> ResourceState? { resources[resource]?.state }

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
    private var preloadScope = Set<Resource>()
    private var runningPreload = Set<Resource>()
    private var readContext: ResourceReadContext?
    private var monitoring = false
    private var suspended = false
    private var active = true
    private var detailWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var resources: [Resource: ResourceCacheEntry] = [:]
    private var histories: [HistoryKey: HistoryCacheEntry] = [:]
    private var historyUse = 0
    @ObservationIgnored var onIdle: (() -> Void)?
    @ObservationIgnored var onCommitsError: ((ModuError) -> Void)?
    private var collapsedPathsPreferenceKey: String? {
        guard let workspace, let selection else { return nil }
        return "detail.\(workspace.root).\(selection.id).collapsedPaths"
    }

    init(service: WorkspaceService, defaults: UserDefaults, monitor: any ResourceChangeMonitoring = ResourceChangeMonitor(),
         readCommits: (@Sendable (URL, String, String) async throws -> [GitCommit])? = nil,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.service = service; self.defaults = defaults; self.monitor = monitor; self.now = now
        self.readCommits = readCommits ?? { path, head, base in
            try await service.git.commits(at: path, head: head, base: base, limit: nil)
        }
    }

    @discardableResult func applyWorkspace(_ workspace: WorkspaceRecord?) -> Bool {
        guard self.workspace != workspace else { return false }
        let previous = self.workspace
        let rootChanged = previous?.root != workspace?.root
        let previousIdentities = identities(in: previous)
        let currentIdentities = identities(in: workspace)
        let contextChanged = rootChanged || selection.map { resource in
            previousIdentities[resource] != currentIdentities[resource]
                || (resource.kind == .group && Set(previous?.groups[resource.group ?? ""]?.repositories ?? []) != Set(workspace?.groups[resource.group ?? ""]?.repositories ?? []))
        } == true
        if contextChanged { cancelCurrent(); pendingChange = selection == nil ? nil : .structure }
        else { cancelPreload() }
        if rootChanged {
            resources = [:]; histories = [:]; pendingPreload = []; preloadScope = []
            detail = .init()
        } else {
            let configured = Set(currentIdentities.keys)
            resources = resources.filter { configured.contains($0.key) && previousIdentities[$0.key] == currentIdentities[$0.key] }
            pendingPreload.formIntersection(configured)
            preloadScope.formIntersection(configured)
            if let selection, let current = currentIdentities[selection], current != previousIdentities[selection] { detail = .init() }
        }
        self.workspace = workspace
        if rootChanged { collapsedPaths = Set(collapsedPathsPreferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? []) }
        return contextChanged
    }

    func refresh(_ selection: Resource?, in workspace: WorkspaceRecord?) {
        let changedSelection = self.selection != selection
        applyWorkspace(workspace)
        if changedSelection {
            cancelCurrent()
            self.selection = selection
            detail = selection.flatMap { resources[$0]?.lastCompleteDetail } ?? RepositoryDetailState()
            collapsedPaths = Set(collapsedPathsPreferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
        }
        guard selection != nil, workspace != nil else { onIdle?(); return }
        request(.structure)
    }

    func request(_ change: ResourceChange) {
        guard selection != nil, workspace != nil else { return }
        pendingChange = max(pendingChange ?? change, change)
        if let selection { resources[selection, default: .init()].invalidated = true }
        cancelPreload()
        startRefresh()
    }

    func setActive(_ active: Bool, refresh: Bool = true) {
        let changed = self.active != active
        self.active = active
        if !active { debounceTask?.cancel(); debounceTask = nil; changeBurstStart = nil; cancelPreload() }
        else if changed && refresh { request(.structure) }
    }

    func pause() {
        suspended = true
        pendingChange = .structure
        cancelCurrent()
    }

    func resume() {
        suspended = false
        startRefresh()
    }

    func stop() {
        suspended = true; pendingChange = nil
        cancelCurrent()
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

    func waitForReads() async {
        while let drain = cancellationDrain { await drain.value }
    }

    func cache(_ snapshot: ResourceSnapshot) {
        guard selection != snapshot.resource else { return }
        updateState(snapshot.resource, changes: snapshot.changes, error: snapshot.changesError)
    }

    func preload(in workspace: WorkspaceRecord, including included: Set<Resource>) {
        applyWorkspace(workspace)
        let configured = Set(service.resources(workspace))
        let previousScope = preloadScope
        preloadScope = configured.intersection(included)
        if let selection { preloadScope.remove(selection) }
        pendingPreload.formIntersection(preloadScope)
        if detailPreloadTask != nil, previousScope != preloadScope { cancelPreload() }
        pendingPreload.formUnion(preloadScope.filter { resource in
            guard let entry = resources[resource], !entry.invalidated, let attempted = entry.lastAttempt else { return true }
            return attempted.duration(to: now()) >= .seconds(30)
        })
        guard detailPreloadTask == nil, !snapshotLoading, !suspended, active,
              !pendingPreload.isEmpty, cancellationDrain == nil else { return }
        let requested = pendingPreload
        let token = preloadGeneration
        runningPreload = requested
        detailPreloadTask = Task(priority: .utility) {
            let result = await service.inspect(workspace, excluding: selection, content: .workingTreeOnly, visibility: .application, concurrency: 2, including: requested) { @MainActor [weak self] snapshot in
                guard let self, !Task.isCancelled, self.preloadGeneration == token,
                      self.workspace?.root == workspace.root, self.preloadScope.contains(snapshot.resource) else { return }
                self.cache(snapshot)
                self.pendingPreload.remove(snapshot.resource)
            }
            guard !Task.isCancelled, preloadGeneration == token else { return }
            for resource in requested.intersection(pendingPreload).intersection(preloadScope) {
                let error = ModuError(result.reasonCode ?? "resource-unavailable", result.message ?? "Repository state is unavailable.", userMessage: result.userMessage)
                updateState(resource, changes: nil, error: error)
                pendingPreload.remove(resource)
            }
            detailPreloadTask = nil; runningPreload = []
            onIdle?()
        }
    }

    func cancelPreload() {
        let task = detailPreloadTask
        task?.cancel(); detailPreloadTask = nil; runningPreload = []; preloadGeneration += 1
        if let task { drainCancelledTask(task) }
    }

    func invalidate(resources affected: Set<Resource>) {
        for resource in affected { resources[resource, default: .init()].invalidated = true }
        pendingPreload.formUnion(affected.intersection(preloadScope))
        if !runningPreload.isDisjoint(with: affected) { cancelPreload() }
        if let selection, affected.contains(selection) {
            cancelCurrent()
            pendingChange = .structure
        }
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
        var next = detail
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
        resources[resource, default: .init()].lastCompleteDetail = next
        changesLoading = false; summaryLoading = false
        updateState(resource, changes: next.changes, error: next.changesError, invalidated: pendingChange != nil)
        if pendingChange == nil, let error = next.commitsError, next.summary?.baseOID != nil { onCommitsError?(error) }
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
        let key = HistoryKey(root: workspace.root, repository: resource.repo ?? "", head: summary.headOID, base: base)
        let cached = cachedHistory(key)
        let path = workspace.rootURL.appending(path: resource.path)
        async let ahead = readHistoryRange(at: path, head: summary.headOID, base: base, cached: cached?.ahead)
        async let behind = readHistoryRange(at: path, head: base, base: summary.headOID, cached: cached?.behind)
        let results = await (ahead, behind)
        guard isCurrent(token, resource: resource, root: workspace.root) else { return next }
        var history = cached ?? .init()
        switch results.0 {
        case .success(let commits):
            history.ahead = commits; next.commits = commits; next.commitsError = nil
        case .failure(let error): next.commits = nil; next.commitsError = error
        }
        switch results.1 {
        case .success(let commits):
            history.behind = commits; next.behindCommits = commits; next.comparisonError = nil
        case .failure(let error): next.behindCommits = nil; next.comparisonError = error
        }
        if history.ahead != nil || history.behind != nil { storeHistory(history, for: key) }
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
        if let selection { resources[selection, default: .init()].invalidated = true }
        guard active, !suspended else { return }
        let now = ContinuousClock.now
        if changeBurstStart == nil { changeBurstStart = now }
        let deadline = min(now.advanced(by: .milliseconds(150)), changeBurstStart!.advanced(by: .seconds(1)))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self else { return }
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

    private func cancelCurrent() {
        let task = detailTask
        task?.cancel()
        detailTask = nil; cancelPreload()
        generation += 1; readContext = nil
        stopMonitoring()
        changesLoading = false; summaryLoading = false
        finishDetail()
        if let task { drainCancelledTask(task) }
    }

    private func drainCancelledTask(_ task: Task<Void, Never>) {
        let previous = cancellationDrain
        let id = UUID(); drainID = id
        let drain = Task { [weak self] in
            await previous?.value
            await task.value
            guard let self, self.drainID == id else { return }
            self.cancellationDrain = nil
            self.onIdle?()
        }
        cancellationDrain = drain
    }

    private func isCurrent(_ token: Int, resource: Resource, root: String) -> Bool {
        !Task.isCancelled && generation == token && selection == resource && workspace?.root == root
    }

    private func cachedHistory(_ key: HistoryKey) -> HistoryCacheEntry? {
        guard var entry = histories[key] else { return nil }
        historyUse += 1; entry.lastUse = historyUse
        histories[key] = entry
        return entry
    }

    private func storeHistory(_ history: HistoryCacheEntry, for key: HistoryKey) {
        historyUse += 1
        var history = history; history.lastUse = historyUse
        histories[key] = history
        let family = histories.filter { $0.key.root == key.root && $0.key.repository == key.repository }
        if family.count > 2, let oldest = family.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            histories.removeValue(forKey: oldest)
        }
        if histories.count > 32, let oldest = histories.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            histories.removeValue(forKey: oldest)
        }
    }

    private func identities(in workspace: WorkspaceRecord?) -> [Resource: ResourceIdentity] {
        guard let workspace else { return [:] }
        let repositories = Dictionary(workspace.repositories.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(service.resources(workspace).map { resource in
            (resource, ResourceIdentity(repositoryURL: resource.repo.flatMap { repositories[$0] },
                                        groupCreatedAt: resource.group.flatMap { workspace.groups[$0]?.createdAt }))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func finishDetail() {
        let waiters = detailWaiters; detailWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    private func updateState(_ resource: Resource, changes: [FileChange]?, error: ModuError?, invalidated: Bool = false) {
        var entry = resources[resource] ?? .init()
        entry.state = ResourceState(resource: resource, available: error == nil, dirty: changes.map { !$0.isEmpty }, reason: error?.message, reasonMessage: error?.userMessage)
        entry.lastAttempt = now(); entry.invalidated = invalidated
        resources[resource] = entry
    }

    private struct ResourceCacheEntry {
        var state: ResourceState?
        var lastAttempt: ContinuousClock.Instant?
        var lastCompleteDetail: RepositoryDetailState?
        var invalidated = true
    }

    private struct ResourceIdentity: Equatable {
        let repositoryURL: String?
        let groupCreatedAt: String?
    }

    private struct HistoryKey: Hashable {
        let root: String
        let repository: String
        let head: String
        let base: String
    }

    private struct HistoryCacheEntry {
        var ahead: [GitCommit]?
        var behind: [GitCommit]?
        var lastUse = 0
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

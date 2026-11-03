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
    private let date: @MainActor () -> Date
    private let diskCache: (any RepositoryDetailCaching)?
    private let readSession: ResourceReadSession
    private let diagnostics: RepositoryReadDiagnostics?
    let presentationCache: RepositoryDetailPresentation
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
    private(set) var pendingFailure: RepositoryDetailFailure?
    private(set) var changesLoading = false
    private(set) var summaryLoading = false
    var hasActiveReads: Bool { detailTask != nil || detailPreloadTask != nil || snapshotPreloadTask != nil || eventFilterTask != nil || cancellationDrain != nil || monitoring || fallbackTask != nil }
    var needsCacheTermination: Bool { diskCache != nil }
    var snapshotLoading: Bool { changesLoading || summaryLoading }
    var detailLoading: Bool { detailTask != nil }
    func state(for resource: Resource) -> ResourceState? { resources[resource]?.state }

    private(set) var detailTask: Task<Void, Never>?
    private(set) var detailPreloadTask: Task<Void, Never>?
    private(set) var snapshotPreloadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var changeBurstStart: ContinuousClock.Instant?
    private var pendingChange: ResourceChange?
    private var revalidateConfiguration = false
    private var userInitiatedRefresh = false
    private var presentedFailure: RepositoryDetailFailure?
    private var pendingCandidates = Set<String>()
    private var eventFilterTask: Task<Void, Never>?
    private var cancellationDrain: Task<Void, Never>?
    private var drainID = UUID()
    private var generation = 0
    private var preloadGeneration = 0
    private var pendingPreload = Set<Resource>()
    private var preloadScope = Set<Resource>()
    private var runningPreload = Set<Resource>()
    private var visiblePreloadResources = Set<Resource>()
    private var configurationPreload = Set<Resource>()
    private var pendingSnapshots = Set<Resource>()
    private var runningSnapshot: Resource?
    private var snapshotPreloadGeneration = 0
    private var readContext: ResourceReadContext?
    private var monitoring = false
    private var suspended = false
    private var active = true
    private var detailWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var resources: [Resource: ResourceCacheEntry] = [:]
    private var histories: [RepositoryHistoryCacheKey: HistoryCacheEntry] = [:]
    private var pendingDetailInvalidations = Set<RepositoryCacheIdentity>()
    private var historyUse = 0
    private var clearedHistoryStates: [RepositoryCacheRepositoryIdentity: RepositoryHistoryCacheState] = [:]
    private var pendingSessionInvalidations = Set<Resource>()
    @ObservationIgnored var onIdle: (() -> Void)?
    private var collapsedPathsPreferenceKey: String? {
        guard let workspace, let selection else { return nil }
        return "detail.\(workspace.root).\(selection.id).collapsedPaths"
    }

    init(service: WorkspaceService, defaults: UserDefaults, monitor: any ResourceChangeMonitoring = ResourceChangeMonitor(),
         readCommits: (@Sendable (URL, String, String) async throws -> [GitCommit])? = nil,
         cache: (any RepositoryDetailCaching)? = nil,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, date: @escaping @MainActor () -> Date = { Date() },
         diagnostics: RepositoryReadDiagnostics? = nil) {
        self.service = service; self.defaults = defaults; self.monitor = monitor; self.now = now
        self.diskCache = cache; self.date = date; self.diagnostics = diagnostics
        readSession = ResourceReadSession(service: service, diagnostics: diagnostics)
        presentationCache = RepositoryDetailPresentation(diagnostics: diagnostics)
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
        let contextChanged = rootChanged || selection.map { previousIdentities[$0] != currentIdentities[$0] } == true
        if contextChanged { cancelCurrent(); pendingChange = selection == nil ? nil : .structure }
        else { cancelPreload() }
        if rootChanged {
            pendingSessionInvalidations.formUnion(resources.keys)
            resources = [:]; histories = [:]; clearedHistoryStates = [:]
            pendingPreload = []; preloadScope = []; visiblePreloadResources = []; configurationPreload = []
            pendingSnapshots = []
            clearDetail()
        } else {
            let configured = Set(currentIdentities.keys)
            for (resource, entry) in resources where !configured.contains(resource) || previousIdentities[resource] != currentIdentities[resource] {
                if let identity = entry.identity { pendingDetailInvalidations.insert(identity) }
                pendingSessionInvalidations.insert(resource)
                if preloadScope.contains(resource) { pendingPreload.insert(resource); pendingSnapshots.insert(resource) }
            }
            resources = resources.filter { configured.contains($0.key) && previousIdentities[$0.key] == currentIdentities[$0.key] }
            pendingPreload.formIntersection(configured)
            pendingSnapshots.formIntersection(configured)
            preloadScope.formIntersection(configured)
            if let selection, let current = currentIdentities[selection], current != previousIdentities[selection] { clearDetail() }
        }
        self.workspace = workspace
        if rootChanged { collapsedPaths = Set(collapsedPathsPreferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? []) }
        return contextChanged
    }

    func refresh(_ selection: Resource?, in workspace: WorkspaceRecord?, userInitiated: Bool = false) {
        let changedSelection = self.selection != selection
        applyWorkspace(workspace)
        if changedSelection {
            cancelCurrent()
            pendingChange = nil; revalidateConfiguration = false
            self.selection = selection
            let saved = selection.flatMap { resources[$0]?.lastSuccessfulDetail }
            if saved != nil { diagnostics?.record("detail.memory.hit") }
            detail = saved.map(RepositoryDetailState.init) ?? .init()
            collapsedPaths = Set(collapsedPathsPreferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
            updatePreloadScope(visiblePreloadResources)
        }
        guard let selection, let workspace else { onIdle?(); return }
        if changedSelection, !userInitiated, active, !suspended, hasRecentDetailAttempt(for: selection),
           resources[selection]?.lastSuccessfulDetail != nil, let context = resources[selection]?.detailContext,
           context.isValid(in: workspace) {
            readContext = context
            startMonitoring(context, token: generation)
            diagnostics?.record("detail.selection.hit")
            onIdle?()
            return
        }
        userInitiatedRefresh = userInitiatedRefresh || userInitiated
        diagnostics?.record("detail.request.refresh")
        request(.structure, revalidatingConfiguration: true)
    }

    func activate(_ selection: Resource?, in workspace: WorkspaceRecord?) {
        guard self.selection == selection, self.workspace == workspace else { refresh(selection, in: workspace); return }
        guard let selection else { return }
        if !pendingCandidates.isEmpty { scheduleEventFilter() }
        guard detailTask == nil else { diagnostics?.record("detail.activation.join"); return }
        if hasRecentDetailAttempt(for: selection) {
            diagnostics?.record("detail.activation.hit")
            return
        }
        diagnostics?.record("detail.request.activation")
        request(.structure, revalidatingConfiguration: true)
    }

    func request(_ change: ResourceChange, revalidatingConfiguration: Bool = false) {
        guard selection != nil, workspace != nil else { return }
        pendingChange = (pendingChange ?? []).union(change)
        revalidateConfiguration = revalidateConfiguration || revalidatingConfiguration
        if let selection { markInvalidated(selection) }
        cancelPreload()
        startRefresh()
    }

    func setActive(_ active: Bool, refresh: Bool = true) {
        let changed = self.active != active
        self.active = active
        if !active { debounceTask?.cancel(); debounceTask = nil; changeBurstStart = nil; cancelPreload() }
        else if changed && refresh { activate(selection, in: workspace) }
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
        await invalidateDiskDetails()
        await invalidateSessionReads()
    }

    func flushCache() async { await diskCache?.flush() }

    var failureForPresentation: RepositoryDetailFailure? {
        guard let failure = pendingFailure, active, !suspended, !detailLoading, pendingChange == nil,
              isCurrent(failure.generation, resource: failure.resource, root: failure.workspace) else { return nil }
        return failure
    }

    func takeFailureForPresentation() -> RepositoryDetailFailure? {
        guard let failure = failureForPresentation else { return nil }
        pendingFailure = nil
        resources[failure.resource, default: .init()].lastPresentedError = failure.signature
        presentedFailure = failure
        return failure
    }

    func dismissFailure() { presentedFailure = nil }

    func cache(_ state: ResourceState) {
        guard selection != state.resource else { return }
        if let previous = resources[state.resource]?.state,
           previous.available != state.available || previous.dirty != state.dirty {
            markDetailInvalidated(state.resource)
            if preloadScope.contains(state.resource) { pendingSnapshots.insert(state.resource) }
        }
        updateState(state)
    }

    func setPreloadScope(in workspace: WorkspaceRecord, including included: Set<Resource>) {
        applyWorkspace(workspace)
        updatePreloadScope(included)
    }

    func activatePreload(in workspace: WorkspaceRecord, including included: Set<Resource>) {
        setPreloadScope(in: workspace, including: included)
        enqueuePreload(preloadScope.subtracting(runningPreload), maximumAge: .seconds(10), revalidatingConfiguration: true)
        drainPreload()
    }

    private func updatePreloadScope(_ included: Set<Resource>) {
        guard let workspace else { return }
        visiblePreloadResources = included
        let previous = preloadScope
        preloadScope = Set(service.resources(workspace)).intersection(included)
        if let selection { preloadScope.remove(selection) }
        pendingPreload.formIntersection(preloadScope)
        pendingSnapshots.formIntersection(preloadScope)
        configurationPreload.formIntersection(preloadScope)
        if detailPreloadTask != nil, previous != preloadScope { cancelStatePreload() }
        if let runningSnapshot, !preloadScope.contains(runningSnapshot) { cancelSnapshotPreload() }
        let added = preloadScope.subtracting(previous)
        enqueuePreload(added, maximumAge: .seconds(30), revalidatingConfiguration: false)
        pendingSnapshots.formUnion(added.filter { resource in
            guard let entry = resources[resource], !entry.detailInvalidated, entry.identity?.isCurrent() != false,
                  entry.detailStatusIdentity == statusIdentity(for: resource), let attempted = entry.lastDetailAttempt else { return true }
            return attempted.duration(to: now()) >= .seconds(30)
        })
    }

    private func enqueuePreload(_ included: Set<Resource>, maximumAge: Duration, revalidatingConfiguration: Bool) {
        let needed = included.filter { resource in
            guard let entry = resources[resource], !entry.invalidated, entry.identity?.isCurrent() != false,
                  entry.statusIdentity == statusIdentity(for: resource), let attempted = entry.lastAttempt else { return true }
            return attempted.duration(to: now()) >= maximumAge
        }
        pendingPreload.formUnion(needed)
        if revalidatingConfiguration { configurationPreload.formUnion(needed) }
        if !needed.isEmpty { diagnostics?.record(revalidatingConfiguration ? "sidebar.request.activation" : "sidebar.request.scope", count: needed.count) }
    }

    func drainPreload() {
        guard let workspace, detailTask == nil, selection == nil || pendingChange == nil,
              detailPreloadTask == nil, !suspended, active else { return }
        let requested = pendingPreload.intersection(preloadScope)
        if !requested.isEmpty, snapshotPreloadTask != nil { cancelSnapshotPreload() }
        guard cancellationDrain == nil else { return }
        guard !requested.isEmpty else { startSnapshotPreload(in: workspace); return }
        let revalidate = !configurationPreload.isDisjoint(with: requested)
        diagnostics?.record("sidebar.read", count: requested.count)
        let token = preloadGeneration
        runningPreload = requested
        detailPreloadTask = Task(priority: .utility) {
            await invalidateSessionReads()
            guard !Task.isCancelled, preloadGeneration == token else { return }
            let result = await service.inspectStates(workspace, including: requested, concurrency: 4, session: readSession,
                                                     revalidateConfiguration: revalidate) { @MainActor [weak self] state in
                guard let self, !Task.isCancelled, self.preloadGeneration == token,
                      self.workspace?.root == workspace.root, self.preloadScope.contains(state.resource) else { return }
                self.cache(state)
                self.diagnostics?.record("sidebar.completed")
                self.pendingPreload.remove(state.resource)
                self.configurationPreload.remove(state.resource)
            }
            guard !Task.isCancelled, preloadGeneration == token else { return }
            for resource in requested.intersection(pendingPreload).intersection(preloadScope) {
                let error = ModuError(result.reasonCode ?? "resource-unavailable", result.message ?? "Repository state is unavailable.", userMessage: result.userMessage)
                updateState(resource, changes: nil, error: error)
                pendingPreload.remove(resource)
                configurationPreload.remove(resource)
            }
            detailPreloadTask = nil; runningPreload = []
            onIdle?()
        }
    }

    func cancelPreload() {
        cancelStatePreload()
        cancelSnapshotPreload()
    }

    private func cancelStatePreload() {
        let task = detailPreloadTask
        task?.cancel(); detailPreloadTask = nil; runningPreload = []; preloadGeneration += 1
        if let task { drainCancelledTask(task) }
    }

    private func cancelSnapshotPreload() {
        let task = snapshotPreloadTask
        task?.cancel(); snapshotPreloadTask = nil; runningSnapshot = nil; snapshotPreloadGeneration += 1
        if let task { drainCancelledTask(task) }
    }

    private func startSnapshotPreload(in workspace: WorkspaceRecord) {
        guard snapshotPreloadTask == nil, !pendingSnapshots.isDisjoint(with: preloadScope) else { return }
        let token = snapshotPreloadGeneration
        snapshotPreloadTask = Task(priority: .utility) {
            defer {
                if snapshotPreloadGeneration == token {
                    snapshotPreloadTask = nil; runningSnapshot = nil
                    onIdle?()
                }
            }
            await invalidateDiskDetails()
            await invalidateSessionReads()
            guard !Task.isCancelled, snapshotPreloadGeneration == token else { return }
            while let resource = pendingSnapshots.intersection(preloadScope).sorted(by: {
                let firstMissing = resources[$0]?.lastSuccessfulDetail == nil
                let secondMissing = resources[$1]?.lastSuccessfulDetail == nil
                return firstMissing == secondMissing ? $0.id < $1.id : firstMissing
            }).first {
                runningSnapshot = resource
                let revision = resources[resource]?.detailRevision ?? 0
                let valid = { self.isPreloading(token, resource: resource, root: workspace.root, revision: revision) }
                diagnostics?.record("detail.preload.read")
                guard var result = await readResourceDetail(resource, in: workspace, initial: .init(), change: .structure,
                                                           revalidatingConfiguration: true, isValid: valid), valid() else { return }
                if result.needsRefresh {
                    markDetailInvalidated(resource)
                    continue
                }
                if let saved = result.detail.successfulSnapshot(observedAt: date()), let identity = result.identity, identity.isCurrent() {
                    await diskCache?.saveDetail(saved, for: identity)
                    guard valid() else { return }
                    if identity.isCurrent() {
                        resources[resource, default: .init()].lastSuccessfulDetail = saved
                        resources[resource]?.lastPresentedError = nil
                    } else {
                        pendingDetailInvalidations.insert(identity)
                        resources[resource]?.lastSuccessfulDetail = nil
                        resources[resource]?.identity = nil
                        result.detail.changes = nil
                        result.detail.changesError = ModuError("repository-changed", "Repository identity changed while reading.")
                        await invalidateDiskDetails()
                        guard valid() else { return }
                    }
                }
                guard valid() else { return }
                await invalidateDiskDetails()
                guard valid() else { return }
                recordDetailAttempt(resource, context: result.context)
                updateState(resource, changes: result.detail.changes, error: result.detail.changesError)
                pendingSnapshots.remove(resource)
                diagnostics?.record("detail.preload.completed")
                runningSnapshot = nil
            }
        }
    }

    private func isPreloading(_ token: Int, resource: Resource, root: String, revision: Int) -> Bool {
        !Task.isCancelled && snapshotPreloadGeneration == token && workspace?.root == root && active && !suspended
            && selection != resource && preloadScope.contains(resource) && (resources[resource]?.detailRevision ?? 0) == revision
    }

    func invalidate(resources affected: Set<Resource>) {
        pendingSessionInvalidations.formUnion(affected)
        invalidateStates(resources: affected)
    }

    func invalidateStates(resources affected: Set<Resource>) {
        diagnostics?.record("reads.invalidated", count: affected.count)
        for resource in affected { markInvalidated(resource) }
        let visible = affected.intersection(preloadScope)
        pendingPreload.formUnion(visible)
        pendingSnapshots.formUnion(visible)
        configurationPreload.formUnion(visible)
        if !runningPreload.isDisjoint(with: affected) || runningSnapshot.map(affected.contains) == true { cancelPreload() }
        if let selection, affected.contains(selection) {
            cancelCurrent()
            pendingChange = .structure
            revalidateConfiguration = true
        }
    }

    private func startRefresh() {
        guard detailTask == nil, !suspended, active, pendingChange != nil, let selection, let workspace else { return }
        let token = generation
        changesLoading = true
        userInitiatedRefresh = userInitiatedRefresh || pendingFailure?.userInitiated == true
        pendingFailure = nil
        detailTask = Task(priority: .userInitiated) {
            await invalidateDiskDetails()
            await invalidateSessionReads()
            guard isCurrent(token, resource: selection, root: workspace.root) else { return }
            while active, !suspended, let change = pendingChange {
                pendingChange = nil
                let revalidate = revalidateConfiguration
                revalidateConfiguration = false
                changesLoading = true
                diagnostics?.record("detail.read")
                await readSnapshot(selection, in: workspace, change: change, revalidatingConfiguration: revalidate, token: token)
                guard isCurrent(token, resource: selection, root: workspace.root) else { return }
            }
            guard isCurrent(token, resource: selection, root: workspace.root) else { return }
            detailTask = nil; changesLoading = false; summaryLoading = false
            if pendingChange == nil { userInitiatedRefresh = false }
            finishDetail()
            onIdle?()
        }
    }

    private func readSnapshot(_ resource: Resource, in workspace: WorkspaceRecord, change: ResourceChange, revalidatingConfiguration: Bool, token: Int) async {
        let readStarted = ContinuousClock.now
        let revision = resources[resource]?.detailRevision ?? 0
        let valid = { self.isCurrent(token, resource: resource, root: workspace.root) }
        guard let result = await readResourceDetail(resource, in: workspace, initial: detail, change: change,
                                                   revalidatingConfiguration: revalidatingConfiguration, isValid: valid,
                                                   progress: { progress in
            switch progress {
            case .prepared(let context, let saved):
                if self.readContext == nil || !change.intersection([.structure, .index, .configuration]).isEmpty || revalidatingConfiguration {
                    self.stopMonitoring()
                }
                self.readContext = context
                self.detail = saved
                if !self.monitoring { self.startMonitoring(context, token: token) }
            case .statusRead: self.changesLoading = false
            case .readingSummary: self.summaryLoading = true
            case .summaryRead: self.summaryLoading = false
            }
        }), valid() else { return }
        let next = result.detail
        if result.context == nil {
            if result.discardsSavedDetail { clearDetail() }
            readContext = nil; stopMonitoring(); startFallback(token: token)
        }
        if result.needsRefresh {
            pendingChange = (pendingChange ?? []).union(.summary)
            markInvalidated(resource)
        }
        if revision == resources[resource]?.detailRevision {
            if let saved = next.successfulSnapshot(observedAt: date()), let identity = result.identity, identity.isCurrent() {
                resources[resource, default: .init()].lastSuccessfulDetail = saved
                detail = next
                pendingFailure = nil
                resources[resource]?.lastPresentedError = nil
                await diskCache?.saveDetail(saved, for: identity)
                guard valid() else { return }
            } else if let saved = resources[resource]?.lastSuccessfulDetail {
                detail = RepositoryDetailState(saved)
            } else {
                detail = next
            }
            if revision == resources[resource]?.detailRevision { recordDetailAttempt(resource, context: result.context) }
        }
        changesLoading = false; summaryLoading = false
        await invalidateDiskDetails()
        guard valid() else { return }
        updateState(resource, changes: next.changes, error: next.changesError, invalidated: pendingChange != nil)
        diagnostics?.record("detail.completed", duration: readStarted.duration(to: .now))
        if pendingChange == nil, let error = next.readError { enqueueFailure(error, resource: resource, root: workspace.root, token: token) }
        finishDetail()
    }

    private func readResourceDetail(_ resource: Resource, in workspace: WorkspaceRecord, initial: RepositoryDetailState,
                                    change: ResourceChange, revalidatingConfiguration: Bool, isValid: () -> Bool,
                                    progress: (DetailReadProgress) -> Void = { _ in }) async -> DetailReadResult? {
        guard isValid() else { return nil }
        var result = DetailReadResult(detail: initial)
        var statusRead = false
        do {
            let started = ContinuousClock.now
            let context = try await readSession.prepare(resource, in: workspace, visibility: .application,
                                                        revalidateConfiguration: revalidatingConfiguration || change.contains(.configuration))
            guard isValid() else { return nil }
            diagnostics?.record("detail.prepare", duration: started.duration(to: .now))
            let identity = try RepositoryCacheIdentity(context: context)
            result.identity = identity
            if resources[resource]?.identity != identity { resources[resource]?.lastPresentedError = nil }
            if let previous = resources[resource]?.identity, previous != identity {
                pendingDetailInvalidations.insert(previous)
                resources[resource]?.lastSuccessfulDetail = nil
                result.detail = .init()
                result.discardsSavedDetail = true
                await invalidateDiskDetails()
                guard isValid() else { return nil }
            }
            resources[resource, default: .init()].identity = identity
            if let saved = resources[resource]?.lastSuccessfulDetail {
                result.detail = RepositoryDetailState(saved)
            } else if let diskCache {
                let saved = await diskCache.loadDetail(for: identity)
                guard isValid() else { return nil }
                if let saved, identity.isCurrent() {
                    resources[resource, default: .init()].lastSuccessfulDetail = saved
                    result.detail = RepositoryDetailState(saved)
                }
            }
            progress(.prepared(context, result.detail))
            let statusStarted = ContinuousClock.now
            let state = try await service.workingState(context, visibility: .application)
            diagnostics?.record("detail.status", duration: statusStarted.duration(to: .now))
            guard isValid() else { return nil }
            let headChanged = result.detail.summary?.headOID != state.headOID || result.detail.summary?.head != state.head
            result.detail.changes = state.changes; result.detail.changesError = nil
            statusRead = true
            progress(.statusRead)
            if !change.intersection([.summary, .configuration, .structure]).isEmpty || headChanged || result.detail.summary == nil {
                progress(.readingSummary)
                let summaryStarted = ContinuousClock.now
                result.detail.summary = try await service.summary(context, workingState: state)
                diagnostics?.record("detail.summary", duration: summaryStarted.duration(to: .now))
                guard isValid() else { return nil }
                result.detail.summaryError = nil
            }
            progress(.summaryRead)
            let history = await readHistory(result.detail, context: context, identity: identity, isValid: isValid)
            guard isValid() else { return nil }
            guard identity.isCurrent() else { throw ModuError("repository-changed", "Repository identity changed while reading.") }
            result.detail = history.detail
            result.needsRefresh = history.needsRefresh
            result.context = context
        } catch {
            guard isValid() else { return nil }
            let error = ModuError.wrap(error)
            let path = workspace.rootURL.appending(path: resource.path)
            if error.code == "origin-mismatch" || resources[resource]?.identity?.isCurrent() == false
                || !PathSafety.exists(path) || !PathSafety.exists(path.appending(path: ".git")) {
                if let previous = resources[resource]?.identity { pendingDetailInvalidations.insert(previous) }
                resources[resource]?.lastSuccessfulDetail = nil
                resources[resource]?.identity = nil
                result.discardsSavedDetail = true
                result.detail.changes = nil; result.detail.changesError = error
            }
            if !statusRead { result.detail.changes = nil; result.detail.changesError = error }
            result.detail.summary = nil; result.detail.summaryError = error
            result.detail.commits = nil; result.detail.behindCommits = nil
            result.detail.commitsError = error; result.detail.comparisonError = nil
        }
        guard isValid() else { return nil }
        return result
    }

    private func enqueueFailure(_ error: ModuError, resource: Resource, root: String, token: Int) {
        let failure = RepositoryDetailFailure(workspace: root, resource: resource, generation: token,
                                              error: error, keepsPreviousResult: resources[resource]?.lastSuccessfulDetail != nil,
                                              userInitiated: userInitiatedRefresh)
        if let presentedFailure, presentedFailure.workspace == root, presentedFailure.resource == resource,
           presentedFailure.signature == failure.signature { return }
        guard userInitiatedRefresh || resources[resource]?.lastPresentedError != failure.signature else { return }
        pendingFailure = failure
    }

    private func readHistory(_ initial: RepositoryDetailState, context: ResourceReadContext, identity: RepositoryCacheIdentity, isValid: () -> Bool) async -> (detail: RepositoryDetailState, needsRefresh: Bool) {
        let started = ContinuousClock.now
        defer { diagnostics?.record("detail.history", duration: started.duration(to: .now)) }
        guard isValid() else { return (initial, false) }
        var next = initial
        var needsRefresh = false
        guard let summary = next.summary else { return (next, needsRefresh) }
        guard let base = summary.baseOID else {
            next.commits = summary.hasRemotes ? nil : []
            next.commitsError = summary.baseError.map { ModuError("base-unavailable", $0, userMessage: summary.baseMessage) }
            next.behindCommits = nil; next.comparisonError = nil
            return (next, needsRefresh)
        }
        let key = RepositoryHistoryCacheKey(repository: identity.repository, head: summary.headOID, base: base)
        do {
            let before = try await service.historyCacheState(context, session: readSession)
            guard isValid() else { return (next, needsRefresh) }
            if !before.reusable, clearedHistoryStates[identity.repository] != before {
                await invalidateHistory(for: identity.repository)
                guard isValid() else { return (next, needsRefresh) }
                clearedHistoryStates[identity.repository] = before
            }
            if before.reusable { clearedHistoryStates.removeValue(forKey: identity.repository) }
            var cached = before.reusable ? cachedHistory(key) : nil
            if cached == nil, before.reusable, let diskCache {
                let stored = await diskCache.loadHistory(for: key)
                guard isValid() else { return (next, needsRefresh) }
                if let stored { cached = .init(ahead: stored.ahead, behind: stored.behind) }
            }
            let cachedAhead = cached?.ahead, cachedBehind = cached?.behind
            let readMissingHistory = cachedAhead == nil || cachedBehind == nil
            async let ahead = readHistoryRange(at: context.path, head: summary.headOID, base: base, cached: cachedAhead)
            async let behind = readHistoryRange(at: context.path, head: base, base: summary.headOID, cached: cachedBehind)
            let results = await (ahead, behind)
            guard isValid() else { return (next, needsRefresh) }
            let after = try await service.historyCacheState(context, session: readSession)
            guard isValid() else { return (next, needsRefresh) }
            guard before == after else {
                await invalidateHistory(for: identity.repository)
                guard isValid() else { return (next, needsRefresh) }
                needsRefresh = true
                throw ModuError("repository-changed", "Repository history changed while reading.")
            }
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
            guard identity.isCurrent() else { throw ModuError("repository-changed", "Repository identity changed while reading.") }
            if after.reusable {
                if history.ahead != nil || history.behind != nil { storeHistory(history, for: key) }
                if readMissingHistory, let ahead = history.ahead, let behind = history.behind, let diskCache {
                    await diskCache.saveHistory(.init(ahead: ahead, behind: behind), for: key)
                    guard isValid() else { return (next, needsRefresh) }
                }
            }
        } catch {
            guard isValid() else { return (next, needsRefresh) }
            let error = ModuError.wrap(error)
            next.commits = nil; next.behindCommits = nil
            next.commitsError = error; next.comparisonError = error
        }
        return (next, needsRefresh)
    }

    private func invalidateHistory(for repository: RepositoryCacheRepositoryIdentity) async {
        histories = histories.filter { $0.key.repository != repository }
        await diskCache?.invalidateHistory(for: repository)
    }

    private func invalidateDiskDetails() async {
        guard let diskCache else { pendingDetailInvalidations = []; return }
        while let identity = pendingDetailInvalidations.first {
            await diskCache.invalidateDetail(for: identity)
            guard !Task.isCancelled else { return }
            pendingDetailInvalidations.remove(identity)
        }
    }

    private func invalidateSessionReads() async {
        let affected = pendingSessionInvalidations
        guard !affected.isEmpty else { return }
        await readSession.invalidate(resources: affected)
        if !Task.isCancelled { pendingSessionInvalidations.subtract(affected) }
    }

    private func clearDetail() {
        detail = .init()
    }

    private func readHistoryRange(at path: URL, head: String, base: String, cached: [GitCommit]?) async -> Result<[GitCommit], ModuError> {
        if let cached { return .success(cached) }
        do { return .success(try await readCommits(path, head, base)) }
        catch { return .failure(.wrap(error)) }
    }

    private func startMonitoring(_ context: ResourceReadContext, token: Int) {
        let excluded = context.resource.kind == .group ? (context.workspace.groups[context.resource.group ?? ""]?.repositories ?? []).map { context.workspace.memberURL(context.resource.group!, $0) } : []
        monitoring = monitor.start(context, excludedDirectories: excluded) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.suspended else { return }
                self.received(event)
            }
        }
        if monitoring { fallbackTask?.cancel(); fallbackTask = nil }
        else { startFallback(token: token) }
    }

    private func received(_ event: ResourceChangeEvent) {
        if !event.change.isEmpty {
            diagnostics?.record("detail.request.event")
            pendingCandidates = []
            cancelEventFilter()
            pendingChange = (pendingChange ?? []).union(event.change)
            if let selection { markInvalidated(selection) }
            guard active, !suspended else { return }
            if !event.change.intersection([.summary, .index, .configuration, .structure]).isEmpty {
                debounceTask?.cancel(); debounceTask = nil; changeBurstStart = nil
                cancelPreload(); startRefresh()
                return
            }
        } else {
            diagnostics?.record("events.candidates", count: event.candidatePaths.count)
            pendingCandidates.formUnion(event.candidatePaths)
            if pendingCandidates.count > ResourceChangeEvent.maximumCandidateCount
                || pendingCandidates.reduce(0, { $0 + $1.utf8.count + 1 }) > ResourceChangeEvent.maximumCandidateBytes {
                pendingCandidates = []
                pendingChange = (pendingChange ?? []).union(.workingTree)
                if let selection { markInvalidated(selection) }
            }
            guard active, !suspended else { return }
        }
        scheduleEventFilter()
    }

    private func scheduleEventFilter() {
        guard active, !suspended else { return }
        let instant = ContinuousClock.now
        if changeBurstStart == nil { changeBurstStart = instant }
        let deadline = min(instant.advanced(by: .milliseconds(150)), changeBurstStart!.advanced(by: .seconds(1)))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.changeBurstStart = nil; self.debounceTask = nil
            self.filterCandidateEvents()
        }
    }

    private func filterCandidateEvents() {
        guard eventFilterTask == nil, active, !suspended else { return }
        guard !pendingCandidates.isEmpty, let context = readContext else {
            if pendingChange != nil { cancelPreload(); startRefresh() }
            return
        }
        let candidates = pendingCandidates
        pendingCandidates = []
        let token = generation
        eventFilterTask = Task { [weak self] in
            guard let self else { return }
            let needsRefresh: Bool
            do {
                let ignored = try await service.git.ignoredPaths(Array(candidates), at: context.path)
                needsRefresh = !candidates.isSubset(of: ignored)
                diagnostics?.record("events.ignored", count: ignored.count)
            } catch {
                guard !Task.isCancelled else { return }
                needsRefresh = true
            }
            guard isCurrent(token, resource: context.resource, root: context.workspace.root) else { return }
            eventFilterTask = nil
            if needsRefresh { request(.workingTree) }
            else if pendingChange != nil { cancelPreload(); startRefresh() }
            if !pendingCandidates.isEmpty { filterCandidateEvents() }
        }
    }

    private func cancelEventFilter() {
        let task = eventFilterTask
        task?.cancel(); eventFilterTask = nil
        if let task { drainCancelledTask(task) }
    }

    private func startFallback(token: Int) {
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == token else { return }
                if self.active, !self.suspended {
                    self.diagnostics?.record("detail.request.fallback")
                    self.request(.structure)
                }
            }
        }
    }

    private func stopMonitoring() {
        monitor.stop(); monitoring = false
        fallbackTask?.cancel(); fallbackTask = nil
        debounceTask?.cancel(); debounceTask = nil; changeBurstStart = nil
        cancelEventFilter()
    }

    private func cancelCurrent() {
        pendingFailure = nil; userInitiatedRefresh = false
        if (!pendingCandidates.isEmpty || eventFilterTask != nil), let selection {
            markInvalidated(selection)
        }
        let task = detailTask
        task?.cancel()
        detailTask = nil; cancelPreload()
        generation += 1; readContext = nil; pendingCandidates = []
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

    private func cachedHistory(_ key: RepositoryHistoryCacheKey) -> HistoryCacheEntry? {
        guard var entry = histories[key] else { diagnostics?.record("history.memory.miss"); return nil }
        diagnostics?.record("history.memory.hit")
        historyUse += 1; entry.lastUse = historyUse
        histories[key] = entry
        return entry
    }

    private func storeHistory(_ history: HistoryCacheEntry, for key: RepositoryHistoryCacheKey) {
        historyUse += 1
        var history = history; history.lastUse = historyUse
        histories[key] = history
        let family = histories.filter { $0.key.repository == key.repository }
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
                                        groupCreatedAt: resource.group.flatMap { workspace.groups[$0]?.createdAt },
                                        groupRepositories: resource.kind == .group ? Set(workspace.groups[resource.group ?? ""]?.repositories ?? []) : nil))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func finishDetail() {
        let waiters = detailWaiters; detailWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    private func statusIdentity(for resource: Resource) -> [PathStamp]? {
        guard let workspace else { return nil }
        let path = workspace.rootURL.appending(path: resource.path)
        let main = resource.repo.map(workspace.repositoryURL) ?? workspace.rootURL
        return try? [path, path.appending(path: ".git"), main.appending(path: ".git")].map(PathStamp.init)
    }

    private func updateState(_ state: ResourceState, invalidated: Bool = false) {
        var entry = resources[state.resource] ?? .init()
        entry.state = state; entry.lastAttempt = now(); entry.invalidated = invalidated
        entry.statusIdentity = statusIdentity(for: state.resource)
        resources[state.resource] = entry
    }

    private func updateState(_ resource: Resource, changes: [FileChange]?, error: ModuError?, invalidated: Bool = false) {
        updateState(ResourceState(resource: resource, available: error == nil, dirty: changes.map { !$0.isEmpty },
                                  reason: error?.message, reasonMessage: error?.userMessage), invalidated: invalidated)
    }

    private func markInvalidated(_ resource: Resource) {
        resources[resource, default: .init()].invalidated = true
        markDetailInvalidated(resource)
    }

    private func markDetailInvalidated(_ resource: Resource) {
        resources[resource, default: .init()].detailInvalidated = true
        resources[resource, default: .init()].detailRevision += 1
    }

    private func hasRecentDetailAttempt(for resource: Resource) -> Bool {
        guard pendingChange == nil, let entry = resources[resource], !entry.detailInvalidated,
              entry.identity?.isCurrent() != false, entry.detailStatusIdentity == statusIdentity(for: resource),
              let attempted = entry.lastDetailAttempt else { return false }
        return attempted.duration(to: now()) < .seconds(10)
    }

    private func recordDetailAttempt(_ resource: Resource, context: ResourceReadContext?) {
        resources[resource, default: .init()].lastDetailAttempt = now()
        resources[resource, default: .init()].detailContext = context
        resources[resource, default: .init()].detailInvalidated = false
        resources[resource, default: .init()].detailStatusIdentity = statusIdentity(for: resource)
    }

    private struct DetailReadResult {
        var detail: RepositoryDetailState
        var context: ResourceReadContext?
        var identity: RepositoryCacheIdentity?
        var discardsSavedDetail = false
        var needsRefresh = false
    }

    private enum DetailReadProgress {
        case prepared(ResourceReadContext, RepositoryDetailState)
        case statusRead, readingSummary, summaryRead
    }

    private struct ResourceCacheEntry {
        var state: ResourceState?
        var lastAttempt: ContinuousClock.Instant?
        var lastDetailAttempt: ContinuousClock.Instant?
        var detailContext: ResourceReadContext?
        var detailStatusIdentity: [PathStamp]?
        var detailInvalidated = true
        var detailRevision = 0
        var statusIdentity: [PathStamp]?
        var lastSuccessfulDetail: RepositoryDetailSnapshot?
        var identity: RepositoryCacheIdentity?
        var invalidated = true
        var lastPresentedError: RepositoryDetailFailure.Signature?
    }

    private struct ResourceIdentity: Equatable {
        let repositoryURL: String?
        let groupCreatedAt: String?
        let groupRepositories: Set<String>?
    }

    private struct PathStamp: Equatable {
        let path: String
        let device: UInt64?
        let inode: UInt64?
        let contents: Data?

        init(_ url: URL) throws {
            path = PathSafety.canonical(url).path
            guard PathSafety.exists(url) else { device = nil; inode = nil; contents = nil; return }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            contents = attributes[.type] as? FileAttributeType == .typeRegular ? try Data(contentsOf: url) : nil
        }
    }

    private struct HistoryCacheEntry {
        var ahead: [GitCommit]?
        var behind: [GitCommit]?
        var lastUse = 0
    }
}

struct RepositoryDetailFailure: Identifiable {
    let id = UUID()
    let workspace: String
    let resource: Resource
    let generation: Int
    let error: ModuError
    let keepsPreviousResult: Bool
    let userInitiated: Bool
    var signature: Signature { .init(code: error.code, diagnostic: Git.sanitize(error.message)) }

    struct Signature: Equatable {
        let code: String
        let diagnostic: String
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

private extension RepositoryDetailState {
    init(_ snapshot: RepositoryDetailSnapshot) {
        summary = snapshot.summary; changes = snapshot.changes
        commits = snapshot.commits; behindCommits = snapshot.behindCommits
    }

    var readError: ModuError? {
        changesError ?? summaryError ?? commitsError ?? comparisonError
            ?? summary?.baseError.map { ModuError("base-unavailable", $0, userMessage: summary?.baseMessage) }
    }

    func successfulSnapshot(observedAt: Date) -> RepositoryDetailSnapshot? {
        guard readError == nil, let summary, let changes,
              !summary.hasRemotes || (summary.baseOID != nil && commits != nil && behindCommits != nil) else { return nil }
        return .init(summary: summary, changes: changes, commits: commits, behindCommits: behindCommits, observedAt: observedAt)
    }
}

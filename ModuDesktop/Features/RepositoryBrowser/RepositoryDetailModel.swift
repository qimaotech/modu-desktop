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
    var hasActiveReads: Bool { detailTask != nil || detailPreloadTask != nil || eventFilterTask != nil || cancellationDrain != nil || monitoring || fallbackTask != nil }
    var needsCacheTermination: Bool { diskCache != nil }
    var snapshotLoading: Bool { changesLoading || summaryLoading }
    var detailLoading: Bool { detailTask != nil }
    func state(for resource: Resource) -> ResourceState? { resources[resource]?.state }

    private(set) var detailTask: Task<Void, Never>?
    private(set) var detailPreloadTask: Task<Void, Never>?
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
            clearDetail()
        } else {
            let configured = Set(currentIdentities.keys)
            for (resource, entry) in resources where !configured.contains(resource) || previousIdentities[resource] != currentIdentities[resource] {
                if let identity = entry.identity { pendingDetailInvalidations.insert(identity) }
                pendingSessionInvalidations.insert(resource)
                if preloadScope.contains(resource) { pendingPreload.insert(resource) }
            }
            resources = resources.filter { configured.contains($0.key) && previousIdentities[$0.key] == currentIdentities[$0.key] }
            pendingPreload.formIntersection(configured)
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
            self.selection = selection
            let saved = selection.flatMap { resources[$0]?.lastSuccessfulDetail }
            if saved != nil { diagnostics?.record("detail.memory.hit") }
            detail = saved.map(RepositoryDetailState.init) ?? .init()
            collapsedPaths = Set(collapsedPathsPreferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
            updatePreloadScope(visiblePreloadResources)
        }
        guard selection != nil, workspace != nil else { onIdle?(); return }
        userInitiatedRefresh = userInitiatedRefresh || userInitiated
        diagnostics?.record("detail.request.refresh")
        request(.structure, revalidatingConfiguration: true)
    }

    func activate(_ selection: Resource?, in workspace: WorkspaceRecord?) {
        guard self.selection == selection, self.workspace == workspace else { refresh(selection, in: workspace); return }
        guard let selection else { return }
        if !pendingCandidates.isEmpty { scheduleEventFilter() }
        guard detailTask == nil else { diagnostics?.record("detail.activation.join"); return }
        let entry = resources[selection]
        let identityChanged = entry?.identity?.isCurrent() == false || entry?.statusIdentity != statusIdentity(for: selection)
        if pendingChange == nil, entry?.invalidated == false, !identityChanged,
           let attempted = entry?.lastDetailAttempt, attempted.duration(to: now()) < .seconds(10) {
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
        if let selection { resources[selection, default: .init()].invalidated = true }
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
        configurationPreload.formIntersection(preloadScope)
        if detailPreloadTask != nil, previous != preloadScope { cancelPreload() }
        enqueuePreload(preloadScope.subtracting(previous), maximumAge: .seconds(30), revalidatingConfiguration: false)
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
        guard let workspace, detailPreloadTask == nil, !snapshotLoading, !suspended, active,
              !pendingPreload.isEmpty, cancellationDrain == nil else { return }
        let requested = pendingPreload.intersection(preloadScope)
        guard !requested.isEmpty else { return }
        let revalidate = !configurationPreload.isDisjoint(with: requested)
        diagnostics?.record("sidebar.read", count: requested.count)
        let token = preloadGeneration
        runningPreload = requested
        detailPreloadTask = Task(priority: .utility) {
            await invalidateSessionReads()
            guard !Task.isCancelled, preloadGeneration == token else { return }
            let result = await service.inspectStates(workspace, including: requested, concurrency: 2, session: readSession,
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
        let task = detailPreloadTask
        task?.cancel(); detailPreloadTask = nil; runningPreload = []; preloadGeneration += 1
        if let task { drainCancelledTask(task) }
    }

    func invalidate(resources affected: Set<Resource>) {
        diagnostics?.record("reads.invalidated", count: affected.count)
        for resource in affected { resources[resource, default: .init()].invalidated = true }
        pendingSessionInvalidations.formUnion(affected)
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
        guard isCurrent(token, resource: resource, root: workspace.root) else { return }
        let readStarted = ContinuousClock.now
        var next = detail
        var identity: RepositoryCacheIdentity?
        do {
            let started = ContinuousClock.now
            let context = try await readSession.prepare(resource, in: workspace, visibility: .application,
                                                        revalidateConfiguration: revalidatingConfiguration || change.contains(.configuration))
            guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            diagnostics?.record("detail.prepare", duration: started.duration(to: .now))
            if readContext == nil || !change.intersection([.structure, .index, .configuration]).isEmpty || revalidatingConfiguration {
                stopMonitoring()
            }
            readContext = context
            let currentIdentity = try RepositoryCacheIdentity(context: context)
            identity = currentIdentity
            if resources[resource]?.identity != currentIdentity { resources[resource]?.lastPresentedError = nil }
            if let previous = resources[resource]?.identity, previous != currentIdentity {
                pendingDetailInvalidations.insert(previous)
                resources[resource]?.lastSuccessfulDetail = nil
                clearDetail()
                next = .init()
                await invalidateDiskDetails()
                guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            }
            resources[resource, default: .init()].identity = currentIdentity
            if resources[resource]?.lastSuccessfulDetail == nil, let diskCache {
                let saved = await diskCache.loadDetail(for: currentIdentity)
                guard isCurrent(token, resource: resource, root: workspace.root) else { return }
                if let saved {
                    resources[resource, default: .init()].lastSuccessfulDetail = saved
                    detail = RepositoryDetailState(saved)
                    next = detail
                }
            }
            if !monitoring { startMonitoring(context, token: token) }
            let statusStarted = ContinuousClock.now
            let state = try await service.workingState(context, visibility: .application)
            diagnostics?.record("detail.status", duration: statusStarted.duration(to: .now))
            guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            let headChanged = next.summary?.headOID != state.headOID || next.summary?.head != state.head
            next.changes = state.changes; next.changesError = nil
            changesLoading = false
            if !change.intersection([.summary, .configuration, .structure]).isEmpty || headChanged || next.summary == nil {
                summaryLoading = true
                let summaryStarted = ContinuousClock.now
                next.summary = try await service.summary(context, workingState: state)
                diagnostics?.record("detail.summary", duration: summaryStarted.duration(to: .now))
                guard isCurrent(token, resource: resource, root: workspace.root) else { return }
                next.summaryError = nil
            }
            summaryLoading = false
            if pendingChange == nil { onIdle?() }
            next = await readHistory(next, context: context, identity: currentIdentity, token: token)
        } catch {
            guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            let error = ModuError.wrap(error)
            let path = workspace.rootURL.appending(path: resource.path)
            if error.code == "origin-mismatch" || resources[resource]?.identity?.isCurrent() == false
                || !PathSafety.exists(path) || !PathSafety.exists(path.appending(path: ".git")) {
                if let previous = resources[resource]?.identity { pendingDetailInvalidations.insert(previous) }
                resources[resource]?.lastSuccessfulDetail = nil
                resources[resource]?.identity = nil
                clearDetail()
            }
            if changesLoading { next.changes = nil; next.changesError = error }
            next.summary = nil; next.summaryError = error
            next.commits = nil; next.behindCommits = nil; next.commitsError = error; next.comparisonError = nil
            readContext = nil; stopMonitoring(); startFallback(token: token)
        }
        guard isCurrent(token, resource: resource, root: workspace.root) else { return }
        let error = next.readError
        if let saved = next.successfulSnapshot(observedAt: date()) {
            resources[resource, default: .init()].lastSuccessfulDetail = saved
            detail = next
            pendingFailure = nil
            resources[resource]?.lastPresentedError = nil
            if let diskCache, let identity {
                await diskCache.saveDetail(saved, for: identity)
                guard isCurrent(token, resource: resource, root: workspace.root) else { return }
            }
        } else if let saved = resources[resource]?.lastSuccessfulDetail {
            detail = RepositoryDetailState(saved)
        } else {
            detail = next
        }
        changesLoading = false; summaryLoading = false
        await invalidateDiskDetails()
        guard isCurrent(token, resource: resource, root: workspace.root) else { return }
        resources[resource, default: .init()].lastDetailAttempt = now()
        updateState(resource, changes: next.changes, error: next.changesError, invalidated: pendingChange != nil)
        diagnostics?.record("detail.completed", duration: readStarted.duration(to: .now))
        if pendingChange == nil, let error { enqueueFailure(error, resource: resource, root: workspace.root, token: token) }
        finishDetail()
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

    private func readHistory(_ initial: RepositoryDetailState, context: ResourceReadContext, identity: RepositoryCacheIdentity, token: Int) async -> RepositoryDetailState {
        let started = ContinuousClock.now
        defer { diagnostics?.record("detail.history", duration: started.duration(to: .now)) }
        let resource = context.resource, root = context.workspace.root
        guard isCurrent(token, resource: resource, root: root) else { return initial }
        var next = initial
        guard let summary = next.summary else { return next }
        guard let base = summary.baseOID else {
            next.commits = summary.hasRemotes ? nil : []
            next.commitsError = summary.baseError.map { ModuError("base-unavailable", $0, userMessage: summary.baseMessage) }
            next.behindCommits = nil; next.comparisonError = nil
            return next
        }
        let key = RepositoryHistoryCacheKey(repository: identity.repository, head: summary.headOID, base: base)
        do {
            let before = try await service.historyCacheState(context, session: readSession)
            guard isCurrent(token, resource: resource, root: root) else { return next }
            if !before.reusable, clearedHistoryStates[identity.repository] != before {
                await invalidateHistory(for: identity.repository)
                clearedHistoryStates[identity.repository] = before
                guard isCurrent(token, resource: resource, root: root) else { return next }
            }
            if before.reusable { clearedHistoryStates.removeValue(forKey: identity.repository) }
            var cached = before.reusable ? cachedHistory(key) : nil
            if cached == nil, before.reusable, let diskCache {
                let stored = await diskCache.loadHistory(for: key)
                guard isCurrent(token, resource: resource, root: root) else { return next }
                if let stored { cached = .init(ahead: stored.ahead, behind: stored.behind) }
            }
            let cachedAhead = cached?.ahead, cachedBehind = cached?.behind
            let readMissingHistory = cachedAhead == nil || cachedBehind == nil
            async let ahead = readHistoryRange(at: context.path, head: summary.headOID, base: base, cached: cachedAhead)
            async let behind = readHistoryRange(at: context.path, head: base, base: summary.headOID, cached: cachedBehind)
            let results = await (ahead, behind)
            guard isCurrent(token, resource: resource, root: root) else { return next }
            let after = try await service.historyCacheState(context, session: readSession)
            guard isCurrent(token, resource: resource, root: root) else { return next }
            guard before == after else {
                await invalidateHistory(for: identity.repository)
                guard isCurrent(token, resource: resource, root: root) else { return next }
                pendingChange = (pendingChange ?? []).union(.summary)
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
            if after.reusable {
                if history.ahead != nil || history.behind != nil { storeHistory(history, for: key) }
                if readMissingHistory, let ahead = history.ahead, let behind = history.behind, let diskCache {
                    await diskCache.saveHistory(.init(ahead: ahead, behind: behind), for: key)
                    guard isCurrent(token, resource: resource, root: root) else { return next }
                }
            }
        } catch {
            guard isCurrent(token, resource: resource, root: root) else { return next }
            let error = ModuError.wrap(error)
            next.commits = nil; next.behindCommits = nil
            next.commitsError = error; next.comparisonError = error
        }
        return next
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
            if let selection { resources[selection, default: .init()].invalidated = true }
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
                if let selection { resources[selection, default: .init()].invalidated = true }
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
            resources[selection, default: .init()].invalidated = true
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

    private struct ResourceCacheEntry {
        var state: ResourceState?
        var lastAttempt: ContinuousClock.Instant?
        var lastDetailAttempt: ContinuousClock.Instant?
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

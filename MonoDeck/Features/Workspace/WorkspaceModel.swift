import Foundation
import MonoDeckCore
import Observation

@MainActor @Observable
final class WorkspaceModel {
    private let service: WorkspaceService
    private let installer: InstallationService
    private let preferences: AppPreferences
    private let operations: OperationLifecycle
    private let presentation: OperationPresentation
    private let recordMonitor: any WorkspaceRecordChangeMonitoring
    private let now: @MainActor () -> ContinuousClock.Instant
    private let waitForRecordDebounce: @MainActor (ContinuousClock.Instant) async throws -> Void
    private var lastRecordActivation: (path: String, completedAt: ContinuousClock.Instant)?
    private var active = true
    private var recordWatchRoot: String?
    private var recordWatchID = UUID()
    private var recordMonitoring = false
    private var recordWatchNeedsRestart = false
    private var recordDebounceTask: Task<Void, Never>?
    private var recordBurstStart: ContinuousClock.Instant?
    private var sidebarResources = Set<Resource>()
    private var recordContextChanged = false
    private struct RefreshIntent: OptionSet {
        let rawValue: Int
        static let record = Self(rawValue: 1)
        static let current = Self(rawValue: 2)
        static let sidebar = Self(rawValue: 4)
        static let all: Self = [.record, .current, .sidebar]
    }
    let details: RepositoryDetailModel
    enum MaintenanceState { case pending, maintaining, ready, failed }
    var maintenanceState: MaintenanceState = .ready
    private(set) var maintenanceFailure: OperationResult?
    private(set) var maintenanceFailurePending = false
    @ObservationIgnored var onMaintenanceFailure: (() -> Void)?
    var canManage: Bool { record != nil && readsAllowed && maintenanceState == .ready && !busy && !presentation.quitPending }
    enum MaintenanceTrigger { case startup, manual }
    var hasActiveReads: Bool { details.hasActiveReads || reloadTask != nil }
    var needsReadTermination: Bool { hasActiveReads || recordMonitoring || recordDebounceTask != nil || details.needsCacheTermination }
    private var readsAllowed = true
    private struct MaintenanceOptions {
        var showProgress: Bool
        var cancellable: Bool

        init(showProgress: Bool, cancellable: Bool) { self.showProgress = showProgress; self.cancellable = cancellable }
        init(_ trigger: MaintenanceTrigger) {
            showProgress = trigger == .manual
            // The toolbar hides cancellation; startup still needs it for quit and workspace switches.
            cancellable = trigger == .startup
        }
    }
    @MainActor private final class ReloadCompletion {
        var afterLoad: (() -> Void)?
        var continuation: CheckedContinuation<Void, Never>?

        init(_ afterLoad: (() -> Void)?) { self.afterLoad = afterLoad }
        func apply() { let action = afterLoad; afterLoad = nil; action?() }
        func finish() {
            afterLoad = nil
            let waiter = continuation; continuation = nil
            waiter?.resume()
        }
    }
    @MainActor private final class ReloadBatch {
        let path: String
        var maintenance: MaintenanceOptions?
        var completions: [ReloadCompletion]
        var operationID: Int?
        var result: OperationResult?
        var intent: RefreshIntent
        var recordActivation = false

        init(path: String, maintenance: MaintenanceOptions?, intent: RefreshIntent, completion: ReloadCompletion? = nil) {
            self.path = path; self.maintenance = maintenance; self.intent = intent; completions = completion.map { [$0] } ?? []
        }
        func merge(_ request: ReloadBatch) {
            intent.formUnion(request.intent)
            recordActivation = recordActivation || request.recordActivation
            if let options = request.maintenance {
                if let current = maintenance {
                    maintenance = .init(showProgress: current.showProgress || options.showProgress, cancellable: current.cancellable && options.cancellable)
                } else { maintenance = options }
            }
            completions += request.completions
        }
        func finish() { for completion in completions { completion.finish() }; completions = [] }
    }
    private var pendingReload: ReloadBatch?
    private var activeReload: ReloadBatch?
    private var reloadTask: (generation: Int, task: Task<Void, Never>)?
    private var reloadStopped = false
    private var switchingGeneration: Int?
    private var cancelledReload: Task<Void, Never>?
    @ObservationIgnored var onContextChange: ((Bool) -> Void)?
    var record: WorkspaceRecord? {
        didSet { applyRecord(previous: oldValue) }
    }

    var blocked: String?
    var blockedDetails: String?
    var notice: String?
    var noticeDetails: String?
    var selection: Resource? {
        didSet {
            if record != nil, let data = try? JSONEncoder().encode(selection) {
                // An explicit nil distinguishes the home page from a workspace without saved navigation.
                defaults.set(data, forKey: sidebarPreferenceKey("selection"))
            }
            if oldValue != selection { onContextChange?(false); refreshDetail() }
        }
    }
    var expandedGroups = Set<String>() {
        didSet {
            guard record != nil else { return }
            let key = sidebarPreferenceKey("expandedGroups")
            let expanded = expandedGroups.sorted()
            if defaults.stringArray(forKey: key) != expanded { defaults.set(expanded, forKey: key) }
        }
    }
    var showsReloadProgress: Bool { activeReload?.maintenance?.showProgress ?? true }
    var isReloading: Bool { activeReload?.maintenance != nil }
    private var refreshGeneration = 0
    private var defaults: UserDefaults { preferences.defaults }
    private var busy: Bool { operations.busy }
    func state(for resource: Resource) -> ResourceState? { details.state(for: resource) }
    var detail: RepositoryDetailState { details.detail }
    var detailLoading: Bool { details.detailLoading }
    var detailPreloadTask: Task<Void, Never>? { details.detailPreloadTask }
    var sortedRepositories: [Repository] { record?.repositories.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } ?? [] }
    var sortedGroups: [String] { record?.groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? [] }
    var currentURL: URL? {
        guard let record else { return nil }
        if let selection { return try? PathSafety.child(selection.path, of: record.rootURL, allowMissing: false) }
        return record.rootURL
    }

    var text: InterfaceText { preferences.text }

    init(service: WorkspaceService, installer: InstallationService, preferences: AppPreferences, operations: OperationLifecycle, presentation: OperationPresentation,
         cache: (any RepositoryDetailCaching)? = nil,
         recordMonitor: any WorkspaceRecordChangeMonitoring = WorkspaceRecordChangeMonitor(),
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         waitForRecordDebounce: (@MainActor (ContinuousClock.Instant) async throws -> Void)? = nil,
         diagnostics: RepositoryReadDiagnostics? = nil) {
        self.service = service
        self.installer = installer
        self.preferences = preferences
        self.operations = operations
        self.presentation = presentation
        self.recordMonitor = recordMonitor
        self.now = now
        self.waitForRecordDebounce = waitForRecordDebounce ?? { deadline in
            try await Task.sleep(until: deadline, clock: .continuous)
        }
        details = RepositoryDetailModel(service: service, defaults: preferences.defaults, cache: cache, now: now, diagnostics: diagnostics)
        details.onIdle = { [weak self] in self?.startDetailPreload() }
    }

    func sidebarPreferenceKey(_ name: String) -> String { "sidebar.\(record?.root ?? defaults.string(forKey: "workspace") ?? "").\(name)" }

    var visibleResources: [Resource] {
        sortedRepositories.map { .repository($0.id) } + sortedGroups.flatMap { group in
            [Resource.group(group)] + (expandedGroups.contains(group) ? sortedRepositories.filter { record?.groups[group]?.repositories.contains($0.id) == true }.map { .member(group, $0.id) } : [])
        }
    }
    func selectSidebarRow(_ resource: Resource) {
        let wasSelected = selection == resource
        selection = resource
        if resource.kind == .group, let group = resource.group {
            if wasSelected { toggleGroup(group) }
            else { expandedGroups.insert(group) }
        }
    }
    func toggleGroup(_ group: String) {
        if expandedGroups.remove(group) != nil {
            if selection?.group == group { selection = .group(group) }
        } else { expandedGroups.insert(group) }
    }
    func restoreForStartup(_ root: URL) async throws {
        maintenanceState = .pending
        let token = refreshGeneration
        let saved = try await service.read(root)
        try Task.checkCancellation()
        guard token == refreshGeneration, defaults.string(forKey: "workspace") == root.path else { throw CancellationError() }
        readsAllowed = true
        let previousSelection = selection
        record = saved; blocked = nil; blockedDetails = nil
        if selection == previousSelection { refreshDetail() }
    }

    func refreshRecord(refreshingSidebar: Bool = true, afterLoad: (() -> Void)? = nil) async {
        await requestReload(maintenance: nil, intent: refreshingSidebar ? .all : [.record, .current], afterLoad: afterLoad)
    }

    func maintainWorkspace(_ trigger: MaintenanceTrigger = .manual) async {
        if trigger == .manual { presentation.completionMessage = nil }
        await requestReload(maintenance: MaintenanceOptions(trigger), intent: .all)
    }

    func showMaintenanceFailure() {
        guard maintenanceState == .failed, let maintenanceFailure else { return }
        maintenanceFailurePending = false
        presentation.presentMaintenanceFailure(maintenanceFailure)
    }

    private func requestReload(maintenance: MaintenanceOptions?, intent: RefreshIntent, afterLoad: (() -> Void)? = nil, wait: Bool = true,
                               recordActivation: Bool = false) async {
        guard !Task.isCancelled, !presentation.quitPending, let path = defaults.string(forKey: "workspace") else { return }
        let completion = ReloadCompletion(afterLoad)
        let request = ReloadBatch(path: path, maintenance: maintenance, intent: intent, completion: completion)
        request.recordActivation = recordActivation
        let waitsForBatch = wait && (active || maintenance != nil) && (!busy || activeReload?.operationID.map(operations.isCurrent) == true)
        if waitsForBatch {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(); return }
                    completion.continuation = continuation
                    enqueueReload(request)
                    startPendingReloadIfPossible()
                }
            } onCancel: {
                Task { @MainActor in completion.finish() }
            }
        } else {
            enqueueReload(request)
            startPendingReloadIfPossible()
        }
    }

    private func enqueueReload(_ request: ReloadBatch) {
        if request.recordActivation, let active = activeReload, active.recordActivation, active.maintenance == nil,
           active.path == request.path, reloadTask?.generation == refreshGeneration,
           reloadTask?.task.isCancelled == false {
            active.completions += request.completions
            return
        }
        if request.maintenance != nil, let active = activeReload, active.maintenance != nil,
           active.path == request.path, reloadTask?.generation == refreshGeneration,
           reloadTask?.task.isCancelled == false {
            active.completions += request.completions
            return
        }
        if let pending = pendingReload, pending.path == request.path { pending.merge(request) }
        else {
            pendingReload?.finish()
            pendingReload = request
        }
    }

    private func startPendingReloadIfPossible() {
        guard reloadTask == nil, !reloadStopped, switchingGeneration == nil, !busy, !presentation.quitPending,
              let pending = pendingReload, active || pending.maintenance != nil else { return }
        guard defaults.string(forKey: "workspace") == pending.path else {
            pending.finish(); pendingReload = nil
            return
        }
        if pending.maintenance != nil || pending.intent != .record { cancelDetailPreload() }
        ensureRecordMonitoring()
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task(priority: .utility) { await runReloads(generation: generation) }
        reloadTask = (generation, task)
    }

    private func runReloads(generation: Int) async {
        defer { finishReloads(generation: generation) }
        while generation == refreshGeneration, !Task.isCancelled, !reloadStopped, !busy, !presentation.quitPending,
              let batch = pendingReload, (active || batch.maintenance != nil), defaults.string(forKey: "workspace") == batch.path {
            activeReload = batch
            if let options = batch.maintenance {
                guard let operationID = operations.begin(.workspace, cancellable: options.cancellable) else {
                    activeReload = nil
                    return
                }
                batch.operationID = operationID
                maintenanceState = .maintaining
                operations.attach(reloadTask?.task, to: operationID)
            }
            pendingReload = nil
            await loadWorkspace(batch, generation: generation)
            if batch.maintenance != nil, reloadTask?.generation == generation,
               defaults.string(forKey: "workspace") == batch.path, maintenanceState == .maintaining {
                maintenanceState = .failed
                notice = text.message(MonoDeckError("cancelled", .operationCancelled))
            }
            if activeReload === batch { activeReload = nil }
            if let operationID = batch.operationID { operations.finish(operationID) }
            finishMaintenance(batch, generation: generation)
            batch.finish()
            resumeReadsIfAllowed()
            if batch.operationID != nil, presentation.quitPending { presentation.finishQuitIfPossible() }
        }
    }

    private func finishMaintenance(_ batch: ReloadBatch, generation: Int) {
        guard batch.maintenance != nil, reloadTask?.generation == generation,
              defaults.string(forKey: "workspace") == batch.path, maintenanceState == .failed else { return }
        let error = MonoDeckError("cancelled", .operationCancelled)
        var result = batch.result ?? OperationResult(command: "workspace.open", workspace: batch.path,
            items: [ItemResult(.workspace(), status: .cancelled, error: error)], error: error)
        if Task.isCancelled, result.status == .success { result.summarize(cancelled: true) }
        maintenanceFailure = result
        maintenanceFailurePending = !presentation.quitPending && (result.status != .cancelled || result.items.contains { !$0.effects.isEmpty })
        onMaintenanceFailure?()
    }

    private func finishReloads(generation: Int) {
        guard reloadTask?.generation == generation else { return }
        reloadTask = nil
        startPendingReloadIfPossible()
        resumeReadsIfAllowed()
    }

    private func resumeReadsIfAllowed() {
        guard !reloadStopped, switchingGeneration == nil, !busy, !presentation.quitPending, readsAllowed,
              maintenanceState != .maintaining, pendingReload?.maintenance == nil,
              pendingReload?.intent.contains(.current) != true, activeReload?.intent.contains(.current) != true else { return }
        details.resume()
        startDetailPreload()
    }

    private func isCurrent(_ batch: ReloadBatch, generation: Int) -> Bool {
        generation == refreshGeneration && activeReload === batch && defaults.string(forKey: "workspace") == batch.path
    }

    private func loadWorkspace(_ batch: ReloadBatch, generation: Int) async {
        let path = batch.path
        let maintainingWorkspace = batch.maintenance != nil
        defer {
            if batch.recordActivation, isCurrent(batch, generation: generation), !Task.isCancelled, !presentation.quitPending,
               batch.result?.status != .cancelled, !busy || batch.operationID.map(operations.isCurrent) == true {
                lastRecordActivation = (path, now())
            }
        }
        do {
            let root = URL(fileURLWithPath: path)
            guard let record = try await recordForReload(root, batch: batch, generation: generation) else { return }
            guard isCurrent(batch, generation: generation), !Task.isCancelled, !presentation.quitPending,
                  !busy || batch.operationID.map(operations.isCurrent) == true else { return }
            let previousSelection = selection
            if !readsAllowed, !maintainingWorkspace { notice = nil; noticeDetails = nil }
            self.record = record; blocked = nil; blockedDetails = nil
            let contextChanged = recordContextChanged
            if maintainingWorkspace {
                maintenanceState = .ready
                maintenanceFailure = nil; maintenanceFailurePending = false
            }
            readsAllowed = true
            for completion in batch.completions {
                guard isCurrent(batch, generation: generation), !Task.isCancelled, !presentation.quitPending else { return }
                completion.apply()
            }
            guard isCurrent(batch, generation: generation), !Task.isCancelled, !presentation.quitPending,
                  !busy || batch.operationID.map(operations.isCurrent) == true else { return }
            if batch.recordActivation, let current = self.record, current.root == path {
                details.activatePreload(in: current, including: sidebarResources)
            }
            if selection == previousSelection, contextChanged || batch.intent.contains(.current) { refreshDetail() }
            if batch.intent.contains(.sidebar) { details.invalidateStates(resources: sidebarResources.subtracting(selection.map { [$0] } ?? [])) }
        } catch {
            guard isCurrent(batch, generation: generation), !Task.isCancelled, !presentation.quitPending,
                  !busy || batch.operationID.map(operations.isCurrent) == true else { return }
            if maintainingWorkspace { maintenanceState = .failed }
            if record?.root == path {
                notice = text.message(error); noticeDetails = Git.sanitize(error.localizedDescription)
                readsAllowed = false
                details.pause()
                if maintainingWorkspace, let actual = try? await service.read(URL(fileURLWithPath: path)) {
                    guard isCurrent(batch, generation: generation), !Task.isCancelled, !presentation.quitPending else { return }
                    self.record = actual
                    readsAllowed = true
                    refreshDetail()
                }
                return
            }
            if maintainingWorkspace { notice = nil; noticeDetails = nil }
            record = nil; selection = nil; blocked = text.message(error); blockedDetails = Git.sanitize(error.localizedDescription)
        }
    }
    private func recordForReload(_ root: URL, batch: ReloadBatch, generation: Int) async throws -> WorkspaceRecord? {
        guard let operationID = batch.operationID else {
            let record = try await service.read(root)
            if !readsAllowed || batch.intent != .record || record != self.record { try await service.git.checkRepository(root, main: true) }
            else { try PathSafety.directory(root.appending(path: ".git")) }
            return record
        }
        await waitForReadCancellation()
        let report: ProgressHandler = { value in Task { @MainActor [self] in
            guard self.refreshGeneration == generation, self.operations.isCurrent(operationID) else { return }
            self.operations.report(value, for: operationID)
        } }
        let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "mono-deck-workflow")
        let opened = await service.openWorkspaceWithRecord(root, skill: skill, installer: installer, requireExistingRecord: true, progress: report)
        batch.result = opened.result
        guard isCurrent(batch, generation: generation) else { return nil }
        let noEffects = opened.result.items.allSatisfy { $0.effects.isEmpty }
        if presentation.quitPending {
            presentation.result = noEffects ? nil : opened.result
            presentation.resultHost = .main
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard opened.result.status == .success, let record = opened.record else {
            let code = opened.result.reasonCode ?? opened.result.items.first?.reasonCode ?? "workspace-unavailable"
            let overall = opened.result.userMessage.map { [$0] } ?? opened.result.message.map { [UserMessage.diagnostic($0)] } ?? []
            let items = opened.result.items.compactMap { item in item.userMessage ?? item.message.map(UserMessage.diagnostic) }
            throw MonoDeckError(code, .joined(overall + items, separator: "\n"))
        }
        let skillFailure = opened.skillError ?? (skill == nil ? MonoDeckError("skill-unavailable", .bundledSkillIsUnavailable) : nil)
        noticeDetails = skillFailure.map { Git.sanitize($0.message) }
        notice = skillFailure.map {
            text.string(.uiWorkflowSkillWasnTEnabled2(presentation.text.message($0)))
        }
        return record
    }
    func switchTo(_ root: URL, loaded: WorkspaceRecord? = nil, waitingFor previousEdit: Task<Void, Never>? = nil) async throws {
        cancelDetailPreload()
        let previous = reloadTask?.task
        previous?.cancel()
        activeReload?.finish(); pendingReload?.finish()
        refreshGeneration += 1; let token = refreshGeneration
        switchingGeneration = token
        defer {
            if switchingGeneration == token {
                switchingGeneration = nil
                startPendingReloadIfPossible()
                resumeReadsIfAllowed()
            }
        }
        await previousEdit?.value
        await previous?.value
        try Task.checkCancellation()
        let record: WorkspaceRecord
        if let loaded { record = loaded }
        else {
            record = try await service.load(root)
            try await service.git.checkRepository(record.rootURL, main: true)
        }
        try Task.checkCancellation()
        guard token == refreshGeneration, !presentation.quitPending else { throw CancellationError() }
        pendingReload?.finish()
        pendingReload = nil
        defaults.set(record.root, forKey: "workspace")
        lastRecordActivation = nil
        let previousSelection = selection
        self.record = record; blocked = nil; notice = nil
        maintenanceFailure = nil; maintenanceFailurePending = false
        maintenanceState = .ready; readsAllowed = true
        reloadStopped = false
        ensureRecordMonitoring()
        if selection == previousSelection { refreshDetail() }
    }
    func refreshDetail(userInitiated: Bool = false) { details.refresh(selection, in: record, userInitiated: userInitiated) }

    func setActive(_ active: Bool, refresh: Bool = true) {
        self.active = active
        details.setActive(active, refresh: refresh)
        if active { startPendingReloadIfPossible(); resumeReadsIfAllowed() }
    }

    func activate() async {
        setActive(true, refresh: false)
        details.activate(selection, in: record)
        if let lastRecordActivation, lastRecordActivation.path == defaults.string(forKey: "workspace"),
           lastRecordActivation.completedAt.duration(to: now()) < .seconds(10) {
            if let record { details.activatePreload(in: record, including: sidebarResources) }
            return
        }
        await requestReload(maintenance: nil, intent: .record, wait: !busy, recordActivation: true)
    }

    func operationsChanged(_ busy: Bool) {
        if busy {
            details.pause()
            if activeReload?.maintenance == nil, let load = reloadTask {
                let interrupted = activeReload
                cancelledReload = load.task; load.task.cancel(); refreshGeneration += 1
                activeReload?.finish(); pendingReload?.finish()
                if let interrupted, !reloadStopped, switchingGeneration == nil, !presentation.quitPending,
                   defaults.string(forKey: "workspace") == interrupted.path {
                    // The cancelled task still owns its batch; only its refresh intent survives.
                    let retry = ReloadBatch(path: interrupted.path, maintenance: nil, intent: interrupted.intent)
                    retry.recordActivation = interrupted.recordActivation
                    enqueueReload(retry)
                }
            }
        } else {
            Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                self.startPendingReloadIfPossible()
                self.resumeReadsIfAllowed()
            }
        }
    }

    func waitForReadCancellation() async {
        let reload = cancelledReload
        await details.waitForReads()
        await reload?.value
    }

    func stopReads() async {
        reloadStopped = true
        stopRecordMonitoring()
        details.stop()
        let load = reloadTask?.task
        load?.cancel()
        activeReload?.finish(); pendingReload?.finish()
        if pendingReload?.maintenance == nil { pendingReload = nil }
        await waitForReadCancellation()
        await load?.value
        await details.flushCache()
    }

    func resumeAfterFailedQuit() {
        guard !busy, !presentation.quitPending else { return }
        reloadStopped = false
        ensureRecordMonitoring()
        startPendingReloadIfPossible()
        guard pendingReload?.maintenance == nil else { return }
        if readsAllowed, maintenanceState != .maintaining { refreshDetail() }
        resumeReadsIfAllowed()
    }
    func invalidateReads(cancelReload: Bool = false) {
        cancelDetailPreload()
        if cancelReload { reloadTask?.task.cancel() }
        activeReload?.finish(); pendingReload?.finish()
        refreshGeneration += 1
    }

    func startDetailPreload() {
        guard reloadTask == nil, !reloadStopped, switchingGeneration == nil, !busy, !presentation.quitPending,
              record != nil else { return }
        guard readsAllowed, pendingReload?.maintenance == nil, !details.snapshotLoading,
              maintenanceState != .pending && maintenanceState != .maintaining else { return }
        details.drainPreload()
    }

    func setVisibleResources(_ resources: Set<Resource>, in root: String) {
        guard let record, record.root == root else { return }
        sidebarResources = resources.intersection(service.resources(record))
        details.setPreloadScope(in: record, including: sidebarResources)
        startDetailPreload()
    }

    private func ensureRecordMonitoring() {
        guard !reloadStopped, !presentation.quitPending, let root = record?.root ?? defaults.string(forKey: "workspace") else { return }
        guard recordWatchRoot != root || !recordMonitoring || recordWatchNeedsRestart else { return }
        // Rebinding must not discard an event whose refresh has not entered the queue yet.
        if recordWatchRoot == root, recordDebounceTask != nil { return }
        stopRecordMonitoring()
        recordWatchRoot = root
        let id = recordWatchID
        recordMonitoring = recordMonitor.start(service.store.recordURL(URL(fileURLWithPath: root))) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.recordWatchID == id, !self.reloadStopped, !self.presentation.quitPending else { return }
                self.receivedRecordChange()
            }
        }
    }

    private func receivedRecordChange() {
        recordWatchNeedsRestart = true
        let now = ContinuousClock.now
        if recordBurstStart == nil { recordBurstStart = now }
        let deadline = min(now.advanced(by: .milliseconds(150)), recordBurstStart!.advanced(by: .seconds(1)))
        recordDebounceTask?.cancel()
        let watchID = recordWatchID
        let wait = waitForRecordDebounce
        recordDebounceTask = Task { [weak self] in
            do { try await wait(deadline) } catch { return }
            guard !Task.isCancelled, let self, self.recordWatchID == watchID,
                  !self.reloadStopped, !self.presentation.quitPending else { return }
            self.recordDebounceTask = nil; self.recordBurstStart = nil
            await self.requestReload(maintenance: nil, intent: .record, wait: false)
        }
    }

    private func stopRecordMonitoring() {
        recordMonitor.stop(); recordMonitoring = false; recordWatchNeedsRestart = false
        recordWatchRoot = nil; recordWatchID = UUID()
        recordDebounceTask?.cancel(); recordDebounceTask = nil; recordBurstStart = nil
    }

    func invalidateResources(after outcome: OperationResult) {
        guard let record else { return }
        let changed = outcome.items.filter { !$0.effects.isEmpty }.map(\.resource)
        let repositories = Set(changed.compactMap(\.repo))
        let workspaceGitChanged = changed.contains { $0.repo == nil }
        let affected = Set(service.resources(record).filter { resource in
            resource.repo.map(repositories.contains) ?? workspaceGitChanged
        })
        details.invalidate(resources: affected)
    }

    func cancelDetailPreload() { details.cancelPreload() }

    private func applyRecord(previous: WorkspaceRecord?) {
        let rootChanged = previous?.root != record?.root
        recordContextChanged = details.applyWorkspace(record)
        if rootChanged {
            onContextChange?(true)
            sidebarResources = []
        }
        guard let record else { return }
        let groups = Set(record.groups.keys)
        var expanded = expandedGroups
        let previousGroups: Set<String>
        if rootChanged {
            let savedExpanded = defaults.stringArray(forKey: sidebarPreferenceKey("expandedGroups"))
            expanded = Set(savedExpanded ?? [])
            // Legacy preferences lack the seen-group list; preserve their existing collapsed state.
            previousGroups = defaults.stringArray(forKey: sidebarPreferenceKey("knownGroups")).map { Set($0) }
                ?? (savedExpanded == nil ? [] : groups)
        } else {
            previousGroups = Set(previous?.groups.keys ?? [:].keys)
        }
        expandedGroups = expanded.union(groups.subtracting(previousGroups)).intersection(groups)
        defaults.set(groups.sorted(), forKey: sidebarPreferenceKey("knownGroups"))
        if rootChanged { restoreSelection(in: record) }
        else if let selection, !service.resources(record).contains(selection) { self.selection = nil }
        ensureRecordMonitoring()
    }

    private func restoreSelection(in record: WorkspaceRecord) {
        let saved = defaults.data(forKey: sidebarPreferenceKey("selection")).flatMap { try? JSONDecoder().decode(Resource.self, from: $0) }
        selection = saved.flatMap { service.resources(record).contains($0) ? $0 : nil }
    }

}

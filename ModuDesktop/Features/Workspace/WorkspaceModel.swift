import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class WorkspaceModel {
    private let service: WorkspaceService
    private let installer: InstallationService
    private let preferences: AppPreferences
    private let operations: OperationLifecycle
    private let presentation: OperationPresentation
    let details: RepositoryDetailModel
    enum MaintenanceState { case pending, maintaining, ready, failed }
    var maintenanceState: MaintenanceState = .ready
    var canManage: Bool { record != nil && maintenanceState == .ready && !busy && !presentation.quitPending }
    var needsReadTermination: Bool { details.hasActiveReads || workspaceLoad != nil }
    private var readsAllowed = true
    private var recordRefreshPending = false
    private struct MaintenanceRequest {
        let path: String
        var showProgress: Bool
        var cancellable: Bool
    }
    private var pendingMaintenance: MaintenanceRequest?
    private var backgroundNeedsRefresh = false
    private var drainingReads: [Task<Void, Never>] = []
    @ObservationIgnored var onContextChange: ((Bool) -> Void)?
    var record: WorkspaceRecord? {
        didSet {
            let rootChanged = oldValue?.root != record?.root
            if rootChanged { onContextChange?(true) }
            guard let record else { return }
            let resources = Set(service.resources(record).map(\.id))
            states = states.filter { resources.contains($0.key) }
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
                previousGroups = Set(oldValue?.groups.keys ?? [:].keys)
            }
            expandedGroups = expanded.union(groups.subtracting(previousGroups)).intersection(groups)
            defaults.set(groups.sorted(), forKey: sidebarPreferenceKey("knownGroups"))
            if rootChanged { restoreSelection(in: record) }
        }
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
    private(set) var showsReloadProgress = true
    private(set) var isReloading = false
    private var workspaceLoad: (path: String, generation: Int, maintainingWorkspace: Bool, task: Task<Void, Never>)?
    private var refreshGeneration = 0
    private var defaults: UserDefaults { preferences.defaults }
    private var busy: Bool { operations.busy }
    var states: [String: ResourceState] {
        get { details.states }
        set { details.states = newValue }
    }
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

    init(service: WorkspaceService, installer: InstallationService, preferences: AppPreferences, operations: OperationLifecycle, presentation: OperationPresentation) {
        self.service = service
        self.installer = installer
        self.preferences = preferences
        self.operations = operations
        self.presentation = presentation
        details = RepositoryDetailModel(service: service, defaults: preferences.defaults)
        details.onIdle = { [weak self] in self?.startDetailPreload() }
        details.onCommitsError = { [weak self] error in
            guard let self, !self.presentation.quitPending else { return }
            self.presentation.presentMessage(Git.sanitize(error.message), title: self.text.string(.uiCanTReadCommits))
        }
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

    func reload() async {
        presentation.completionMessage = nil
        await reload(maintainingWorkspace: true, afterLoad: nil)
    }
    func reload(showProgress: Bool = true, maintainingWorkspace: Bool = false, cancellable: Bool = false, afterLoad: (() -> Void)?) async {
        guard !presentation.quitPending, let path = defaults.string(forKey: "workspace") else { return }
        if pendingMaintenance?.path != path { pendingMaintenance = nil }
        let currentLoad = workspaceLoad.flatMap { $0.path == path && $0.generation == refreshGeneration ? $0 : nil }
        if maintainingWorkspace, currentLoad?.maintainingWorkspace != true || pendingMaintenance != nil {
            if var pending = pendingMaintenance {
                // Explicit reloads stay visible and noncancellable when merged with startup maintenance.
                pending.showProgress = pending.showProgress || showProgress
                pending.cancellable = pending.cancellable && cancellable
                pendingMaintenance = pending
            } else { pendingMaintenance = MaintenanceRequest(path: path, showProgress: showProgress, cancellable: cancellable) }
        }
        let maintainWorkspace = maintainingWorkspace || pendingMaintenance != nil
        if let load = workspaceLoad, load.path == path, load.generation == refreshGeneration {
            if !maintainWorkspace {
                recordRefreshPending = true
                await load.task.value
                if recordRefreshPending, !busy, !presentation.quitPending, load.generation == refreshGeneration,
                   defaults.string(forKey: "workspace") == path {
                    if workspaceLoad?.generation == load.generation { workspaceLoad = nil }
                    await reload(showProgress: showProgress, afterLoad: afterLoad)
                }
                return
            }
            await load.task.value
            guard !Task.isCancelled, !presentation.quitPending, defaults.string(forKey: "workspace") == path else { return }
            if load.maintainingWorkspace { return }
            if workspaceLoad?.generation == load.generation { workspaceLoad = nil }
        }
        guard !busy else { recordRefreshPending = true; return }
        let previous = workspaceLoad?.task
        previous?.cancel()
        cancelDetailPreload()
        refreshGeneration += 1; let generation = refreshGeneration
        let task = Task(priority: .utility) {
            await previous?.value
            var maintain = maintainWorkspace
            var completion = afterLoad
            repeat {
                recordRefreshPending = false
                guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
                let options = maintain ? pendingMaintenance : nil
                await loadWorkspace(path, generation: generation, showProgress: options?.showProgress ?? showProgress, maintainingWorkspace: maintain, cancellable: options?.cancellable ?? cancellable, afterLoad: completion)
                completion = nil
                maintain = false
            } while recordRefreshPending && !presentation.quitPending
        }
        workspaceLoad = (path, generation, maintainWorkspace, task)
        await task.value
        if task.isCancelled, maintenanceState == .maintaining, !presentation.quitPending {
            maintenanceState = .failed
            notice = text.message(ModuError("cancelled", .operationCancelled))
            details.resume()
        }
        if workspaceLoad?.generation == generation {
            workspaceLoad = nil
            if pendingMaintenance != nil, !busy, !presentation.quitPending { await reload(showProgress: false, afterLoad: nil) }
            else { startDetailPreload() }
        }
    }
    private func loadWorkspace(_ path: String, generation: Int, showProgress: Bool, maintainingWorkspace: Bool, cancellable: Bool, afterLoad: (() -> Void)?) async {
        do {
            let root = URL(fileURLWithPath: path)
            if maintainingWorkspace { maintenanceState = .maintaining }
            guard let record = try await recordForReload(root, generation: generation, showProgress: showProgress, maintainingWorkspace: maintainingWorkspace, cancellable: cancellable) else { return }
            guard generation == refreshGeneration, !busy, !Task.isCancelled, !presentation.quitPending else { return }
            let recordChanged = self.record != record
            if recordChanged { invalidateDetailCache() }
            let previousSelection = selection
            self.record = record; blocked = nil; blockedDetails = nil
            if maintainingWorkspace { maintenanceState = .ready }
            readsAllowed = true
            afterLoad?()
            if let selection, !service.resources(record).contains(selection) { self.selection = nil }
            if selection == previousSelection, recordChanged || !details.snapshotLoading { refreshDetail() }
            backgroundNeedsRefresh = true
            details.resume()
        } catch {
            guard generation == refreshGeneration, !busy, !Task.isCancelled, !presentation.quitPending else { return }
            if record != nil, maintainingWorkspace || maintenanceState == .failed {
                maintenanceState = .failed
                notice = text.message(error); noticeDetails = Git.sanitize(error.localizedDescription)
                if let actual = try? await service.read(URL(fileURLWithPath: path)) {
                    guard generation == refreshGeneration, !Task.isCancelled, !presentation.quitPending else { return }
                    let retained = selection.map { ($0, self.record, detail) }
                    if self.record != actual { invalidateDetailCache() }
                    self.record = actual
                    if let selected = selection, !service.resources(actual).contains(selected) { selection = nil }
                    if let (resource, previous, savedDetail) = retained, let previous,
                       canRestoreDetail(resource, from: previous, in: actual) { details.restore(savedDetail, for: resource) }
                    readsAllowed = true
                    refreshDetail(); details.resume()
                } else {
                    readsAllowed = false
                    drainingReads += details.pause()
                }
                return
            }
            invalidateDetailCache()
            record = nil; selection = nil; blocked = text.message(error); blockedDetails = Git.sanitize(error.localizedDescription)
        }
    }
    private func recordForReload(_ root: URL, generation: Int, showProgress: Bool, maintainingWorkspace: Bool, cancellable: Bool) async throws -> WorkspaceRecord? {
        if !maintainingWorkspace {
            let record = try await service.read(root)
            try await service.git.checkRepository(root, main: true)
            return record
        }
        showsReloadProgress = showProgress
        guard let operationID = operations.begin(.workspace, cancellable: cancellable) else { return nil }
        if pendingMaintenance?.path == root.path { pendingMaintenance = nil }
        isReloading = true
        operations.attach(workspaceLoad?.task, to: operationID)
        defer {
            isReloading = false
            operations.finish(operationID)
            showsReloadProgress = true
        }
        await waitForReadCancellation()
        let report: ProgressHandler = { value in Task { @MainActor [self] in
            guard self.refreshGeneration == generation, self.operations.isCurrent(operationID) else { return }
            self.operations.report(value, for: operationID)
        } }
        let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "modu-workflow")
        let opened = await service.openWorkspaceWithRecord(root, skill: skill, installer: installer, requireExistingRecord: true, progress: report)
        guard generation == refreshGeneration else { return nil }
        let noEffects = opened.result.items.allSatisfy { $0.effects.isEmpty }
        if presentation.quitPending || ((opened.result.status != .success || Task.isCancelled) && !noEffects) {
            presentation.result = opened.result; presentation.resultHost = .main
        }
        if presentation.quitPending {
            if noEffects { presentation.result = nil; operations.finish(operationID); presentation.finishQuitIfPossible() }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard opened.result.status == .success, let record = opened.record else {
            let code = opened.result.reasonCode ?? opened.result.items.first?.reasonCode ?? "workspace-unavailable"
            let overall = opened.result.userMessage.map { [$0] } ?? opened.result.message.map { [UserMessage.diagnostic($0)] } ?? []
            let items = opened.result.items.compactMap { item in item.userMessage ?? item.message.map(UserMessage.diagnostic) }
            throw ModuError(code, .joined(overall + items, separator: "\n"))
        }
        let skillFailure = opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", .bundledSkillIsUnavailable) : nil)
        noticeDetails = skillFailure.map { Git.sanitize($0.message) }
        notice = skillFailure.map {
            text.string(.uiWorkflowSkillWasnTEnabled2(presentation.text.message($0)))
        }
        return record
    }
    func switchTo(_ root: URL, loaded: WorkspaceRecord? = nil, waitingFor previousEdit: Task<Void, Never>? = nil) async throws {
        cancelDetailPreload()
        let previous = workspaceLoad?.task
        previous?.cancel()
        refreshGeneration += 1; let token = refreshGeneration
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
        guard token == refreshGeneration else { throw CancellationError() }
        invalidateDetailCache()
        pendingMaintenance = nil; recordRefreshPending = false
        defaults.set(record.root, forKey: "workspace")
        let previousSelection = selection
        self.record = record; blocked = nil; notice = nil
        states = [:]; maintenanceState = .ready; readsAllowed = true
        if selection == previousSelection { refreshDetail() }
    }
    func refreshDetail() { details.refresh(selection, in: record) }

    func activate() async {
        details.setActive(true)
        backgroundNeedsRefresh = true
        if busy { recordRefreshPending = true; return }
        await reload(showProgress: false, afterLoad: nil)
    }

    func operationsChanged(_ busy: Bool) {
        if busy {
            drainingReads += details.pause()
            if let load = workspaceLoad, !load.maintainingWorkspace {
                drainingReads.append(load.task); load.task.cancel(); refreshGeneration += 1
            }
        } else {
            Task { [weak self] in
                await Task.yield()
                guard let self, !self.busy, !self.presentation.quitPending else { return }
                if self.readsAllowed, self.maintenanceState != .maintaining { self.details.resume() }
                if self.recordRefreshPending || self.pendingMaintenance != nil, self.workspaceLoad == nil {
                    await self.reload(showProgress: false, afterLoad: nil)
                }
                self.startDetailPreload()
            }
        }
    }

    func waitForReadCancellation() async {
        let tasks = drainingReads; drainingReads = []
        for task in tasks { await task.value }
    }

    func stopReads() async {
        drainingReads += details.stop()
        let load = workspaceLoad?.task
        load?.cancel()
        await waitForReadCancellation()
        await load?.value
    }

    func resumeAfterFailedQuit() {
        guard !busy, !presentation.quitPending else { return }
        if pendingMaintenance != nil {
            Task { await reload(showProgress: false, afterLoad: nil) }
            return
        }
        guard readsAllowed, maintenanceState != .maintaining else { return }
        details.resume()
        refreshDetail()
        startDetailPreload()
    }
    func invalidateReads(cancelReload: Bool = false) {
        cancelDetailPreload()
        if cancelReload { workspaceLoad?.task.cancel() }
        refreshGeneration += 1
    }

    func startDetailPreload() {
        guard workspaceLoad == nil, !busy, !presentation.quitPending, let record else { return }
        guard readsAllowed, pendingMaintenance == nil, !details.snapshotLoading, maintenanceState != .pending && maintenanceState != .maintaining else { return }
        details.preload(in: record, force: backgroundNeedsRefresh)
        backgroundNeedsRefresh = false
    }

    func cancelDetailPreload() { details.cancelPreload() }
    func invalidateDetailCache() { details.invalidate() }

    func canRestoreDetail(_ resource: Resource, from previous: WorkspaceRecord, in current: WorkspaceRecord) -> Bool {
        guard previous.root == current.root, service.resources(current).contains(resource) else { return false }
        if let repo = resource.repo, previous.repositories.first(where: { $0.id == repo })?.url != current.repositories.first(where: { $0.id == repo })?.url { return false }
        if let group = resource.group, previous.groups[group]?.createdAt != current.groups[group]?.createdAt { return false }
        return true
    }

    private func restoreSelection(in record: WorkspaceRecord) {
        let saved = defaults.data(forKey: sidebarPreferenceKey("selection")).flatMap { try? JSONDecoder().decode(Resource.self, from: $0) }
        selection = saved.flatMap { service.resources(record).contains($0) ? $0 : nil }
    }

}

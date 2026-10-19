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
    @ObservationIgnored var onContextChange: ((Bool) -> Void)?
    var record: WorkspaceRecord? {
        didSet {
            let rootChanged = oldValue?.root != record?.root
            if rootChanged { onContextChange?(true) }
            guard let record else { return }
            if rootChanged {
                expandedGroups = Set(defaults.stringArray(forKey: sidebarPreferenceKey("expandedGroups")) ?? [])
            }
            expandedGroups.formIntersection(record.groups.keys)
        }
    }
    var blocked: String?
    var waiting = false
    var notice: String?
    var selection: Resource? {
        didSet {
            if oldValue != selection { onContextChange?(false); refreshDetail() }
        }
    }
    var expandedGroups = Set<String>() {
        didSet {
            guard record != nil, expandedGroups != oldValue else { return }
            defaults.set(expandedGroups.sorted(), forKey: sidebarPreferenceKey("expandedGroups"))
        }
    }
    private(set) var showsReloadProgress = true
    private var workspaceLoad: (path: String, generation: Int, task: Task<Void, Never>)?
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

    init(service: WorkspaceService, installer: InstallationService, preferences: AppPreferences, operations: OperationLifecycle, presentation: OperationPresentation) {
        self.service = service
        self.installer = installer
        self.preferences = preferences
        self.operations = operations
        self.presentation = presentation
        details = RepositoryDetailModel(service: service)
        details.onIdle = { [weak self] in self?.startDetailPreload() }
    }

    func sidebarPreferenceKey(_ name: String) -> String { "sidebar.\(record?.root ?? defaults.string(forKey: "workspace") ?? "").\(name)" }
    private func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

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
    func reload() async {
        presentation.completionMessage = nil
        await reload(afterLoad: nil)
    }
    func reload(showProgress: Bool = true, afterLoad: (() -> Void)?) async {
        guard !presentation.quitPending, let path = defaults.string(forKey: "workspace") else { return }
        if let load = workspaceLoad, load.path == path, load.generation == refreshGeneration {
            await load.task.value
            return
        }
        guard !busy else { return }
        let previous = workspaceLoad?.task
        previous?.cancel()
        cancelDetailPreload()
        refreshGeneration += 1; let generation = refreshGeneration
        waiting = false
        let task = Task(priority: .utility) {
            // Release the previous read's workspace lock before starting another generation.
            await previous?.value
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            await loadWorkspace(path, generation: generation, showProgress: showProgress, afterLoad: afterLoad)
        }
        workspaceLoad = (path, generation, task)
        await task.value
        if workspaceLoad?.generation == generation { workspaceLoad = nil; startDetailPreload() }
    }
    private func loadWorkspace(_ path: String, generation: Int, showProgress: Bool, afterLoad: (() -> Void)?) async {
        do {
            let root = URL(fileURLWithPath: path)
            guard let record = try await initializeForReload(root, generation: generation, showProgress: showProgress) else { return }
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            if self.record != record { invalidateDetailCache() }
            self.record = record; blocked = nil
            let previousSelection = selection
            afterLoad?()
            if let selection, !service.resources(record).contains(selection) { self.selection = nil }
            if selection == previousSelection { refreshDetail() }
            while detailLoading, let task = details.detailTask {
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            }
            let inspection = await service.inspect(record, excluding: selection) { @MainActor [self] snapshot in
                guard generation == refreshGeneration, !busy, !Task.isCancelled, self.record == record else { return }
                details.cache(snapshot)
            }
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            if inspection.reasonCode == "workspace-busy" { waiting = true; cancelDetailPreload(); return }
            let resourceIDs = Set(service.resources(record).map(\.id))
            var states = self.states.filter { resourceIDs.contains($0.key) }
            for item in inspection.items {
                if item.resource == selection, detail.changes != nil || detail.changesError != nil { continue }
                states[item.resource.id] = ResourceState(resource: item.resource, available: item.status == .success, dirty: item.data?["working-tree"].map { $0 == "dirty" }, reason: item.message)
            }
            self.states = states
        } catch {
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            if (error as? ModuError)?.code == "workspace-busy" { waiting = true; blocked = nil; return }
            invalidateDetailCache()
            record = nil; selection = nil; blocked = error.localizedDescription
        }
    }
    private func initializeForReload(_ root: URL, generation: Int, showProgress: Bool) async throws -> WorkspaceRecord? {
        showsReloadProgress = showProgress
        guard let operationID = operations.begin(.workspace) else { return nil }
        operations.attach(workspaceLoad?.task, to: operationID)
        defer {
            operations.finish(operationID)
            showsReloadProgress = true
        }
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
            let message = ([opened.result.message].compactMap { $0 } + opened.result.items.compactMap(\.message)).joined(separator: "\n")
            throw ModuError(code, message)
        }
        notice = (opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", "Bundled skill is unavailable.") : nil)).map {
            t("Workflow skill wasn’t enabled. ", "工作流技能未启用。") + $0.localizedDescription
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
        defaults.set(record.root, forKey: "workspace")
        self.record = record; blocked = nil; waiting = false; notice = nil
        states = [:]
        selection = nil; refreshDetail()
    }
    func refreshDetail() { details.refresh(selection, in: record) }
    func loadMore() { details.loadMore() }

    func invalidateReads(cancelReload: Bool = false) {
        cancelDetailPreload()
        if cancelReload { workspaceLoad?.task.cancel() }
        refreshGeneration += 1
    }

    func startDetailPreload() {
        guard workspaceLoad == nil, !waiting, !busy, let record else { return }
        details.preload(in: record)
    }

    func cancelDetailPreload() { details.cancelPreload() }
    func invalidateDetailCache() { details.invalidate() }

    func canRestoreDetail(_ resource: Resource, from previous: WorkspaceRecord, in current: WorkspaceRecord) -> Bool {
        guard previous.root == current.root, service.resources(current).contains(resource) else { return false }
        if let repo = resource.repo, previous.repositories.first(where: { $0.id == repo })?.url != current.repositories.first(where: { $0.id == repo })?.url { return false }
        if let group = resource.group, previous.groups[group]?.createdAt != current.groups[group]?.createdAt { return false }
        return true
    }

}

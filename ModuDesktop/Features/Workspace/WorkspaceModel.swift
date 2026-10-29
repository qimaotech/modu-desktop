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
        }
    }
    var blocked: String?
    var blockedDetails: String?
    var notice: String?
    var noticeDetails: String?
    var selection: Resource? {
        didSet {
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
        details = RepositoryDetailModel(service: service)
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
    func reload() async {
        presentation.completionMessage = nil
        await reload(maintainingWorkspace: true, afterLoad: nil)
    }
    func reload(showProgress: Bool = true, maintainingWorkspace: Bool = false, afterLoad: (() -> Void)?) async {
        guard !presentation.quitPending, let path = defaults.string(forKey: "workspace") else { return }
        if let load = workspaceLoad, load.path == path, load.generation == refreshGeneration {
            await load.task.value
            guard !Task.isCancelled, !load.task.isCancelled,
                  maintainingWorkspace, !load.maintainingWorkspace, load.generation == refreshGeneration,
                  defaults.string(forKey: "workspace") == path, !presentation.quitPending else { return }
        }
        guard !busy else { return }
        let previous = workspaceLoad?.task
        previous?.cancel()
        cancelDetailPreload()
        refreshGeneration += 1; let generation = refreshGeneration
        let task = Task(priority: .utility) {
            // Release the previous read's workspace lock before starting another generation.
            await previous?.value
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            await loadWorkspace(path, generation: generation, showProgress: showProgress, maintainingWorkspace: maintainingWorkspace, afterLoad: afterLoad)
        }
        workspaceLoad = (path, generation, maintainingWorkspace, task)
        await task.value
        if workspaceLoad?.generation == generation { workspaceLoad = nil; startDetailPreload() }
    }
    private func loadWorkspace(_ path: String, generation: Int, showProgress: Bool, maintainingWorkspace: Bool, afterLoad: (() -> Void)?) async {
        do {
            let root = URL(fileURLWithPath: path)
            guard let record = try await recordForReload(root, generation: generation, showProgress: showProgress, maintainingWorkspace: maintainingWorkspace) else { return }
            guard generation == refreshGeneration, !busy, !Task.isCancelled, !presentation.quitPending else { return }
            if self.record != record { invalidateDetailCache() }
            self.record = record; blocked = nil; blockedDetails = nil
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
            let resourceIDs = Set(service.resources(record).map(\.id))
            var states = self.states.filter { resourceIDs.contains($0.key) }
            for item in inspection.items {
                if item.resource == selection, detail.changes != nil || detail.changesError != nil { continue }
                states[item.resource.id] = ResourceState(resource: item.resource, available: item.status == .success, dirty: item.data?["working-tree"].map { $0 == "dirty" }, reason: item.message, reasonMessage: item.userMessage)
            }
            self.states = states
        } catch {
            guard generation == refreshGeneration, !busy, !Task.isCancelled, !presentation.quitPending else { return }
            if (error as? ModuError)?.code == "workspace-lock-timeout", record != nil {
                presentation.presentMessage(error, title: text.string(.uiWorkspaceDataCouldnTBeLoaded))
                return
            }
            invalidateDetailCache()
            record = nil; selection = nil; blocked = text.message(error); blockedDetails = Git.sanitize(error.localizedDescription)
        }
    }
    private func recordForReload(_ root: URL, generation: Int, showProgress: Bool, maintainingWorkspace: Bool) async throws -> WorkspaceRecord? {
        showsReloadProgress = showProgress
        guard let operationID = operations.begin(.workspace, cancellable: false) else { return nil }
        isReloading = true
        operations.attach(workspaceLoad?.task, to: operationID)
        defer {
            isReloading = false
            operations.finish(operationID)
            showsReloadProgress = true
            if !maintainingWorkspace { presentation.finishQuitIfPossible() }
        }
        if !maintainingWorkspace {
            let record = try await service.read(root)
            try await service.git.checkRepository(root, main: true)
            return record
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
        defaults.set(record.root, forKey: "workspace")
        self.record = record; blocked = nil; notice = nil
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
        guard workspaceLoad == nil, !busy, !presentation.quitPending, let record else { return }
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

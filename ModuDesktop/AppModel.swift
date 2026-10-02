import SwiftUI
import AppKit
import ModuCore
import Observation

@MainActor @Observable
final class AppModel {
    let defaults: UserDefaults
    let service: WorkspaceService
    let installer: InstallationService
    let toolService: ExternalTools
    var workspace: WorkspaceRecord? {
        didSet {
            if oldValue?.root != workspace?.root, sheet == .delete { sheet = nil }
            guard let workspace else { return }
            if oldValue?.root != workspace.root {
                expandedGroups = Set(defaults.stringArray(forKey: sidebarPreferenceKey("expandedGroups")) ?? [])
            }
            expandedGroups.formIntersection(workspace.groups.keys)
        }
    }
    var blocked: String?
    var workspaceWaiting = false
    var selection: Resource? { didSet { if oldValue != selection { refreshDetail() } } }
    var states: [String: ResourceState] = [:]
    var tools: [ExternalTool] = []
    private(set) var preferredToolIDs: [String: String] = [:]
    var expandedGroups = Set<String>() {
        didSet {
            guard workspace != nil, expandedGroups != oldValue else { return }
            defaults.set(expandedGroups.sorted(), forKey: sidebarPreferenceKey("expandedGroups"))
        }
    }
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var detail = RepositoryDetailState()
    var detailLoading = false
    var busy = false
    var openingWorkspace = false
    var workspaceNotice: String?
    var progress: OperationProgress?
    // SwiftUI can still render the closed sheet; reset its progress when the next sheet opens.
    private(set) var managementProgress: ManagementProgressPresentation?
    var cancelling = false
    var operation: Task<Void, Never>?
    var result: OperationResult?
    var message: String?
    var messageTitle: String?
    var messageHost = ResultHost.main
    var completionMessage: String?
    var importFileName: String?
    var formError: String? { didSet { formErrorDetails = nil } }
    var formErrorDetails: String?
    var resultHost = ResultHost.main
    var quitPending = false
    var sheet: ManagementSheet? {
        didSet {
            if sheet == nil, oldValue == .delete {
                dismissedDeletion = deletionPresentation
            }
            if let sheet, sheet != oldValue {
                managementProgress = nil
                dismissedDeletion = nil
                // Back to Edit keeps the pending selection; newly opened forms start fresh.
                if sheet != .delete && (sheet != .edit || oldValue != .delete) {
                    deleteRequest = nil; pendingEdit = nil; deletion = []
                }
            }
            if oldValue == .delete && sheet != .delete { cancelDeletePreview() }
        }
    }
    var deletion: [DeletionTarget] = []
    var deletionLoading = false
    private(set) var deletePreviewTask: Task<Void, Never>?
    var deleteRequest: DeleteRequest?
    var pendingEdit: (String, [String])?
    // The dismissed view must not depend on deletion authorization cleared by onDismiss.
    private var dismissedDeletion: DeletionPresentation?
    private var detailTask: Task<Void, Never>?
    private(set) var detailPreloadTask: Task<Void, Never>?
    private var workspaceLoad: (path: String, generation: Int, task: Task<Void, Never>)?
    private var generation = 0
    private var refreshGeneration = 0
    private var operationGeneration = 0
    private var deletePreviewGeneration = 0
    private var detailCache: [Resource: RepositoryDetailState] = [:]
    private var commitCache: [String: CommitPage] = [:]
    private(set) var started = false

    init(defaults: UserDefaults? = nil, service: WorkspaceService = .init(), toolService: ExternalTools? = nil, installer: InstallationService? = nil) {
        self.service = service
        self.toolService = toolService ?? ExternalTools()
        self.installer = installer ?? InstallationService(support: service.store.support)
        if let defaults { self.defaults = defaults }
        else {
            #if DEBUG
            if let suite = ProcessInfo.processInfo.environment["MODU_TEST_DEFAULTS"] {
                self.defaults = UserDefaults(suiteName: suite)!
                if let root = ProcessInfo.processInfo.environment["MODU_TEST_WORKSPACE"] { self.defaults.set(root, forKey: "workspace") }
            } else { self.defaults = .standard }
            #else
            self.defaults = .standard
            #endif
        }
        language = self.defaults.string(forKey: "language") ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
        for category in Set(ExternalTool.builtIn.map(\.category)) {
            preferredToolIDs[category] = self.defaults.string(forKey: "tool.\(category)")
        }
    }
    var hasSavedWorkspace: Bool { defaults.string(forKey: "workspace") != nil }
    func sidebarPreferenceKey(_ name: String) -> String { "sidebar.\(workspace?.root ?? defaults.string(forKey: "workspace") ?? "").\(name)" }
    func t(_ english: String, _ chinese: String) -> String { language == "zh" ? chinese : english }
    var sortedRepositories: [Repository] { workspace?.repositories.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } ?? [] }
    var sortedGroups: [String] { workspace?.groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? [] }
    var currentURL: URL? { guard let workspace else { return nil }; if let selection { return try? PathSafety.child(selection.path, of: workspace.rootURL, allowMissing: false) }; return workspace.rootURL }

    @discardableResult func start() async -> Bool {
        guard !started else { return false }; started = true
        let cli = await installer.checkCLI()
        guard !Task.isCancelled else { return false }
        if !cli.available { return true }
        if let path = defaults.string(forKey: "workspace") {
            changeWorkspace(URL(fileURLWithPath: path))
        }
        tools = await toolService.available()
        await operation?.value
        if let result {
            blocked = ([result.message].compactMap { $0 } + result.items.compactMap(\.message)).joined(separator: "\n")
            resultHost = .main
        }
        return false
    }
    var visibleResources: [Resource] {
        sortedRepositories.map { .repository($0.id) } + sortedGroups.flatMap { group in
            [Resource.group(group)] + (expandedGroups.contains(group) ? sortedRepositories.filter { workspace?.groups[group]?.repositories.contains($0.id) == true }.map { .member(group, $0.id) } : [])
        }
    }
    func selectSidebarRow(_ resource: Resource) {
        let wasSelected = selection == resource
        selection = resource
        if resource.kind == "group", let group = resource.group {
            if wasSelected { toggleGroup(group) }
            else { expandedGroups.insert(group) }
        }
    }
    func toggleGroup(_ group: String) {
        if expandedGroups.remove(group) != nil {
            if selection?.group == group { selection = .group(group) }
        } else { expandedGroups.insert(group) }
    }
    func requestReload() { if busy { cancel() } else { Task { await reload() } } }
    func dismissResult() { result = nil; resultHost = .main; if quitPending { NSApp.terminate(nil) } }
    func finishManagementDismissal() {
        guard sheet == nil, !busy else { return }
        deleteRequest = nil; pendingEdit = nil; deletion = []
    }
    func presentMessage(_ message: String, title: String, host: ResultHost = .main) {
        messageTitle = title; messageHost = host; self.message = message
    }
    func reload() async {
        completionMessage = nil
        await reload(afterLoad: nil)
    }
    private func reload(afterLoad: (() -> Void)?) async {
        guard !quitPending, let path = defaults.string(forKey: "workspace") else { return }
        if let load = workspaceLoad, load.path == path, load.generation == refreshGeneration {
            await load.task.value
            return
        }
        guard !busy else { return }
        let previous = workspaceLoad?.task
        previous?.cancel()
        cancelDetailPreload()
        refreshGeneration += 1; let generation = refreshGeneration
        workspaceWaiting = false
        let task = Task(priority: .utility) {
            // Release the previous read's workspace lock before starting another generation.
            await previous?.value
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            await loadWorkspace(path, generation: generation, afterLoad: afterLoad)
        }
        workspaceLoad = (path, generation, task)
        await task.value
        if workspaceLoad?.generation == generation { workspaceLoad = nil; startDetailPreload() }
    }
    private func loadWorkspace(_ path: String, generation: Int, afterLoad: (() -> Void)?) async {
        do {
            let root = URL(fileURLWithPath: path)
            guard let record = try await initializeForReload(root, generation: generation) else { return }
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            if workspace != record { invalidateDetailCache() }
            workspace = record; blocked = nil
            let previousSelection = selection
            afterLoad?()
            if let selection, !service.resources(record).contains(selection) { self.selection = nil }
            if selection == previousSelection { refreshDetail() }
            while detailLoading, let task = detailTask {
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            }
            let inspection = await service.inspect(record, excluding: selection)
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            if inspection.reasonCode == "workspace-busy" { workspaceWaiting = true; cancelDetailPreload(); return }
            let resourceIDs = Set(service.resources(record).map(\.id))
            var states = self.states.filter { resourceIDs.contains($0.key) }
            for item in inspection.items {
                if item.resource == selection, detail.changes != nil || detail.changesError != nil { continue }
                states[item.resource.id] = ResourceState(resource: item.resource, available: item.status == "success", dirty: item.data?["working-tree"].map { $0 == "dirty" }, reason: item.message)
            }
            self.states = states
        } catch {
            guard generation == refreshGeneration, !busy, !Task.isCancelled else { return }
            if (error as? ModuError)?.code == "workspace-busy" { workspaceWaiting = true; blocked = nil; return }
            invalidateDetailCache()
            workspace = nil; selection = nil; blocked = error.localizedDescription
        }
    }
    private func initializeForReload(_ root: URL, generation: Int) async throws -> WorkspaceRecord? {
        let token = operationGeneration
        busy = true; openingWorkspace = true; cancelling = false; progress = nil
        operation = workspaceLoad?.task
        defer {
            if operationGeneration == token {
                busy = false; openingWorkspace = false; cancelling = false; progress = nil; operation = nil
            }
        }
        let report: ProgressHandler = { value in Task { @MainActor [self] in
            guard refreshGeneration == generation, operationGeneration == token, busy else { return }
            progress = value
        } }
        let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md")
        let opened = await service.openWorkspaceWithRecord(root, skill: skill, installer: installer, requireExistingRecord: true, progress: report)
        guard generation == refreshGeneration, operationGeneration == token else { return nil }
        let noEffects = opened.result.items.allSatisfy { $0.effects.isEmpty }
        if quitPending || ((opened.result.status != "success" || Task.isCancelled) && !noEffects) {
            result = opened.result; resultHost = .main
        }
        if quitPending {
            if noEffects { result = nil; busy = false; NSApp.terminate(nil) }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard opened.result.status == "success", let record = opened.record else {
            let code = opened.result.reasonCode ?? opened.result.items.first?.reasonCode ?? "workspace-unavailable"
            let message = ([opened.result.message].compactMap { $0 } + opened.result.items.compactMap(\.message)).joined(separator: "\n")
            throw ModuError(code, message)
        }
        workspaceNotice = (opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", "Bundled skill is unavailable.") : nil)).map {
            t("Workflow skill wasn’t enabled. ", "工作流技能未启用。") + $0.localizedDescription
        }
        return record
    }
    func activate() async {
        guard !busy else { return }
        async let workspaceReload: Void = reload(afterLoad: nil)
        tools = await toolService.available()
        await workspaceReload
    }
    func changeWorkspace(_ url: URL) {
        guard !busy, result == nil else { return }
        let root = PathSafety.canonical(url)
        if let workspace, PathSafety.identity(root) == PathSafety.identity(workspace.rootURL) { return }
        if sheet == .delete { sheet = nil }
        busy = true; openingWorkspace = true; completionMessage = nil
        resultHost = .settings; progress = nil; cancelling = false
        cancelDetailPreload(); workspaceLoad?.task.cancel(); refreshGeneration += 1
        operation = Task {
            let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md")
            let opened = await service.openWorkspaceWithRecord(root, skill: skill, installer: installer)
            var outcome = opened.result
            if let record = opened.record, outcome.status == "success", !quitPending {
                do {
                    try await switchTo(root, loaded: record)
                    if let error = opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", "Bundled skill is unavailable.") : nil) {
                        workspaceNotice = t("Workflow skill wasn’t enabled. ", "工作流技能未启用。") + error.localizedDescription
                    }
                } catch {
                    let failure = error is CancellationError ? ModuError("cancelled", t("Workspace change cancelled.", "已取消切换工作区。")) : ModuError.wrap(error)
                    outcome.items.append(ItemResult(.init(kind: "workspace", path: root.path), status: failure.code == "cancelled" ? "cancelled" : "failed", error: failure))
                    outcome.summarize(cancelled: failure.code == "cancelled")
                }
            }
            let noEffects = outcome.items.allSatisfy { $0.effects.isEmpty }
            if quitPending || (outcome.status != "success" && !(outcome.status == "cancelled" && noEffects)) { result = outcome }
            busy = false; openingWorkspace = false; operation = nil; progress = nil; cancelling = false
            if quitPending, noEffects { result = nil; NSApp.terminate(nil) }
            if result == nil { resultHost = .main }
            startDetailPreload()
        }
    }
    func switchTo(_ root: URL, loaded: WorkspaceRecord? = nil) async throws {
        cancelDetailPreload()
        let previous = workspaceLoad?.task
        previous?.cancel()
        refreshGeneration += 1; let token = refreshGeneration
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
        workspace = record; blocked = nil; workspaceWaiting = false; workspaceNotice = nil
        states = [:]
        selection = nil; refreshDetail()
    }
    func refreshDetail() {
        cancelDetailPreload()
        detailTask?.cancel(); generation += 1
        detail = selection.flatMap { detailCache[$0] } ?? RepositoryDetailState()
        guard let selection, let workspace else {
            detailLoading = false; startDetailPreload(); return
        }
        detailLoading = true
        let token = generation, root = workspace.root, cached = detail
        detailTask = Task(priority: .userInitiated) {
            let loaded = await readDetail(selection, in: workspace, cached: cached) { partial in
                guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
                detail = partial; detailCache[selection] = partial
                updateState(selection, from: partial)
            }
            guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
            if let loaded { detail = loaded; detailCache[selection] = loaded; updateState(selection, from: loaded) }
            detailLoading = false
            startDetailPreload()
        }
    }
    func loadMore() {
        guard !detailLoading, let selection, let root = workspace?.root,
              let path = currentURL, let summary = detail.summary, let base = summary.baseOID,
              let commits = detail.commits, detail.canLoadMore else { return }
        let token = generation, key = "\(root)|\(selection.repo ?? "")|\(summary.headOID)|\(base)"
        cancelDetailPreload()
        detailLoading = true
        detailTask = Task {
            defer {
                if !Task.isCancelled, self.generation == token, self.workspace?.root == root {
                    detailCache[selection] = detail; detailLoading = false; startDetailPreload()
                }
            }
            do {
                let more = try await service.git.commits(at: path, head: summary.headOID, base: base, skip: commits.count)
                guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
                let page = CommitPage(commits: commits + more, canLoadMore: more.count == 30)
                commitCache[key] = page; detail.commits = page.commits; detail.canLoadMore = page.canLoadMore; detail.commitsError = nil
            } catch {
                guard !Task.isCancelled, self.generation == token, self.workspace?.root == root else { return }
                detail.commitsError = error.localizedDescription
            }
        }
    }
    func run(_ body: @escaping @Sendable (WorkspaceService, URL, ProgressHandler) async -> OperationResult, select: Resource? = nil) {
        guard let root = workspace?.rootURL, !busy else { return }
        cancelDeletePreview()
        cancelDetailPreload()
        managementProgress = sheet == nil ? nil : .init(importFileName: importFileName)
        busy = true; cancelling = false; progress = nil; formError = nil; completionMessage = nil; refreshGeneration += 1
        operationGeneration += 1; let operationToken = operationGeneration
        let report: ProgressHandler = { [self] progress in Task { @MainActor in
            guard self.busy, !self.openingWorkspace, self.operationGeneration == operationToken else { return }
            self.progress = progress
            self.managementProgress?.progress = progress
            // Publish additions immediately; apply removals together in the final reload.
            if let snapshot = progress.snapshot, let workspace = self.workspace, workspace.root == snapshot.root,
               Set(self.service.resources(workspace)).isSubset(of: Set(self.service.resources(snapshot))) {
                self.workspace = snapshot
            }
        } }
        operation = Task {
            let outcome = await body(service, root, report)
            let noEffects = outcome.items.allSatisfy { $0.effects.isEmpty }
            if outcome.status == "failed", noEffects, sheet != nil, sheet != .delete, !quitPending {
                formError = outcome.message ?? outcome.items.compactMap(\.message).joined(separator: "\n")
                if outcome.command == "repo.add", let raw = formError {
                    let reason = outcome.reasonCode ?? outcome.items.first?.reasonCode
                    formError = repositoryAdditionMessage(reasonCode: reason, message: raw)
                    if formError != raw { formErrorDetails = Git.sanitize(raw) }
                }
                managementProgress = nil
                busy = false; progress = nil; cancelling = false; operation = nil
                importFileName = nil
                startDetailPreload()
                return
            }
            let retainedDetail: (resource: Resource, workspace: WorkspaceRecord, detail: RepositoryDetailState)?
            if outcome.status == "success", ["worktree.remove", "repo.remove"].contains(outcome.command),
               let selection, let workspace, !outcome.items.contains(where: { $0.resource == selection }) {
                retainedDetail = (selection, workspace, detail)
            } else { retainedDetail = nil }
            invalidateDetailCache()
            pendingEdit = nil; deletion = []
            if outcome.status == "success" && !quitPending {
                result = nil
                if resultHost == .main, outcome.command != "repo.update" {
                    completionMessage = t("Completed", "已完成")
                    Task { try? await Task.sleep(for: .seconds(3)); if operationGeneration == operationToken { completionMessage = nil } }
                }
            } else if outcome.status == "cancelled", noEffects, !quitPending { result = nil }
            else { result = outcome }
            if result == nil { resultHost = .main }
            sheet = nil
            busy = false; progress = nil; cancelling = false; operation = nil
            importFileName = nil
            let selectionAtCompletion = selection
            await reload(afterLoad: { [self] in
                guard operationGeneration == operationToken, workspace?.rootURL == root, selection == selectionAtCompletion else { return }
                if let retainedDetail, selection == retainedDetail.resource, let workspace,
                   canRestoreDetail(retainedDetail.resource, from: retainedDetail.workspace, in: workspace) {
                    detailCache[retainedDetail.resource] = retainedDetail.detail
                }
                if let select, let workspace, service.resources(workspace).contains(select) { selection = select; if let group = select.group { expandedGroups.insert(group) } }
                else if let last = outcome.items.last(where: { $0.data?["disposition"] == "added" }), outcome.command == "repo.import-yaml" { selection = last.resource }
            })
        }
    }
    func cancel() { guard progress?.cancellable != false else { return }; cancelling = true; operation?.cancel() }
    func add(_ url: String, name: String) { run({ service, root, progress in await service.addRepository(.init(url: url.trimmingCharacters(in: .whitespacesAndNewlines), name: name.isEmpty ? nil : name), at: root, progress: progress) }, select: try? Resource.repository(RepositoryIdentity(url.trimmingCharacters(in: .whitespacesAndNewlines)).name)) }
    func create(_ group: String, members: [String]) { run({ service, root, progress in await service.createGroup(group, repositories: members, at: root, progress: progress) }, select: .group(group)) }
    func edit(_ group: String, members: [String]) {
        guard let root = workspace?.rootURL, !busy else { return }
        let context = generation
        Task {
            let preview = await service.editGroupPreview(group, repositories: members, at: root)
            guard generation == context, workspace?.rootURL == root, sheet == .edit, !busy else { return }
            if preview.status == "confirmation-required" {
                deletion = preview.plan ?? []; deleteRequest = nil
                pendingEdit = (group, members); sheet = .delete
            }
            else if preview.status == "failed" { formError = preview.message }
            else { run({ service, root, progress in await service.editGroup(group, repositories: members, at: root, progress: progress) }) }
        }
    }
    func prepareDelete(_ request: DeleteRequest) {
        guard let root = workspace?.rootURL, !busy else { return }
        let previous = deletePreviewTask
        cancelDeletePreview()
        let context = deletePreviewGeneration
        deletion = []; formError = nil; deleteRequest = request; pendingEdit = nil
        sheet = .delete; deletionLoading = true
        deletePreviewTask = Task {
            await previous?.value
            guard !Task.isCancelled, deletePreviewGeneration == context, workspace?.rootURL == root, sheet == .delete, !busy else { return }
            let preview = await Result(catching: { try await service.previewDelete(request, at: root) })
            guard !Task.isCancelled, deletePreviewGeneration == context, workspace?.rootURL == root, sheet == .delete, !busy else { return }
            switch preview {
            case .success(let targets): deletion = targets
            case .failure(let error): formError = error.localizedDescription
            }
            deletionLoading = false; deletePreviewTask = nil
        }
    }
    var deletionResources: [Resource] {
        if !deletion.isEmpty { return deletion.map(\.resource) }
        guard let workspace, let deleteRequest else { return [] }
        return (try? service.deleteResources(deleteRequest, record: workspace)) ?? []
    }
    var deletionPresentation: DeletionPresentation {
        dismissedDeletion ?? .init(request: deleteRequest, editingGroup: pendingEdit != nil, targets: deletion, resources: deletionResources, loading: deletionLoading)
    }
    var canConfirmDelete: Bool { sheet == .delete && !busy && !deletionLoading && !deletion.isEmpty }
    func confirmDelete() {
        guard canConfirmDelete else { return }
        let authorization = deletion
        if let edit = pendingEdit { run({ service, root, progress in await service.editGroup(edit.0, repositories: edit.1, at: root, authorization: authorization, progress: progress) }) }
        else if let request = deleteRequest { run({ service, root, progress in await service.remove(request, at: root, authorization: authorization, progress: progress) }) }
    }
    func openTool(_ tool: ExternalTool, workspaceRoot: Bool = false) {
        guard let url = workspaceRoot ? workspace?.rootURL : currentURL else { return }
        Task {
            do {
                try await toolService.open(tool, directory: url)
                preferredToolIDs[tool.category] = tool.id
                defaults.set(tool.id, forKey: "tool.\(tool.category)")
            }
            catch { presentMessage(error.localizedDescription, title: t("Can’t open \(tool.name)", "无法打开 \(tool.name)")) }
        }
    }
    func importRepositories(_ text: String, filename: String) { importFileName = filename; run { service, root, progress in await service.importRepositoryYAML(text, at: root, progress: progress) } }
    func importWorkspace(_ text: String, filename: String) { importFileName = filename; run { service, root, progress in await service.importWorkspaceYAML(text, at: root, progress: progress) } }
    func update() { run { service, root, progress in await service.updateRepositories(at: root, progress: progress) } }

    private func startDetailPreload() {
        guard detailPreloadTask == nil, workspaceLoad == nil, !workspaceWaiting, !detailLoading, !busy, let workspace else { return }
        let resources = service.resources(workspace).filter { detailCache[$0] == nil }
        guard !resources.isEmpty else { return }
        detailPreloadTask = Task(priority: .utility) {
            defer { if !Task.isCancelled { detailPreloadTask = nil } }
            for resource in resources {
                guard !Task.isCancelled, self.workspace == workspace, !busy else { return }
                guard let loaded = await readDetail(resource, in: workspace), !Task.isCancelled,
                      self.workspace == workspace, !busy else { return }
                detailCache[resource] = loaded
                updateState(resource, from: loaded)
            }
        }
    }

    private func readDetail(_ resource: Resource, in workspace: WorkspaceRecord, cached: RepositoryDetailState? = nil, publish: (RepositoryDetailState) -> Void = { _ in }) async -> RepositoryDetailState? {
        var loaded = cached ?? RepositoryDetailState()
        let path: URL
        do { path = try await service.checked(resource, in: workspace) }
        catch {
            guard !Task.isCancelled else { return nil }
            return RepositoryDetailState(summaryError: error.localizedDescription, changesError: error.localizedDescription, commitsError: error.localizedDescription)
        }
        guard !Task.isCancelled else { return nil }
        let origin = workspace.repositories.first(where: { $0.id == resource.repo })?.url
        async let loadedChanges = Result { try await service.git.changes(at: path) }
        async let loadedSummary = Result { try await service.git.summary(at: path, origin: origin) }
        let changeResult = await loadedChanges
        guard !Task.isCancelled else { return nil }
        switch changeResult {
        case .success(let value): loaded.changes = value; loaded.changesError = nil
        case .failure(let error): loaded.changes = nil; loaded.changesError = error.localizedDescription
        }
        publish(loaded)
        let summaryResult = await loadedSummary
        guard !Task.isCancelled else { return nil }
        switch summaryResult {
        case .success(let value):
            loaded.summary = value; loaded.summaryError = nil
            if let base = value.baseOID {
                let key = "\(workspace.root)|\(resource.repo ?? "")|\(value.headOID)|\(base)"
                if let cached = commitCache[key] {
                    loaded.commits = cached.commits; loaded.canLoadMore = cached.canLoadMore; loaded.commitsError = nil
                } else {
                    publish(loaded)
                    do {
                        let values = try await service.git.commits(at: path, head: value.headOID, base: base)
                        guard !Task.isCancelled else { return nil }
                        let page = CommitPage(commits: values, canLoadMore: values.count == 30)
                        commitCache[key] = page; loaded.commits = page.commits; loaded.canLoadMore = page.canLoadMore; loaded.commitsError = nil
                    } catch { loaded.commitsError = error.localizedDescription }
                }
            } else { loaded.commits = value.hasRemotes ? nil : []; loaded.canLoadMore = false; loaded.commitsError = value.baseError }
        case .failure(let error):
            loaded.summary = nil; loaded.summaryError = error.localizedDescription
            loaded.commits = nil; loaded.canLoadMore = false; loaded.commitsError = error.localizedDescription
        }
        return Task.isCancelled ? nil : loaded
    }

    private func updateState(_ resource: Resource, from detail: RepositoryDetailState) {
        states[resource.id] = ResourceState(resource: resource, available: detail.changesError == nil, dirty: detail.changes.map { !$0.isEmpty }, reason: detail.changesError)
    }

    private func cancelDetailPreload() {
        detailPreloadTask?.cancel(); detailPreloadTask = nil
    }

    private func cancelDeletePreview() {
        deletePreviewTask?.cancel(); deletePreviewGeneration += 1; deletionLoading = false
    }

    private func canRestoreDetail(_ resource: Resource, from previous: WorkspaceRecord, in current: WorkspaceRecord) -> Bool {
        guard previous.root == current.root, service.resources(current).contains(resource) else { return false }
        if let repo = resource.repo, previous.repositories.first(where: { $0.id == repo })?.url != current.repositories.first(where: { $0.id == repo })?.url { return false }
        if let group = resource.group, previous.groups[group]?.createdAt != current.groups[group]?.createdAt { return false }
        return true
    }

    private func invalidateDetailCache() {
        cancelDetailPreload()
        detailTask?.cancel(); generation += 1; detailLoading = false
        detailCache = [:]; commitCache = [:]
    }
}

enum ManagementSheet: String, Identifiable { case add, create, edit, delete; var id: String { rawValue } }
struct ManagementProgressPresentation {
    var progress: OperationProgress?
    var importFileName: String?
}
struct DeletionPresentation {
    let request: DeleteRequest?
    let editingGroup: Bool
    let targets: [DeletionTarget]
    let resources: [Resource]
    let loading: Bool
}
extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async { do { self = .success(try await body()) } catch { self = .failure(error) } }
}

enum ResultHost { case main, settings, setup }

struct RepositoryDetailState {
    var summary: GitSummary?
    var summaryError: String?
    var changes: [FileChange]?
    var changesError: String?
    var commits: [GitCommit]?
    var commitsError: String?
    var canLoadMore = false
}

private struct CommitPage {
    var commits: [GitCommit]
    var canLoadMore: Bool
}

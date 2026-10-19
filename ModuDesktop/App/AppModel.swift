import AppKit
import ModuCore
import Observation

@MainActor @Observable
final class AppModel {
    let service: WorkspaceService
    let installer: InstallationService
    let toolService: ExternalTools
    let preferences: AppPreferences
    let operations: OperationLifecycle
    let presentation: OperationPresentation
    let workspace: WorkspaceModel
    let management: ManagementModel
    var tools: [ExternalTool] = []
    private(set) var preferredToolIDs: [String: String] = [:]
    private(set) var started = false
    #if DEBUG
    @ObservationIgnored var mockWorkspace: MockWorkspace?
    #endif
    var defaults: UserDefaults { preferences.defaults }
    var language: String {
        get { preferences.language }
        set { preferences.language = newValue }
    }
    var busy: Bool { operations.busy }
    var openingWorkspace: Bool { operations.kind == .workspace }
    var cancelling: Bool { operations.cancelling }
    var progress: OperationProgress? { operations.progress }
    var operation: Task<Void, Never>? { operations.task }
    var hasSavedWorkspace: Bool { defaults.string(forKey: "workspace") != nil }
    var showsMainOperationProgress: Bool {
        busy && management.sheet == nil && presentation.resultHost == .main && (!openingWorkspace || workspace.showsReloadProgress)
    }

    init(defaults: UserDefaults? = nil, service: WorkspaceService = .init(), toolService: ExternalTools? = nil, installer: InstallationService? = nil) {
        self.service = service
        self.toolService = toolService ?? ExternalTools(git: service.git)
        let installer = installer ?? InstallationService(support: service.store.support)
        self.installer = installer
        let preferences = AppPreferences(defaults: defaults ?? Self.launchDefaults())
        self.preferences = preferences
        let operations = OperationLifecycle()
        self.operations = operations
        let presentation = OperationPresentation(preferences: preferences, operations: operations, terminate: { NSApp.terminate(nil) })
        self.presentation = presentation
        let workspace = WorkspaceModel(service: service, installer: installer, preferences: preferences, operations: operations, presentation: presentation)
        self.workspace = workspace
        let management = ManagementModel(service: service, session: workspace, operations: operations, presentation: presentation, preferences: preferences)
        self.management = management
        workspace.onContextChange = { [weak management] rootChanged in management?.contextChanged(rootChanged: rootChanged) }
        for category in Set(ExternalTool.builtIn.map(\.category)) {
            preferredToolIDs[category] = preferences.defaults.string(forKey: "tool.\(category)")
        }
    }

    func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

    @discardableResult func start(onReady: @MainActor () -> Void = {}) async -> Bool {
        guard !started else { return false }; started = true
        #if DEBUG
        if let mockWorkspace {
            await startMockWorkspace(mockWorkspace, onReady: onReady)
            return false
        }
        #endif
        let cli = await installer.checkCLIInstallation()
        guard !Task.isCancelled else { return false }
        if !cli.available || !hasSavedWorkspace { return true }
        async let pathCheck = installer.checkCLIPath()
        if let path = defaults.string(forKey: "workspace") {
            changeWorkspace(URL(fileURLWithPath: path), requireExistingRecord: true)
        }
        tools = await toolService.available()
        await operation?.value
        if let result = presentation.result {
            workspace.blocked = ([result.message].compactMap { $0 } + result.items.compactMap(\.message)).joined(separator: "\n")
            presentation.resultHost = .main
        }
        guard !Task.isCancelled else { return false }
        if !presentation.quitPending || presentation.result != nil { onReady() }
        guard !presentation.quitPending else { return false }
        let path = await pathCheck
        return !Task.isCancelled && !path.available
    }

    func activate() async {
        guard !busy else { return }
        async let workspaceReload: Void = workspace.reload(afterLoad: nil)
        tools = await toolService.available()
        await workspaceReload
    }

    func requestReload() {
        if busy { cancel() }
        else { Task { await workspace.reload() } }
    }

    func changeWorkspace(_ url: URL, requireExistingRecord: Bool = false) {
        guard !busy, presentation.result == nil else { return }
        let root = PathSafety.canonical(url)
        if let record = workspace.record, PathSafety.identity(root) == PathSafety.identity(record.rootURL) { return }
        let previousEdit = management.editPreviewTask
        management.cancelEditPreview()
        if management.sheet == .delete { management.sheet = nil }
        guard let operationID = operations.begin(.workspace) else { return }
        presentation.completionMessage = nil; presentation.resultHost = .settings
        workspace.invalidateReads(cancelReload: true)
        let task = Task {
            await previousEdit?.value
            let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "modu-workflow")
            let opened = await service.openWorkspaceWithRecord(root, skill: skill, installer: installer, requireExistingRecord: requireExistingRecord)
            var outcome = opened.result
            if let record = opened.record, outcome.status == .success, !presentation.quitPending {
                do {
                    try await switchTo(root, loaded: record)
                    if let error = opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", "Bundled skill is unavailable.") : nil) {
                        workspace.notice = t("Workflow skill wasn’t enabled. ", "工作流技能未启用。") + error.localizedDescription
                    }
                } catch {
                    let failure = error is CancellationError ? ModuError("cancelled", t("Workspace change cancelled.", "已取消切换工作区。")) : ModuError.wrap(error)
                    outcome.items.append(ItemResult(.workspace(path: root.path), status: failure.code == "cancelled" ? .cancelled : .failed, error: failure))
                    outcome.summarize(cancelled: failure.code == "cancelled")
                }
            }
            let noEffects = outcome.items.allSatisfy { $0.effects.isEmpty }
            if presentation.quitPending || (outcome.status != .success && !(outcome.status == .cancelled && noEffects)) { presentation.result = outcome }
            operations.finish(operationID)
            if presentation.quitPending, noEffects { presentation.result = nil; presentation.finishQuitIfPossible() }
            if presentation.result == nil { presentation.resultHost = .main }
            workspace.startDetailPreload()
        }
        operations.attach(task, to: operationID)
    }

    func completeSetup(_ root: URL, loaded: WorkspaceRecord? = nil) async throws {
        try Task.checkCancellation()
        let available = await toolService.available()
        try Task.checkCancellation()
        guard !presentation.quitPending else { throw CancellationError() }
        try await switchTo(root, loaded: loaded)
        tools = available
    }

    func switchTo(_ root: URL, loaded: WorkspaceRecord? = nil) async throws {
        try service.store.checkBoundary(root)
        if let loaded { try service.store.checkBoundary(loaded.rootURL) }
        let previousEdit = management.editPreviewTask
        management.cancelEditPreview()
        try await workspace.switchTo(root, loaded: loaded, waitingFor: previousEdit)
    }

    func cancel() { operations.cancel() }

    func runSetupOperation(_ body: @escaping @MainActor () async -> OperationResult) {
        guard !presentation.quitPending, presentation.result == nil, let operationID = operations.begin(.setup) else { return }
        presentation.resultHost = .setup
        let task = Task {
            let outcome = await body()
            operations.finish(operationID)
            if presentation.quitPending {
                if outcome.items.allSatisfy({ $0.effects.isEmpty }) { presentation.finishQuitIfPossible() }
                else { presentation.result = outcome }
            } else { presentation.resultHost = .main; workspace.refreshDetail() }
        }
        operations.attach(task, to: operationID)
    }

    func openTool(_ tool: ExternalTool, workspaceRoot: Bool = false) {
        guard let url = workspaceRoot ? workspace.record?.rootURL : workspace.currentURL else { return }
        Task {
            do {
                try await toolService.open(tool, directory: url)
                preferredToolIDs[tool.category] = tool.id
                defaults.set(tool.id, forKey: "tool.\(tool.category)")
            }
            catch { presentation.presentMessage(error.localizedDescription, title: t("Can’t open \(tool.name)", "无法打开 \(tool.name)")) }
        }
    }

    private static func launchDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["MODU_TEST_DEFAULTS"] {
            let defaults = UserDefaults(suiteName: suite)!
            if let root = ProcessInfo.processInfo.environment["MODU_TEST_WORKSPACE"] { defaults.set(root, forKey: "workspace") }
            return defaults
        }
        #endif
        return .standard
    }

    #if DEBUG
    private func startMockWorkspace(_ mock: MockWorkspace, onReady: @MainActor () -> Void) async {
        do {
            let record = try await mock.fixture.load()
            try await service.git.checkRepository(record.rootURL, main: true)
            try Task.checkCancellation()
            guard !presentation.quitPending else { throw CancellationError() }
            workspace.record = record
            workspace.expandedGroups = Set(record.groups.keys)
            tools = await toolService.available()
            workspace.selection = mock.initialSelection
            workspace.refreshDetail()
            await workspace.details.detailTask?.value
            try Task.checkCancellation()
            guard !presentation.quitPending else { throw CancellationError() }
            onReady()
        } catch {
            workspace.cancelDetailPreload(); workspace.details.detailTask?.cancel()
            workspace.record = nil; workspace.selection = nil; workspace.states = [:]; tools = []
            mock.fixture.remove()
            guard !Task.isCancelled, !presentation.quitPending else { return }
            workspace.blocked = error.localizedDescription
            onReady()
        }
    }
    #endif
}

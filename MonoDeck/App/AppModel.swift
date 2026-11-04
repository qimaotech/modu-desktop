import AppKit
import MonoDeckCore
import Observation

@MainActor @Observable
final class AppModel {
    let service: WorkspaceService
    let installer: InstallationService
    let toolService: ExternalTools
    let preferences: AppPreferences
    let globalShortcut: GlobalShortcutModel
    let updates: AppUpdateModel
    let relaunch: AppRelaunchModel
    let operations: OperationLifecycle
    let presentation: OperationPresentation
    let workspace: WorkspaceModel
    let management: ManagementModel
    var tools: [ExternalTool] = []
    private(set) var preferredToolIDs: [String: String] = [:]
    private(set) var started = false
    private(set) var startupCLIInstallation: CLIInstallation?
    #if DEBUG
    @ObservationIgnored var mockWorkspace: MockWorkspace?
    #endif
    var defaults: UserDefaults { preferences.defaults }
    var appLanguage: AppLanguage {
        get { preferences.appLanguage }
        set { preferences.appLanguage = newValue }
    }
    var text: InterfaceText { preferences.text }
    var busy: Bool { operations.busy }
    var openingWorkspace: Bool { operations.kind == .workspace }
    var cancelling: Bool { operations.cancelling }
    var progress: OperationProgress? { operations.progress }
    var operation: Task<Void, Never>? { operations.task }
    var hasSavedWorkspace: Bool { defaults.string(forKey: "workspace") != nil }
    var showsMainOperationProgress: Bool {
        busy && management.sheet == nil && (workspace.isReloading || (presentation.resultHost == .main && !openingWorkspace))
    }
    var showsWorkspacePreparation: Bool {
        workspace.record != nil && workspace.blocked == nil && workspace.maintenanceState == .pending
            && !busy && management.sheet == nil && !presentation.quitPending
    }
    var mainOperationProgressText: String {
        if workspace.isReloading, !workspace.showsReloadProgress, !cancelling { return text.string(.uiPreparingWorkspace) }
        return presentation.repositoryUpdateProgressText
    }
    var canShowMaintenanceFailure: Bool {
        workspace.maintenanceState == .failed && workspace.maintenanceFailure != nil && !busy && !presentation.quitPending
            && management.sheet == nil && presentation.result == nil && presentation.message == nil && !presentation.mainSheetVisible
    }
    var canPresentMaintenanceFailure: Bool { workspace.maintenanceFailurePending && canShowMaintenanceFailure }
    var detailFailurePresentationID: UUID? {
        guard !busy, !presentation.quitPending, management.sheet == nil, presentation.result == nil,
              presentation.message == nil, !presentation.mainSheetVisible, !workspace.maintenanceFailurePending,
              let failure = workspace.details.failureForPresentation,
              workspace.record?.root == failure.workspace, workspace.selection == failure.resource else { return nil }
        return failure.id
    }

    init(defaults: UserDefaults? = nil, service: WorkspaceService = .init(), toolService: ExternalTools? = nil, installer: InstallationService? = nil,
         cache: (any RepositoryDetailCaching)? = nil,
         updates: AppUpdateModel? = nil, relaunch: AppRelaunchModel? = nil,
         recordMonitor: any WorkspaceRecordChangeMonitoring = WorkspaceRecordChangeMonitor(),
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         waitForRecordDebounce: (@MainActor (ContinuousClock.Instant) async throws -> Void)? = nil,
         diagnostics: RepositoryReadDiagnostics? = nil) {
        let service = diagnostics.map { service.withDiagnostics($0) } ?? service
        self.service = service
        self.toolService = toolService ?? ExternalTools(git: service.git)
        let installer = installer ?? InstallationService(support: service.store.support)
        self.installer = installer
        let preferences = AppPreferences(defaults: defaults ?? Self.launchDefaults())
        self.preferences = preferences
        globalShortcut = GlobalShortcutModel(preferences: preferences)
        self.updates = updates ?? AppUpdateModel(preferences: preferences)
        self.relaunch = relaunch ?? AppRelaunchModel()
        let operations = OperationLifecycle()
        self.operations = operations
        let presentation = OperationPresentation(preferences: preferences, operations: operations, terminate: { NSApp.terminate(nil) })
        self.presentation = presentation
        let workspace = WorkspaceModel(service: service, installer: installer, preferences: preferences, operations: operations, presentation: presentation, cache: cache, recordMonitor: recordMonitor, now: now, waitForRecordDebounce: waitForRecordDebounce, diagnostics: diagnostics)
        self.workspace = workspace
        operations.onBusyChange = { [weak workspace] busy in workspace?.operationsChanged(busy) }
        let management = ManagementModel(service: service, session: workspace, operations: operations, presentation: presentation)
        self.management = management
        workspace.onContextChange = { [weak management] rootChanged in management?.contextChanged(rootChanged: rootChanged) }
        workspace.onMaintenanceFailure = { [weak self] in self?.presentMaintenanceFailureIfPossible() }
        self.updates.onRestartFailure = { [weak self] in self?.resumeAfterFailedQuit() }
        self.relaunch.onFailure = { [weak self] error in
            guard let self else { return }
            resumeAfterFailedQuit()
            let text = self.text
            self.presentation.presentMessage(text.string(.uiLanguageSavedRestartManually) + "\n\n" + text.string(.uiDetails) + ":\n" + Git.sanitize(error.localizedDescription),
                                             title: text.string(.uiCanTRestartMonoDeck), host: .settings)
        }
        for category in Set(ExternalTool.builtIn.map(\.category)) {
            preferredToolIDs[category] = preferences.defaults.string(forKey: "tool.\(category)")
        }
    }

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
        if !cli.available {
            startupCLIInstallation = cli
            return true
        }
        if !hasSavedWorkspace {
            let path = await installer.checkCLIPath()
            guard !Task.isCancelled, !presentation.quitPending else { return false }
            startupCLIInstallation = path
            return true
        }
        async let pathCheck = installer.checkCLIPath()
        tools = await toolService.available()
        guard !Task.isCancelled, !presentation.quitPending else { return false }
        if let path = defaults.string(forKey: "workspace") {
            do {
                try await workspace.restoreForStartup(URL(fileURLWithPath: path))
                guard !Task.isCancelled, !presentation.quitPending else { return false }
                onReady()
                await workspace.details.waitForDetail()
                guard !Task.isCancelled, !presentation.quitPending else { return false }
                if defaults.string(forKey: "workspace") == path {
                    await workspace.maintainWorkspace(.startup)
                }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, !presentation.quitPending else { return false }
                workspace.blocked = text.message(error); workspace.blockedDetails = Git.sanitize(error.localizedDescription)
                let result = OperationResult(command: "workspace.open", workspace: path, status: .failed, items: [ItemResult(.workspace(), status: .failed, error: .wrap(error))], error: .wrap(error))
                presentation.result = result; presentation.resultHost = .main
                onReady()
            }
        }
        guard !Task.isCancelled, !presentation.quitPending else { return false }
        let path = await pathCheck
        guard !Task.isCancelled, !presentation.quitPending else { return false }
        if !path.available { startupCLIInstallation = path }
        return !path.available
    }

    func takeStartupCLIInstallation() -> CLIInstallation? {
        defer { startupCLIInstallation = nil }
        return startupCLIInstallation
    }

    func activate() async {
        async let workspaceReload: Void = workspace.activate()
        tools = await toolService.available()
        await workspaceReload
    }

    @discardableResult func changeWorkspace(_ url: URL, requireExistingRecord: Bool = false, cancellable: Bool = true) -> Bool {
        guard !busy, presentation.result == nil else { return false }
        let root = PathSafety.canonical(url)
        if let record = workspace.record, PathSafety.identity(root) == PathSafety.identity(record.rootURL) { return false }
        let previousEdit = management.editPreviewTask
        management.cancelEditPreview()
        if management.sheet == .delete { management.sheet = nil }
        guard let operationID = operations.begin(.workspace, cancellable: cancellable) else { return false }
        presentation.completionMessage = nil; presentation.resultHost = .settings
        workspace.invalidateReads(cancelReload: true)
        let task = Task {
            await previousEdit?.value
            await workspace.waitForReadCancellation()
            let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "mono-deck-workflow")
            let opened = await service.openWorkspaceWithRecord(root, skill: skill, installer: installer, requireExistingRecord: requireExistingRecord)
            var outcome = opened.result
            if let record = opened.record, outcome.status == .success, !presentation.quitPending {
                do {
                    try await switchTo(root, loaded: record)
                    if let error = opened.skillError ?? (skill == nil ? MonoDeckError("skill-unavailable", .bundledSkillIsUnavailable) : nil) {
                        workspace.notice = text.string(.uiWorkflowSkillWasnTEnabled2(presentation.text.message(error)))
                        workspace.noticeDetails = Git.sanitize(error.message)
                    }
                } catch {
                    let failure = error is CancellationError ? MonoDeckError("cancelled", .workspaceChangeCancelled) : MonoDeckError.wrap(error)
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
        return true
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

    func changeLanguageAndRestart(_ language: AppLanguage) {
        guard !presentation.quitPending, !relaunch.restartPending, !updates.installing, !updates.restartPending else { return }
        preferences.appLanguage = language
        var environment: [String: String] = [:]
        #if DEBUG
        if let mockWorkspace { environment["MONO_DECK_TEST_DEFAULTS"] = mockWorkspace.suite }
        #endif
        relaunch.restart(environment: environment)
    }

    func cancel() { operations.cancel() }

    func presentMaintenanceFailureIfPossible() {
        if canPresentMaintenanceFailure { workspace.showMaintenanceFailure() }
    }

    func presentDetailFailureIfPossible() {
        guard detailFailurePresentationID != nil, let failure = workspace.details.takeFailureForPresentation() else { return }
        let resource = failure.resource.repo ?? failure.resource.group ?? failure.resource.path
        let overview = Git.sanitize(text.message(failure.error)).trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = failure.signature.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = resource + ": " + overview
        if failure.keepsPreviousResult { message += " " + text.string(.uiShowingPreviousResults) }
        if !diagnostic.isEmpty, diagnostic != overview { message += "\n\n" + text.string(.uiDetails) + ":\n" + diagnostic }
        presentation.presentMessage(message, title: text.string(.uiGitDetailsRefreshFailed))
    }

    func dismissMessage() {
        workspace.details.dismissFailure()
        presentation.message = nil
    }

    func showMaintenanceFailure() {
        if canShowMaintenanceFailure { workspace.showMaintenanceFailure() }
    }

    func retryWorkspaceMaintenance() async {
        guard workspace.maintenanceState == .failed, let failure = workspace.maintenanceFailure,
              failure.workspace == defaults.string(forKey: "workspace"), !busy, !presentation.quitPending,
              management.sheet == nil, presentation.message == nil,
              presentation.result == nil || presentation.isMaintenanceFailure else { return }
        if presentation.isMaintenanceFailure { presentation.dismissResult() }
        await workspace.maintainWorkspace()
    }

    func resumeAfterFailedQuit() {
        guard presentation.quitPending else { return }
        presentation.quitPending = false
        workspace.resumeAfterFailedQuit()
    }

    func runSetupOperation(_ body: @escaping @MainActor () async -> OperationResult) {
        guard !presentation.quitPending, presentation.result == nil, let operationID = operations.begin(.setup) else { return }
        presentation.resultHost = .setup
        let task = Task {
            await workspace.waitForReadCancellation()
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
        guard workspace.canManage, let url = workspaceRoot ? workspace.record?.rootURL : workspace.currentURL else { return }
        Task {
            do {
                try await toolService.open(tool, directory: url)
                preferredToolIDs[tool.category] = tool.id
                defaults.set(tool.id, forKey: "tool.\(tool.category)")
            }
            catch { presentation.presentMessage(error, title: text.string(.uiCanTOpen("\(tool.name)"))) }
        }
    }

    static func launchDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["MONO_DECK_TEST_DEFAULTS"] {
            let defaults = UserDefaults(suiteName: suite)!
            if let root = ProcessInfo.processInfo.environment["MONO_DECK_TEST_WORKSPACE"] { defaults.set(root, forKey: "workspace") }
            return defaults
        }
        return UserDefaults(suiteName: "fun.armantang.MonoDeck.development")!
        #else
        return .standard
        #endif
    }

    #if DEBUG
    private func startMockWorkspace(_ mock: MockWorkspace, onReady: @MainActor () -> Void) async {
        do {
            let record = try await mock.fixture.load()
            try await service.git.checkRepository(record.rootURL, main: true)
            try Task.checkCancellation()
            guard !presentation.quitPending else { throw CancellationError() }
            workspace.record = record
            if workspace.selection == nil { workspace.refreshDetail() }
            tools = await toolService.available()
            await workspace.details.detailTask?.value
            try Task.checkCancellation()
            guard !presentation.quitPending else { throw CancellationError() }
            onReady()
        } catch {
            await workspace.stopReads()
            workspace.record = nil; workspace.selection = nil; tools = []
            mock.fixture.remove()
            guard !Task.isCancelled, !presentation.quitPending else { return }
            workspace.blocked = text.message(error); workspace.blockedDetails = Git.sanitize(error.localizedDescription)
            onReady()
        }
    }
    #endif
}

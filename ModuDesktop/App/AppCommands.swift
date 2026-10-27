import SwiftUI

struct AppCommands: Commands {
    var model: AppModel
    var startupWindowReady: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(model.text.string(.uiCheckForUpdates)) {
                openWindow(id: "updates")
                model.updates.check()
            }
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .singleWindowList) {
            Button("Modu") { openWindow(id: "main") }.disabled(!startupWindowReady)
            Button(model.text.string(.uiModuSetup)) { openWindow(id: "setup") }.disabled(model.busy || !startupWindowReady)
        }
        CommandGroup(after: .newItem) {
            Button(model.text.string(.uiReloadWorkspace)) { model.requestReload() }.disabled(!model.hasSavedWorkspace)
            Button(model.text.string(.uiRefreshChanges)) { model.workspace.refreshDetail() }.keyboardShortcut("r").disabled(model.workspace.selection == nil)
            Button(model.text.string(.uiOpenWorkspaceInCodex)) { if let codex = model.tools.first(where: { $0.id == "codex" }) { model.openTool(codex, workspaceRoot: true) } }.disabled(model.workspace.record == nil || !model.tools.contains { $0.id == "codex" })
                .help(model.text.string(.uiStartCodexFromWorkspaceRootDiscoverWorkflowSkill))
                .accessibilityHint(model.text.string(.uiStartCodexFromWorkspaceRootDiscoverWorkflowSkill))
        }
        CommandMenu(model.text.string(.uiActions)) {
            Button(model.text.string(.uiAddRepository)) { model.management.sheet = .add }.keyboardShortcut("n").disabled(model.busy || model.workspace.record == nil)
            Button(model.text.string(.uiCreateWorktreeGroup)) { model.management.sheet = .create }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy || model.workspace.sortedRepositories.isEmpty)
            Button(model.text.string(.uiUpdateRepositories)) { model.management.update() }.disabled(model.busy || model.workspace.sortedRepositories.isEmpty)
            Divider()
            ResourceActions(workspace: model.workspace, management: model.management, operations: model.operations, text: model.presentation.text, resource: model.workspace.selection)
        }
    }
}

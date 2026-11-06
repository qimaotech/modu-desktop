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
            Button("MonoDeck") { openWindow(id: "main") }.disabled(!startupWindowReady)
            Button(model.text.string(.uiMonoDeckSetup)) { openWindow(id: "setup") }.disabled(model.busy || !startupWindowReady)
        }
        CommandGroup(after: .newItem) {
            Button(model.text.string(.uiRefreshGitDetails)) { model.workspace.refreshDetail(userInitiated: true) }.keyboardShortcut("r").disabled(model.workspace.selection == nil)
            Button(model.text.string(.uiOpenWorkspaceInCodex)) { openWindow(id: "main"); if let codex = ExternalTool.builtIn.first(where: { $0.id == "codex" }) { model.openTool(codex, workspaceRoot: true) } }
                .help(model.text.string(.uiStartCodexFromWorkspaceRootDiscoverWorkflowSkill))
                .accessibilityHint(model.text.string(.uiStartCodexFromWorkspaceRootDiscoverWorkflowSkill))
        }
        CommandMenu(model.text.string(.uiActions)) {
            Button(model.text.string(.uiAddRepository)) { openWindow(id: "main"); model.management.requestForm(.addRepository) }.keyboardShortcut("n")
            Button(model.text.string(.uiCreateWorktreeGroup)) { openWindow(id: "main"); model.management.requestForm(.createGroup) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button(model.text.string(.uiUpdateRepositories)) { model.management.updateRepositories() }.disabled(!model.workspace.canManage || model.workspace.sidebarStructure.repositories.isEmpty)
            Divider()
            ResourceActions(workspace: model.workspace, management: model.management, operations: model.operations, text: model.presentation.text, resource: model.workspace.selection)
        }
    }
}

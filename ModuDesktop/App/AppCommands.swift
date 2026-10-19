import SwiftUI

struct AppCommands: Commands {
    var model: AppModel
    var startupWindowReady: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .singleWindowList) {
            Button("Modu") { openWindow(id: "main") }.disabled(!startupWindowReady)
            Button(model.t("Modu Setup", "Modu 设置")) { openWindow(id: "setup") }.disabled(model.busy || !startupWindowReady)
        }
        CommandGroup(after: .newItem) {
            Button(model.t("Reload Workspace", "重新加载工作区")) { model.requestReload() }.disabled(!model.hasSavedWorkspace)
            Button(model.t("Refresh Changes", "刷新更改")) { model.workspace.refreshDetail() }.keyboardShortcut("r").disabled(model.workspace.selection == nil)
            Button(model.t("Open Workspace in Codex", "在 Codex 中打开工作区")) { if let codex = model.tools.first(where: { $0.id == "codex" }) { model.openTool(codex, workspaceRoot: true) } }.disabled(model.workspace.record == nil || !model.tools.contains { $0.id == "codex" })
                .help(model.t("Start Codex from the workspace root to discover the workflow skill.", "从工作区根目录启动 Codex 以发现工作流技能。"))
                .accessibilityHint(model.t("Start Codex from the workspace root to discover the workflow skill.", "从工作区根目录启动 Codex 以发现工作流技能。"))
        }
        CommandMenu(model.t("Actions", "操作")) {
            Button(model.t("Add Repository…", "添加仓库…")) { model.management.sheet = .add }.keyboardShortcut("n").disabled(model.busy || model.workspace.record == nil)
            Button(model.t("Create Worktree Group…", "创建工作树分组…")) { model.management.sheet = .create }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy || model.workspace.sortedRepositories.isEmpty)
            Button(model.t("Update Repositories", "更新仓库")) { model.management.update() }.disabled(model.busy || model.workspace.sortedRepositories.isEmpty)
            Divider()
            ResourceActions(workspace: model.workspace, management: model.management, operations: model.operations, text: model.presentation.text, resource: model.workspace.selection)
        }
    }
}

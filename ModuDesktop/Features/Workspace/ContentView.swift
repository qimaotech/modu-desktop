import SwiftUI
import AppKit
import ModuCore

struct ContentView: View {
    @Bindable var model: AppModel
    var chromeHeight: CGFloat = 40
    var startupCompleted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSplitView(sidebar: WorkspaceSidebar(workspace: model.workspace, management: model.management, operations: model.operations, preferences: model.preferences).id(model.workspace.record?.root), detail: detail.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        .background(DesignStyle.background)
        .navigationTitle(model.workspace.record?.rootURL.lastPathComponent ?? "Modu")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.showsMainOperationProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.presentation.repositoryUpdateProgressText).monospacedDigit()
                        Button { model.cancel() } label: { DesignIcon(name: "Cancel", size: 20) }
                            .buttonStyle(HoverPlainButtonStyle(shape: Circle()))
                            .disabled(!model.operations.canCancel)
                            .help(model.openingWorkspace ? model.t("Cancel Reload", "取消重新加载") : model.t("Cancel Update", "取消更新"))
                            .accessibilityLabel(model.openingWorkspace ? model.t("Cancel Reload", "取消重新加载") : model.t("Cancel Update", "取消更新"))
                    }
                } else if let completion = model.presentation.completionMessage {
                    Label(completion, systemImage: "checkmark.circle")
                } else { Text(model.workspace.record?.rootURL.lastPathComponent ?? "Modu").font(.system(size: 13, weight: .semibold)) }
            }.sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: mainSheetPresentation, onDismiss: { model.management.finishDismissal() }) {
            if let result = model.presentation.result, model.presentation.resultHost == .main {
                ResultView(text: model.presentation.text, result: result) { model.presentation.dismissResult() }
            } else if let sheet = model.management.sheet {
                ManagementView(management: model.management, workspace: model.workspace, operations: model.operations, presentation: model.presentation, sheet: sheet).id(sheet)
            }
        }
        .alert(model.presentation.messageTitle ?? model.t("Operation failed", "操作失败"), isPresented: Binding(get: { model.presentation.message != nil && model.presentation.messageHost == .main }, set: { if !$0 && model.presentation.messageHost == .main { model.presentation.message = nil } })) { Button(model.t("OK", "好")) {} } message: { Text(model.presentation.message ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if startupCompleted { Task { await model.activate() } }
        }
    }

    var mainSheetPresentation: Binding<Bool> {
        Binding(get: { model.management.sheet != nil || (model.presentation.result != nil && model.presentation.resultHost == .main) }, set: {
            if !$0 {
                model.management.sheet = nil
                if model.presentation.resultHost == .main { model.presentation.dismissResult() }
            }
        })
    }

    @ViewBuilder private var detail: some View {
        if let blocked = model.workspace.blocked {
            ContentUnavailableView {
                Label(model.t("Workspace data couldn’t be loaded", "无法加载工作区数据"), systemImage: "exclamationmark.triangle")
            } description: { Text(blocked).textSelection(.enabled) } actions: {
                Button(model.t("Reload", "重新加载")) { Task { await model.workspace.reload() } }
                Button(model.t("Set Up Workspace", "设置工作区")) { openWindow(id: "setup") }
                Button(model.t("Quit", "退出")) { NSApp.terminate(nil) }
            }
        } else if model.workspace.record == nil, model.hasSavedWorkspace {
            if model.workspace.waiting {
                ContentUnavailableView {
                    Label(model.t("Workspace is busy", "工作区正忙"), systemImage: "clock")
                } description: {
                    Text(model.t("Workspace is in use. Reload shortly.", "工作区正被其他操作使用，请稍后重新加载。"))
                } actions: {
                    Button(model.t("Reload", "重新加载")) { model.requestReload() }
                }
            } else {
                Color.clear.accessibilityElement()
                    .accessibilityLabel(model.t("Loading workspace…", "正在加载工作区…"))
            }
        } else if model.workspace.record == nil {
            ContentUnavailableView { Label(model.t("No workspace selected", "尚未选择工作区"), systemImage: "folder") } actions: { Button(model.t("Set Up Workspace", "设置工作区")) { openWindow(id: "setup") } }
        } else if model.workspace.selection == nil {
            VStack(spacing: 24) {
                Text(model.t("Let’s start", "开始使用")).font(DesignStyle.welcomeTitle).frame(height: 32)
                HStack(spacing: 12) {
                    Button(model.t("Add Repository", "添加仓库")) { model.management.sheet = .add }
                    Button(model.t("Create Group", "创建分组")) { model.management.sheet = .create }.disabled(model.workspace.sortedRepositories.isEmpty)
                }.buttonStyle(StartButtonStyle(width: model.language == "zh" ? 112 : 136)).disabled(model.busy)
                HStack(spacing: 12) {
                    ForEach(["Agent", "Editor"], id: \.self) { category in
                        if model.tools.contains(where: { $0.category == category }) {
                            ToolBarView(tools: model.tools, preferredToolIDs: model.preferredToolIDs, directory: model.workspace.currentURL, gitUnavailable: model.workspace.selection.map { model.workspace.states[$0.id]?.available == false } == true, text: model.presentation.text, open: { model.openTool($0) }, category: category, fixedButtonWidth: 160)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).offset(x: -12, y: -chromeHeight / 2)
        } else { RepositoryDetailView(workspace: model.workspace, preferences: model.preferences, tools: model.tools, preferredToolIDs: model.preferredToolIDs, openTool: { model.openTool($0) }) }
    }
}

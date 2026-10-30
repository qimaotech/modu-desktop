import SwiftUI
import AppKit
import ModuCore

struct ContentView: View {
    @Bindable var model: AppModel
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
                        if model.operations.canCancel || model.cancelling {
                            Button { model.cancel() } label: {
                                Image(systemName: "xmark.circle.fill").resizable().scaledToFit()
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, DesignStyle.secondary)
                                    .frame(width: 13, height: 13).frame(width: 14, height: 14, alignment: .bottom)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .disabled(!model.operations.canCancel)
                                .help(model.openingWorkspace ? model.text.string(.uiCancelReload) : model.text.string(.uiCancelUpdate))
                                .accessibilityLabel(model.openingWorkspace ? model.text.string(.uiCancelReload) : model.text.string(.uiCancelUpdate))
                        }
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
        .alert(model.presentation.messageTitle ?? model.text.string(.uiOperationFailed), isPresented: Binding(get: { model.presentation.message != nil && model.presentation.messageHost == .main }, set: { if !$0 && model.presentation.messageHost == .main { model.presentation.message = nil } })) { Button(model.text.string(.uiOk)) {} } message: { Text(model.presentation.message ?? "") }
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
                Label(model.text.string(.uiWorkspaceDataCouldnTBeLoaded), systemImage: "exclamationmark.triangle")
            } description: { IssueDescriptionView(message: blocked, details: model.workspace.blockedDetails, text: model.text) } actions: {
                Button(model.text.string(.uiReload)) { Task { await model.workspace.reload() } }
                    .disabled(model.busy)
                Button(model.text.string(.uiSetUpWorkspace)) { openWindow(id: "setup") }
                Button(model.text.string(.uiQuit)) { NSApp.terminate(nil) }
            }
        } else if model.workspace.record == nil, model.hasSavedWorkspace {
            Color.clear.accessibilityElement()
                .accessibilityLabel(model.text.string(.uiLoadingWorkspace))
        } else if model.workspace.record == nil {
            ContentUnavailableView { Label(model.text.string(.uiNoWorkspaceSelected), systemImage: "folder") } actions: { Button(model.text.string(.uiSetUpWorkspace)) { openWindow(id: "setup") } }
        } else if model.workspace.selection == nil {
            VStack(spacing: 32) {
                Text(model.text.string(.uiLetSStart)).font(DesignStyle.welcomeTitle).frame(height: 32)
                HStack(spacing: 12) {
                    Button(model.text.string(.uiAddRepository2)) { model.management.sheet = .add }
                    Button(model.text.string(.uiCreateGroup)) { model.management.sheet = .create }.disabled(model.workspace.sortedRepositories.isEmpty)
                }.buttonStyle(StartButtonStyle(width: model.preferences.activeLocale == .simplifiedChinese ? 120 : 128)).disabled(model.busy)
                HStack(spacing: 12) {
                    ForEach(["Git GUI", "Editor", "Agent"], id: \.self) { category in
                        if model.tools.contains(where: { $0.category == category }) {
                            ToolBarView(tools: model.tools, preferredToolIDs: model.preferredToolIDs, directory: model.workspace.currentURL, gitUnavailable: model.workspace.selection.map { model.workspace.states[$0.id]?.available == false } == true, text: model.presentation.text, open: { model.openTool($0) }, category: category, fixedButtonWidth: 136)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).offset(x: -12, y: -24)
        } else { RepositoryDetailView(workspace: model.workspace, preferences: model.preferences, tools: model.tools, preferredToolIDs: model.preferredToolIDs, openTool: { model.openTool($0) }) }
    }
}

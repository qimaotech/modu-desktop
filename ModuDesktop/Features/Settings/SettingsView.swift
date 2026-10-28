import SwiftUI
import ModuCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var choosingWorkspace = false
    @State private var openingWorkspaceURL: URL?
    @State private var closingAfterWorkspaceChange = false
    @State private var choosingAgain = false
    @State private var pendingLanguage: AppLanguage?
    private var presentingOperation: Bool { openingWorkspaceURL != nil || (model.presentation.resultHost == .settings && (model.presentation.result != nil || (model.busy && !model.openingWorkspace))) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text.string(.uiGeneral)).font(.system(size: 13, weight: .semibold))
                    HStack {
                        Text(model.text.string(.uiLanguage))
                        Spacer()
                        Picker(model.text.string(.uiLanguage), selection: languageSelection) {
                            Text(model.text.string(.uiFollowSystem)).tag(AppLanguage.system)
                            Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                            Text(verbatim: "English").tag(AppLanguage.english)
                        }.labelsHidden().frame(width: 150)
                            .alert(model.text.string(.uiChangeLanguage), isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } }), presenting: pendingLanguage) { language in
                                Button(model.text.string(.uiCancel), role: .cancel) { pendingLanguage = nil }
                                Button(model.text.string(.uiRestart)) {
                                    model.changeLanguageAndRestart(language)
                                    pendingLanguage = nil
                                }
                                .keyboardShortcut(.defaultAction)
                            } message: { _ in
                                Text(model.text.string(.uiRestartModuApplyLanguageChange))
                            }
                            .disabled(model.presentation.quitPending || model.updates.installing || model.updates.restartPending || model.relaunch.restartPending)
                    }.padding(.horizontal, 16).frame(height: 60).formPlate()
                }
                GlobalShortcutSettingsView(model: model.globalShortcut)
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text.string(.uiWorkspace)).font(.system(size: 13, weight: .semibold))
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.workspace.record?.rootURL.lastPathComponent ?? model.text.string(.uiNoWorkspaceSelected)).fontWeight(.medium)
                                if let path = model.workspace.record?.root {
                                    Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesignStyle.secondary)
                                        .lineLimit(1).truncationMode(.middle).help(path).accessibilityValue(path)
                                }
                            }
                            Spacer(minLength: 16)
                            Button(model.workspace.record == nil ? model.text.string(.uiChoose) : model.text.string(.uiChange)) { chooseWorkspace() }
                                .accessibilityIdentifier("changeWorkspace").disabled(model.busy || presentingOperation || choosingWorkspace)
                                .accessibilityValue(model.openingWorkspace ? model.text.string(.uiOpeningWorkspace) : "")
                        }.frame(height: 64)
                        Divider()
                        HStack(spacing: 8) {
                            Text(model.text.string(.uiConfiguration))
                            Spacer()
                            Button(model.text.string(.uiImportYAML)) { importYAML() }.disabled(model.workspace.record == nil || model.busy || presentingOperation || choosingWorkspace)
                            Button(model.text.string(.uiExportYAML)) { exportYAML() }.disabled(model.workspace.record == nil || model.busy || presentingOperation || choosingWorkspace)
                        }.frame(height: 48)
                            .help(model.text.string(.uiOnlySavesRepositoryAndGroupStructureNotFiles))
                    }.padding(.horizontal, 16).formPlate()
                }
                if let notice = model.workspace.notice {
                    HStack(alignment: .top) {
                        ScrollView { IssueDescriptionView(message: notice, details: model.workspace.noticeDetails, text: model.text).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80)
                        Button { model.workspace.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(HoverPlainButtonStyle(shape: Circle())).accessibilityLabel(model.text.string(.uiDismiss)).help(model.text.string(.uiDismiss))
                    }.foregroundStyle(DesignStyle.secondary)
                }
            }.font(.system(size: 13)).padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 40)
        }.background(DesignStyle.background)
        .navigationTitle(model.text.string(.uiSettings))
        .alert(model.presentation.messageTitle ?? model.text.string(.uiConfigurationError), isPresented: Binding(get: { model.presentation.message != nil && model.presentation.messageHost == .settings }, set: { if !$0 && model.presentation.messageHost == .settings { model.presentation.message = nil } })) { Button(model.text.string(.uiOk)) {} } message: { Text(model.presentation.message ?? "") }
        .sheet(isPresented: operationSheetPresentation, onDismiss: {
            if closingAfterWorkspaceChange {
                closingAfterWorkspaceChange = false
                dismiss(); openWindow(id: "main")
            } else if choosingAgain { choosingAgain = false; chooseWorkspace() }
        }) {
            operationSheetContents
        }
    }
    private var languageSelection: Binding<AppLanguage> {
        Binding(get: { pendingLanguage ?? model.appLanguage }, set: { language in
            guard language != model.appLanguage else { return }
            if model.preferences.languageChangeRequiresRestart(language) {
                pendingLanguage = language
            } else {
                model.appLanguage = language
            }
        })
    }
    var operationSheetPresentation: Binding<Bool> {
        Binding(get: { presentingOperation }, set: { if !$0 && openingWorkspaceURL == nil { model.presentation.dismissResult() } })
    }
    @ViewBuilder var operationSheetContents: some View {
        if let url = openingWorkspaceURL {
            WorkspaceOpeningProgressView(title: model.text.string(.uiOpeningWorkspace), url: url)
                .task { await openWorkspace(url) }
        } else if let result = model.presentation.result {
            ResultView(text: model.presentation.text, result: result, retry: result.command == "workspace.open" && !model.presentation.quitPending ? { choosingAgain = true; model.presentation.dismissResult() } : nil) { model.presentation.dismissResult() }
        } else if model.busy && !model.openingWorkspace {
            OperationProgressView(operations: model.operations, operationPresentation: model.presentation, title: model.text.string(.uiImportingWorkspace), context: model.management.importFileName)
        }
    }
    private func chooseWorkspace() {
        choosingWorkspace = true
        Task {
            defer { choosingWorkspace = false }
            guard let url = await FilePanels.directory(at: model.workspace.record?.rootURL.deletingLastPathComponent(), prompt: model.text.string(.uiOpen)), !model.busy else { return }
            openingWorkspaceURL = PathSafety.canonical(url)
        }
    }
    private func openWorkspace(_ url: URL) async {
        guard model.changeWorkspace(url, cancellable: false) else { openingWorkspaceURL = nil; return }
        await model.operation?.value
        guard !Task.isCancelled, openingWorkspaceURL == url else { return }
        closingAfterWorkspaceChange = model.presentation.result == nil && !model.presentation.quitPending && model.workspace.record?.root == url.path
        openingWorkspaceURL = nil
    }
    private func importYAML() {
        Task {
            do { if let file = try await FilePanels.readYAML(prompt: model.text.string(.uiImport)) { model.presentation.resultHost = .settings; model.management.importWorkspace(file.text, filename: file.name) } }
            catch { model.presentation.presentMessage(error, title: model.text.string(.uiCanTReadConfigurationFile), host: .settings) }
        }
    }
    private func exportYAML() {
        guard let root = model.workspace.record?.rootURL else { return }
        Task {
            do {
                guard let destination = await FilePanels.yamlDestination(name: root.lastPathComponent, directory: model.service.store.directoryBoundary) else { return }
                try await model.service.exportYAML(at: root, to: destination)
            } catch { model.presentation.presentMessage(error, title: model.text.string(.uiCanTExportConfiguration), host: .settings) }
        }
    }
}

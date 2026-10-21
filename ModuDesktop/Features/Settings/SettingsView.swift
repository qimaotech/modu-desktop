import SwiftUI
import ModuCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var choosingWorkspace = false
    @State private var showingProgress = false
    @State private var choosingAgain = false
    private var presentingOperation: Bool { model.presentation.resultHost == .settings && (model.presentation.result != nil || (model.busy && !model.openingWorkspace)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.t("General", "通用")).font(.system(size: 13, weight: .semibold))
                    HStack {
                        Text(model.t("Language", "语言"))
                        Spacer()
                        Picker("", selection: $model.language) { Text("English").tag("en"); Text("中文").tag("zh") }
                            .labelsHidden().frame(width: 120)
                    }.padding(.horizontal, 16).frame(height: 60).formPlate()
                }
                GlobalShortcutSettingsView(model: model.globalShortcut)
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.t("Workspace", "工作区")).font(.system(size: 13, weight: .semibold))
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.workspace.record?.rootURL.lastPathComponent ?? model.t("No workspace selected", "尚未选择工作区")).fontWeight(.medium)
                                if let path = model.workspace.record?.root {
                                    Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesignStyle.secondary)
                                        .lineLimit(1).truncationMode(.middle).help(path).accessibilityValue(path)
                                }
                            }
                            Spacer(minLength: 16)
                            if showingProgress && model.openingWorkspace {
                                ProgressView().controlSize(.small)
                                Text(model.t("Opening workspace…", "正在打开工作区…")).font(.system(size: 11)).foregroundStyle(DesignStyle.secondary)
                            }
                            Button(model.workspace.record == nil ? model.t("Choose…", "选择…") : model.t("Change…", "更改…")) { chooseWorkspace() }
                                .accessibilityIdentifier("changeWorkspace").disabled(model.busy || presentingOperation || choosingWorkspace)
                                .accessibilityValue(model.openingWorkspace ? model.t("Opening workspace…", "正在打开工作区…") : "")
                        }.frame(height: 64)
                        Divider()
                        HStack(spacing: 8) {
                            Text(model.t("Configuration", "配置"))
                            Spacer()
                            Button(model.t("Import YAML…", "导入 YAML…")) { importYAML() }.disabled(model.workspace.record == nil || model.busy || presentingOperation || choosingWorkspace)
                            Button(model.t("Export YAML…", "导出 YAML…")) { exportYAML() }.disabled(model.workspace.record == nil || model.busy || presentingOperation || choosingWorkspace)
                        }.frame(height: 48)
                            .help(model.t("Only saves repository and group structure, not files, history, or current branch state.", "仅保存仓库与分组结构，不备份文件、历史或当前分支状态。"))
                    }.padding(.horizontal, 16).formPlate()
                }
                if let notice = model.workspace.notice {
                    HStack(alignment: .top) {
                        ScrollView { Text(notice).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80)
                        Button { model.workspace.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(HoverPlainButtonStyle(shape: Circle())).accessibilityLabel(model.t("Dismiss", "关闭提示")).help(model.t("Dismiss", "关闭提示"))
                    }.foregroundStyle(DesignStyle.secondary)
                }
            }.font(.system(size: 13)).padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 40)
        }.background(DesignStyle.background)
        .navigationTitle(model.t("Settings", "设置"))
        .alert(model.presentation.messageTitle ?? model.t("Configuration error", "配置文件错误"), isPresented: Binding(get: { model.presentation.message != nil && model.presentation.messageHost == .settings }, set: { if !$0 && model.presentation.messageHost == .settings { model.presentation.message = nil } })) { Button(model.t("OK", "好")) {} } message: { Text(model.presentation.message ?? "") }
        .task(id: model.openingWorkspace) {
            showingProgress = false
            guard model.openingWorkspace else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            if model.openingWorkspace { showingProgress = true }
        }
        .sheet(isPresented: operationSheetPresentation, onDismiss: {
            if choosingAgain { choosingAgain = false; chooseWorkspace() }
        }) {
            operationSheetContents
        }
    }
    var operationSheetPresentation: Binding<Bool> {
        Binding(get: { presentingOperation }, set: { if !$0 { model.presentation.dismissResult() } })
    }
    @ViewBuilder var operationSheetContents: some View {
        if let result = model.presentation.result {
            ResultView(text: model.presentation.text, result: result, retry: result.command == "workspace.open" && !model.presentation.quitPending ? { choosingAgain = true; model.presentation.dismissResult() } : nil) { model.presentation.dismissResult() }
        } else if model.busy && !model.openingWorkspace {
            OperationProgressView(operations: model.operations, operationPresentation: model.presentation, title: model.t("Importing workspace…", "正在导入工作区…"), context: model.management.importFileName)
        }
    }
    private func chooseWorkspace() {
        choosingWorkspace = true
        Task {
            defer { choosingWorkspace = false }
            guard let url = await FilePanels.directory(at: model.workspace.record?.rootURL, prompt: model.t("Open", "打开")), !model.busy else { return }
            model.changeWorkspace(url)
        }
    }
    private func importYAML() {
        Task {
            do { if let file = try await FilePanels.readYAML(prompt: model.t("Import", "导入")) { model.presentation.resultHost = .settings; model.management.importWorkspace(file.text, filename: file.name) } }
            catch { model.presentation.presentMessage(error.localizedDescription, title: model.t("Can’t read configuration file", "无法读取配置文件"), host: .settings) }
        }
    }
    private func exportYAML() {
        guard let root = model.workspace.record?.rootURL else { return }
        Task {
            do {
                guard let destination = await FilePanels.yamlDestination(name: root.lastPathComponent, directory: model.service.store.directoryBoundary) else { return }
                try await model.service.exportYAML(at: root, to: destination)
            } catch { model.presentation.presentMessage(error.localizedDescription, title: model.t("Can’t export configuration", "无法导出配置"), host: .settings) }
        }
    }
}

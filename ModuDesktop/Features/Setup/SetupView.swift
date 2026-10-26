import SwiftUI
import AppKit
import ModuCore

struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var setup: SetupModel

    init(model: AppModel) {
        self.model = model
        _setup = State(initialValue: SetupModel(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        stepGraphic("1.", icon: "ToolIcons/Terminal")
                        Text(model.t("Install modu-cli", "安装 modu-cli"))
                        Spacer(minLength: 8)
                        if setup.cliReady && setup.cliActivity == nil {
                            HStack(spacing: 4) { DesignIcon(name: "Success", size: 20); Text(model.t("Installed", "已安装")).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary) }
                        } else {
                            Button { setup.install() } label: {
                                installButtonLabel
                            }
                            .accessibilityLabel(installButtonTitle)
                            .buttonStyle(.borderedProminent).disabled(setup.working || setup.cliActivity != nil)
                        }
                    }.padding(.horizontal, 20).frame(height: 68)
                    Divider().padding(.horizontal, 20).frame(height: 11)
                    HStack(spacing: 16) {
                        stepGraphic("2.", icon: "DesignIcons/Finder").opacity(setup.cliReady ? 1 : 0.4)
                        Text(model.t("Choose Workspace", "选择工作区")).fixedSize().opacity(setup.cliReady ? 1 : 0.4)
                        if let candidate = setup.candidate {
                            HStack(spacing: 4) {
                                DesignIcon(name: "Success", size: 20)
                                Text((candidate.path as NSString).abbreviatingWithTildeInPath).font(DialogTypography.path).foregroundStyle(DesignStyle.secondary).lineLimit(1).truncationMode(.middle).help(candidate.path)
                                    .accessibilityIdentifier("workspaceCandidate").accessibilityValue(candidate.path)
                            }.frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Spacer(minLength: 8)
                        }
                        Button(model.t("Choose…", "选择…")) { choose() }.disabled(!setup.cliReady || setup.working)
                    }.padding(.horizontal, 20).frame(height: 68)
                }.formPlate()
                VStack(alignment: .leading, spacing: 8) {
                    if !setup.cliMessage.isEmpty && !setup.cliReady && setup.cliMessage != "Install modu-cli to continue." { Text(setup.cliMessage).textSelection(.enabled) }
                    if setup.skillConflict {
                        Label(model.t("Workflow skill: Unavailable", "工作流技能：不可用"), systemImage: "exclamationmark.circle")
                    }
                    if let error = setup.error { ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90) }
                    if setup.working && !setup.settingUp && setup.cliActivity == nil { ProgressView().controlSize(.small) }
                }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 20)
            Divider()
            HStack {
                Button(model.hasSavedWorkspace ? model.t("Cancel", "取消") : model.t("Quit", "退出")) {
                    if setup.cliReady && model.hasSavedWorkspace { dismiss(); openWindow(id: "main") }
                    else { NSApp.terminate(nil) }
                }.disabled(setup.working).keyboardShortcut(.cancelAction)
                Spacer()
                Button { setup.continueSetup { openWindow(id: "main"); dismiss() } } label: {
                    continueButtonLabel
                }
                .accessibilityLabel(continueButtonTitle)
                .keyboardShortcut(.defaultAction).disabled(!setup.cliReady || setup.candidate == nil || setup.working)
            }.padding(.horizontal, 20).frame(height: 52)
        }.font(DialogTypography.body).background(DesignStyle.background)
        .interactiveDismissDisabled(setup.working)
        .sheet(isPresented: Binding(get: { model.presentation.resultHost == .setup && model.presentation.result != nil }, set: { if !$0 { model.presentation.dismissResult() } })) {
            if let result = model.presentation.result { ResultView(text: model.presentation.text, result: result) { model.presentation.dismissResult() } }
        }
        .task { await setup.check() }
    }

    var installButtonLabel: some View {
        ZStack {
            Text(model.t("Install", "安装")).hidden()
            Text(model.t("Checking…", "正在检查…")).padding(.leading, 18).hidden()
            Text(model.t("Installing…", "正在安装…")).padding(.leading, 18).hidden()
            HStack(spacing: 6) {
                if setup.cliActivity != nil {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true)
                }
                Text(installButtonTitle)
            }
        }
    }

    var installButtonTitle: String {
        switch setup.cliActivity {
        case .checking: model.t("Checking…", "正在检查…")
        case .installing: model.t("Installing…", "正在安装…")
        case nil: model.t("Install", "安装")
        }
    }

    var continueButtonLabel: some View {
        ZStack {
            Text(continueTitle).hidden()
            Text(model.t("Setting up…", "正在设置…")).padding(.leading, 18).hidden()
            HStack(spacing: 6) {
                if setup.settingUp {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true)
                }
                Text(continueButtonTitle)
            }
        }
    }

    var continueButtonTitle: String {
        setup.settingUp ? model.t("Setting up…", "正在设置…") : continueTitle
    }

    private var continueTitle: String {
        setup.skillConflict ? model.t("Continue Without Skill", "不安装技能并继续") : model.t("Continue", "继续")
    }

    private func stepGraphic(_ number: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Text(number).font(DialogTypography.body.weight(.semibold)).foregroundStyle(DesignStyle.secondary)
            Image(icon).resizable().scaledToFit().frame(width: 24, height: 24).frame(width: 48).accessibilityHidden(true)
        }
    }

    private func choose() {
        Task {
            guard let url = await FilePanels.directory(at: setup.candidate ?? model.workspace.record?.rootURL) else { return }
            await setup.checkCandidate(url)
        }
    }
}

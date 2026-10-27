import SwiftUI
import AppKit
import ModuCore

struct SetupView: View {
    @Bindable var model: AppModel
    var canReturnToMainWindow: () -> Bool
    var returnToMainWindow: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var setup: SetupModel

    init(model: AppModel, canReturnToMainWindow: @escaping () -> Bool, returnToMainWindow: @escaping () -> Void) {
        self.model = model
        self.canReturnToMainWindow = canReturnToMainWindow
        self.returnToMainWindow = returnToMainWindow
        _setup = State(initialValue: SetupModel(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        stepGraphic("ToolIcons/Terminal")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.t("Install modu-cli", "安装 modu-cli")).fontWeight(.semibold)
                            pathLabel(model.installer.commandLink)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if setup.cliReady && setup.cliActivity == nil {
                            HStack(spacing: 4) { DesignIcon(name: "Success", size: 20); Text(model.t("Installed", "已安装")).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary) }
                        } else {
                            Button { setup.install() } label: {
                                installButtonLabel
                            }
                            .accessibilityLabel(installButtonTitle)
                            .buttonStyle(.borderedProminent).disabled(setup.working || setup.cliActivity != nil)
                        }
                    }.padding(.horizontal, 20).frame(height: 84)
                    Divider().padding(.horizontal, 20)
                    HStack(spacing: 16) {
                        stepGraphic("DesignIcons/Finder").opacity(setup.cliReady ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.t("Choose Workspace", "选择工作区")).fontWeight(.semibold)
                            if let candidate = setup.candidate {
                                pathLabel(candidate).accessibilityIdentifier("workspaceCandidate")
                            } else {
                                Text(model.t("No workspace selected", "尚未选择工作区")).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).opacity(setup.cliReady ? 1 : 0.4)
                        Button(setup.candidate == nil ? model.t("Choose…", "选择…") : model.t("Change…", "更改…")) { choose() }.disabled(!setup.cliReady || setup.working)
                    }.padding(.horizontal, 20).frame(height: 84)
                }.formPlate()
                if showsStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        if showsCLIMessage { Text(model.presentation.text.message(setup.cliMessage)).textSelection(.enabled) }
                        if setup.skillConflict {
                            Label(model.t("Workflow skill: Unavailable", "工作流技能：不可用"), systemImage: "exclamationmark.circle")
                        }
                        if let error = setup.error { ScrollView { Text(model.presentation.text.message(error)).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90) }
                        if setup.working && !setup.settingUp && setup.cliActivity == nil { ProgressView().controlSize(.small) }
                    }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 32)
            Divider()
            HStack {
                Button(canReturnToMainWindow() ? model.t("Cancel", "取消") : model.t("Quit", "退出")) {
                    if canReturnToMainWindow() { dismiss(); returnToMainWindow() }
                    else { NSApp.terminate(nil) }
                }.disabled(setup.working).keyboardShortcut(.cancelAction)
                Spacer()
                Button { setup.continueSetup { openWindow(id: "main"); dismiss() } } label: {
                    continueButtonLabel
                }
                .accessibilityLabel(continueButtonTitle)
                .keyboardShortcut(.defaultAction).disabled(!setup.cliReady || setup.candidate == nil || setup.working)
            }.padding(.horizontal, 24).frame(height: 54)
        }.font(DialogTypography.body).background(DesignStyle.background)
        .interactiveDismissDisabled(setup.working)
        .sheet(isPresented: Binding(get: { model.presentation.resultHost == .setup && model.presentation.result != nil }, set: { if !$0 { model.presentation.dismissResult() } })) {
            if let result = model.presentation.result { ResultView(text: model.presentation.text, result: result) { model.presentation.dismissResult() } }
        }
        .task { await setup.check() }
    }

    private var showsStatus: Bool {
        showsCLIMessage || setup.skillConflict || setup.error != nil || (setup.working && !setup.settingUp && setup.cliActivity == nil)
    }

    private var showsCLIMessage: Bool {
        !setup.cliMessage.isEmpty && !setup.cliReady && setup.cliMessage != "Install modu-cli to continue."
    }

    var installButtonLabel: some View {
        ZStack {
            Text(installTitle).hidden()
            Text(model.t("Checking…", "正在检查…")).padding(.leading, 18).hidden()
            Text(installingTitle).padding(.leading, 18).hidden()
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
        case .installing: installingTitle
        case nil: installTitle
        }
    }

    private var installTitle: String {
        setup.cliPreviouslyInstalled ? model.t("Reinstall", "重新安装") : model.t("Install", "安装")
    }

    private var installingTitle: String {
        setup.cliPreviouslyInstalled ? model.t("Reinstalling…", "正在重新安装…") : model.t("Installing…", "正在安装…")
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

    private func stepGraphic(_ icon: String) -> some View {
        Image(icon).resizable().scaledToFit().frame(width: 32, height: 32).frame(width: 48).accessibilityHidden(true)
    }

    private func pathLabel(_ url: URL) -> some View {
        Text((url.path as NSString).abbreviatingWithTildeInPath)
            .font(DialogTypography.path).foregroundStyle(DesignStyle.secondary)
            .lineLimit(1).truncationMode(.middle).help(url.path).accessibilityValue(url.path)
    }

    private func choose() {
        Task {
            guard let url = await FilePanels.directory(at: setup.candidate ?? model.workspace.record?.rootURL) else { return }
            await setup.checkCandidate(url)
        }
    }
}

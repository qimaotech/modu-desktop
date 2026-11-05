import SwiftUI
import AppKit
import MonoDeckCore

struct SetupView: View {
    @Bindable var model: AppModel
    var canReturnToMainWindow: () -> Bool
    var returnToMainWindow: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var setup: SetupModel

    init(model: AppModel, preparedSetup: SetupModel? = nil, canReturnToMainWindow: @escaping () -> Bool, returnToMainWindow: @escaping () -> Void) {
        self.model = model
        self.canReturnToMainWindow = canReturnToMainWindow
        self.returnToMainWindow = returnToMainWindow
        if let preparedSetup, !model.hasSavedWorkspace || preparedSetup.isPreparedForCurrentWorkspace {
            _setup = State(initialValue: preparedSetup)
        } else {
            _setup = State(initialValue: SetupModel(model: model))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        stepGraphic("ToolIcons/Terminal")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.text.string(.uiInstallMonoDeckCli)).fontWeight(.semibold)
                            pathLabel(model.installer.commandLink)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if setup.cliReady && setup.cliActivity == nil {
                            HStack(spacing: 4) { DesignIcon(name: "Success", size: 20); Text(model.text.string(.uiInstalled)).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary) }
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
                        stepGraphic("DesignIcons/Finder").opacity(setup.canSelectWorkspace ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.text.string(.uiChooseWorkspace)).fontWeight(.semibold)
                            if let workspace = setup.selectedWorkspace {
                                pathLabel(workspace).accessibilityIdentifier("workspaceCandidate")
                            } else {
                                Text(model.text.string(.uiNoWorkspaceSelected)).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).opacity(setup.canSelectWorkspace ? 1 : 0.4)
                        Button(setup.selectedWorkspace == nil ? model.text.string(.uiChoose) : model.text.string(.uiChange)) { choose() }.disabled(!setup.canSelectWorkspace)
                    }.padding(.horizontal, 20).frame(height: 84)
                }.formPlate()
                if showsStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        if showsCLIMessage { IssueDescriptionView(message: model.text.message(setup.cliUserMessage ?? .diagnostic(setup.cliMessage)), details: setup.cliMessage, text: model.text) }
                        if setup.skillConflict {
                            Label(model.text.string(.uiWorkflowSkillUnavailable), systemImage: "exclamationmark.circle")
                        }
                        if let error = setup.error { ScrollView { IssueDescriptionView(message: error, details: setup.errorDetails, text: model.text).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90) }
                    }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 32)
            Divider()
            HStack {
                Button(canReturnToMainWindow() ? model.text.string(.uiCancel) : model.text.string(.uiQuit)) {
                    if canReturnToMainWindow() { dismiss(); returnToMainWindow() }
                    else { NSApp.terminate(nil) }
                }.disabled(setup.working && setup.cliActivity != .checking).keyboardShortcut(.cancelAction)
                Spacer()
                Button { setup.continueSetup { openWindow(id: "main"); dismiss() } } label: {
                    continueButtonLabel
                }
                .accessibilityLabel(continueButtonTitle)
                .keyboardShortcut(.defaultAction).disabled(!setup.canContinueSetup)
            }.padding(.horizontal, 24).frame(height: 54)
        }.font(DialogTypography.body).background(DesignStyle.background)
        .interactiveDismissDisabled(setup.working)
        .sheet(isPresented: Binding(get: { model.presentation.resultHost == .setup && model.presentation.result != nil }, set: { if !$0 { model.presentation.dismissResult() } })) {
            if let result = model.presentation.result { ResultView(text: model.presentation.text, result: result) { model.presentation.dismissResult() } }
        }
        .task { await setup.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "setup" else { return }
            setup.windowClosed()
        }
    }

    private var showsStatus: Bool {
        showsCLIMessage || setup.skillConflict || setup.error != nil
    }

    private var showsCLIMessage: Bool {
        !setup.cliMessage.isEmpty && !setup.cliReady
    }

    var installButtonLabel: some View {
        ZStack {
            Text(installTitle).hidden()
            Text(model.text.string(.uiChecking)).padding(.leading, 18).hidden()
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
        case .checking: model.text.string(.uiChecking)
        case .installing: installingTitle
        case nil: installTitle
        }
    }

    private var installTitle: String {
        setup.cliPreviouslyInstalled ? model.text.string(.uiReinstall) : model.text.string(.uiInstall)
    }

    private var installingTitle: String {
        setup.cliPreviouslyInstalled ? model.text.string(.uiReinstalling) : model.text.string(.uiInstalling)
    }

    var continueButtonLabel: some View {
        ZStack {
            Text(continueTitle).hidden()
            Text(model.text.string(.uiSettingUp)).padding(.leading, 18).hidden()
            HStack(spacing: 6) {
                if setup.settingUp {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true)
                }
                Text(continueButtonTitle)
            }
        }
    }

    var continueButtonTitle: String {
        setup.settingUp ? model.text.string(.uiSettingUp) : continueTitle
    }

    private var continueTitle: String {
        setup.skillConflict ? model.text.string(.uiContinueWithoutSkill) : model.text.string(.uiContinue)
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
            guard let url = await FilePanels.directory(at: setup.selectedWorkspace ?? model.workspace.record?.rootURL) else { return }
            setup.selectWorkspace(url)
        }
    }
}

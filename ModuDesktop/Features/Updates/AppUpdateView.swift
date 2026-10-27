import SwiftUI
import ModuCore

struct AppUpdateView: View {
    var model: AppUpdateModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let update = model.update {
                Text(model.text.string(.uiModuIsAvailable("\(update.version)"))).font(DesignStyle.windowTitle)
            }
            Text(model.text.string(.uiInstalledVersion("\(ModuVersion.current)")))
                .font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
            if model.working {
                if model.downloading, case let .downloading(receivedBytes, totalBytes) = model.downloadProgress, totalBytes > 0 {
                    let fraction = min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(progressText)
                            Spacer()
                            Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(model.text.locale.locale)))
                                .monospacedDigit()
                        }
                        ProgressView(value: fraction).progressViewStyle(.linear)
                        Text("\(byteCount(receivedBytes)) / \(byteCount(totalBytes))")
                            .font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary).monospacedDigit()
                    }
                } else {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(progressText)
                    }
                }
            } else if model.update != nil {
                Text(model.text.string(.uiInstallUpdateAndAutomaticallyRestartModuWorkspacesAre))
            } else if model.checked {
                Text(model.text.string(.uiYouReRunningLatestVersionOfModu))
            }
            if let error = model.error { IssueDescriptionView(message: error, details: model.errorDetails, text: model.text).foregroundStyle(.red) }
            HStack {
                Link(model.text.string(.uiReleaseNotes), destination: model.update?.releaseURL ?? AppUpdateService.releasesURL)
                Spacer()
                if model.restartPending {
                    Text(model.text.string(.uiWaitingForModuQuit)).foregroundStyle(DesignStyle.secondary)
                } else if model.working {
                    Button(model.text.string(.uiCancel)) { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(model.text.string(.uiClose)) { dismissWindow(id: "updates") }.keyboardShortcut(.cancelAction)
                    if model.update != nil {
                        Button(model.text.string(.uiInstallAndRestart)) { model.installAndRestart() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(model.text.string(.uiCheckAgain)) { model.check() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .font(DialogTypography.body)
        .padding(24).frame(width: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .background(WindowCloseHandler(shouldQuit: { model.cancel(); return model.restartPending }))
        .onDisappear { model.cancel() }
    }

    private var progressText: String {
        if model.restartPending { return model.text.string(.uiReadyInstallModuWillRestartAfterQuitting) }
        if case .verifying = model.downloadProgress { return model.text.string(.uiVerifyingInstaller) }
        if model.downloading { return model.text.string(.uiDownloadingInstaller) }
        if model.installing { return model.text.string(.uiPreparingUpdate) }
        return model.text.string(.uiCheckingGitHubReleases)
    }

    private func byteCount(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(model.text.locale.locale))
    }
}

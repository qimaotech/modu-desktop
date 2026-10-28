import Accessibility
import SwiftUI
import ModuCore

struct AppUpdateView: View {
    var model: AppUpdateModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingErrorDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(DesignStyle.windowTitle).accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let update = model.update {
                        Text(model.text.string(.uiUpdateVersionPrefix(ModuVersion.current)))
                            .foregroundStyle(DesignStyle.secondary)
                        Link(update.version, destination: update.releaseURL)
                            .help(model.text.string(.uiReleaseNotes))
                            .accessibilityHint(model.text.string(.uiReleaseNotes))
                    } else {
                        Text(model.text.string(.uiInstalledVersion(ModuVersion.current)))
                            .foregroundStyle(DesignStyle.secondary)
                    }
                }
                .font(DialogTypography.auxiliary)
            }
            .frame(minHeight: 44, alignment: .topLeading)

            status
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)

            HStack(spacing: 12) {
                Toggle(model.text.string(.uiAutomaticallyCheckForUpdates), isOn: Binding(
                    get: { model.automaticallyChecksForUpdates }, set: { model.automaticallyChecksForUpdates = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .font(DialogTypography.auxiliary)
                    .help(model.text.string(.uiAutomaticallyCheckForUpdatesHelp))
                    .disabled(model.restartPending)
                Spacer(minLength: 16)
                Button(action: performPrimaryAction) {
                    Text(primaryActionTitle).frame(minWidth: 120)
                }
                .keyboardShortcut(model.working ? nil : .defaultAction)
                .disabled(model.restartPending)
            }
            .controlSize(.regular)
        }
        .font(DialogTypography.body)
        .padding(24).frame(width: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .background(WindowCloseHandler(shouldQuit: { model.cancel(); return model.restartPending }))
        .onExitCommand {
            if model.working { model.cancel() }
            else { dismissWindow(id: "updates") }
        }
        .onChange(of: model.phase) { _, _ in
            showingErrorDetails = false
            AccessibilityNotification.Announcement(title).post()
        }
        .onAppear { model.windowOpened() }
        .onDisappear { model.windowClosed() }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if let details = model.errorDetails, !details.isEmpty, details != error {
                        DisclosureGroup(model.text.string(.uiDetails), isExpanded: $showingErrorDetails) {
                            ScrollView {
                                Text(details).font(DialogTypography.path)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 96)
                        }
                        .foregroundStyle(DesignStyle.secondary)
                    }
                }
                .textSelection(.enabled)
            } else {
                Text(statusDescription).foregroundStyle(DesignStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.working { progress }
        }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            Group {
                if let fraction { ProgressView(value: fraction) }
                else { ProgressView() }
            }
            .progressViewStyle(.linear).controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(fraction.map(percent) ?? statusDescription)
            HStack {
                Text(downloadSizeText ?? " ")
                Spacer()
                Text(fraction.map(percent) ?? " ")
            }
            .font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary).monospacedDigit()
            .accessibilityHidden(true)
        }
    }

    private var title: String {
        let resource: LocalizedStringResource
        switch model.phase {
        case .idle: resource = .uiSoftwareUpdate
        case .checking: resource = .uiCheckingForUpdates
        case .available: resource = .uiModuIsAvailable(model.update?.version ?? "")
        case .upToDate: resource = .uiModuIsUpToDate
        case .downloading: resource = .uiDownloadingInstaller
        case .verifying: resource = .uiVerifyingInstaller
        case .preparing: resource = .uiPreparingUpdate
        case .restarting: resource = .uiUpdateReady
        case .failed: resource = .uiUpdateFailed
        }
        return model.text.string(resource)
    }

    private var statusDescription: String {
        let resource: LocalizedStringResource
        switch model.phase {
        case .checking: resource = .uiCheckingGitHubReleases
        case .available: resource = .uiUpdateAvailableDescription
        case .upToDate: resource = .uiYouReRunningLatestVersionOfModu
        case .downloading: resource = .uiUpdateWorkspacesPreserved
        case .verifying: resource = .uiDownloadCompleteVerifyingInstaller
        case .preparing: resource = .uiPreparingUpdateRestartNotice
        case .restarting: resource = .uiReadyInstallModuWillRestartAfterQuitting
        case .idle, .failed: return ""
        }
        return model.text.string(resource)
    }

    private var primaryActionTitle: String {
        if model.restartPending { return model.text.string(.uiWaitingForModuQuit) }
        if model.working { return model.text.string(.uiCancelUpdate) }
        if model.update == nil { return model.text.string(.uiCheckAgain) }
        if model.error != nil { return model.text.string(model.downloadFailed ? .uiDownloadAgain : .uiRetry) }
        return model.text.string(.uiInstallAndRestart)
    }

    private var fraction: Double? {
        guard model.downloading, case let .downloading(receivedBytes, totalBytes) = model.downloadProgress, totalBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    private var downloadSizeText: String? {
        guard model.downloading, case let .downloading(receivedBytes, totalBytes) = model.downloadProgress else { return nil }
        if totalBytes > 0 { return "\(byteCount(receivedBytes)) / \(byteCount(totalBytes))" }
        return byteCount(receivedBytes)
    }

    private func performPrimaryAction() {
        if model.working { model.cancel() }
        else if model.update != nil { model.installAndRestart() }
        else { model.check() }
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(model.text.locale.locale))
    }

    private func byteCount(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(model.text.locale.locale))
    }
}

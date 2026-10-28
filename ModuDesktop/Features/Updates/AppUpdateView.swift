import Accessibility
import SwiftUI
import ModuCore

struct AppUpdateView: View {
    var model: AppUpdateModel
    var waitingForOperation = false
    var waitingForResult = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingErrorDetails = false
    private static let errorDetailsURL = URL(string: "modu://update-details")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DesignStyle.windowTitle)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let update = model.update {
                        Text(model.text.string(.uiUpdateVersionPrefix(ModuVersion.current)))
                            .foregroundStyle(DesignStyle.secondary)
                        Link(update.version, destination: update.releaseURL)
                            .padding(.vertical, 4).contentShape(Rectangle())
                            .help(model.text.string(.uiReleaseNotes))
                            .accessibilityHint(model.text.string(.uiReleaseNotes))
                    } else {
                        Text(model.text.string(.uiInstalledVersion(ModuVersion.current)))
                            .foregroundStyle(DesignStyle.secondary)
                    }
                }
                .font(DialogTypography.auxiliary)
                .frame(height: 21, alignment: .leading)
            }
            .frame(height: 48, alignment: .topLeading)

            ZStack(alignment: .topLeading) {
                Color.clear
                status
            }
            .frame(height: 56)

            HStack(spacing: 12) {
                Toggle(model.text.string(.uiAutomaticallyCheckForUpdates), isOn: Binding(
                    get: { model.automaticallyChecksForUpdates }, set: { model.automaticallyChecksForUpdates = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .font(DialogTypography.auxiliary)
                    .help(model.text.string(.uiAutomaticallyCheckForUpdatesHelp))
                    .disabled(model.restartPending)
                Spacer(minLength: 16)
                if !model.restartPending {
                    Button(action: performPrimaryAction) {
                        Text(primaryActionTitle).frame(minWidth: 120)
                    }
                    .keyboardShortcut(model.working ? nil : .defaultAction)
                }
            }
            .controlSize(.regular)
            .frame(height: 24)
        }
        .font(DialogTypography.body)
        .padding(24).frame(width: DesignStyle.sheetWidth, height: 200, alignment: .topLeading)
        .background(WindowCloseHandler(shouldQuit: { model.cancel(); return model.restartPending }))
        .onExitCommand {
            if model.working { model.cancel() }
            else { dismissWindow(id: "updates") }
        }
        .onChange(of: model.phase) { _, _ in
            showingErrorDetails = false
            AccessibilityNotification.Announcement(title).post()
        }
        .onChange(of: model.errorDetails) { _, _ in showingErrorDetails = false }
        .onAppear { model.windowOpened() }
        .onDisappear { model.windowClosed() }
    }

    @ViewBuilder private var status: some View {
        if let error = model.error {
            let details = model.errorDetails.flatMap { $0.isEmpty || $0 == error ? nil : $0 }
            ScrollView {
                Text(errorDescription(error, hasDetails: details != nil))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.errorDetailsURL else { return .systemAction }
                showingErrorDetails = true
                return .handled
            })
            .popover(isPresented: $showingErrorDetails, arrowEdge: .bottom) {
                if let details {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.text.string(.uiDetails)).font(DialogTypography.title)
                        ScrollView {
                            Text(details).font(DialogTypography.path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }.frame(width: 388, height: 128)
                    }.padding(16)
                }
            }
        } else if model.phase == .downloading {
            downloadProgress
        } else if model.working {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    .accessibilityLabel(title)
                Text(statusDescription).foregroundStyle(DesignStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !statusDescription.isEmpty {
            Text(statusDescription).foregroundStyle(DesignStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var downloadProgress: some View {
        VStack(spacing: 4) {
            Group {
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                }
            }
            .frame(height: 14).controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(fraction.map(percent) ?? downloadSizeText ?? title)
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
        case .restarting: resource = .uiQuittingModu
        case .failed:
            if model.update == nil { resource = .uiUpdateCheckFailed }
            else if model.downloadFailed { resource = .uiUpdateDownloadFailed }
            else { resource = .uiUpdateInstallFailed }
        }
        return model.text.string(resource)
    }

    private var statusDescription: String {
        let resource: LocalizedStringResource
        switch model.phase {
        case .checking: resource = .uiUpdateCheckingDescription
        case .available: resource = .uiUpdateAvailableDescription
        case .verifying: resource = .uiDownloadCompleteVerifyingInstaller
        case .preparing: resource = .uiPreparingUpdateRestartNotice
        case .restarting:
            if waitingForOperation { resource = .uiUpdateWaitingForOperation }
            else if waitingForResult { resource = .uiUpdateWaitingForResult }
            else { resource = .uiReadyInstallModuWillRestartAfterQuitting }
        case .idle, .failed, .downloading, .upToDate: return ""
        }
        return model.text.string(resource)
    }

    private var primaryActionTitle: String {
        if model.working { return model.text.string(.uiCancel) }
        if model.phase == .idle { return model.text.string(.uiCheckForUpdates) }
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

    private func errorDescription(_ error: String, hasDetails: Bool) -> AttributedString {
        var description = AttributedString(error)
        if hasDetails {
            description.append(AttributedString(" "))
            var link = AttributedString(model.text.string(.uiDetails))
            link.link = Self.errorDetailsURL
            description.append(link)
        }
        return description
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

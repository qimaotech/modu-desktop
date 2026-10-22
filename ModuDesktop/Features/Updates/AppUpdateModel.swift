import AppKit
import ModuCore
import Observation

@MainActor @Observable
final class AppUpdateModel {
    private let preferences: AppPreferences
    private let service: AppUpdateService
    private(set) var update: AppUpdate?
    private(set) var installerURL: URL?
    private(set) var checking = false
    private(set) var downloading = false
    private(set) var checked = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var requestID = UUID()
    var working: Bool { checking || downloading }

    init(preferences: AppPreferences, service: AppUpdateService = .init()) {
        self.preferences = preferences
        self.service = service
    }

    func check() {
        guard !working else { return }
        update = nil; installerURL = nil; error = nil; checked = false; checking = true
        let id = UUID()
        requestID = id
        task = Task {
            defer { if requestID == id { checking = false; task = nil } }
            do {
                let result = try await service.check()
                guard !Task.isCancelled, requestID == id else { return }
                update = result; checked = true
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = errorText(error)
            }
        }
    }

    func download() {
        guard !working, let update else { return }
        error = nil; downloading = true
        let id = UUID()
        requestID = id
        task = Task {
            defer { if requestID == id { downloading = false; task = nil } }
            do {
                let url = try await service.download(update)
                guard !Task.isCancelled, requestID == id else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                installerURL = url
                openInstaller()
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = errorText(error)
            }
        }
    }

    func cancel() {
        requestID = UUID()
        task?.cancel(); task = nil
        checking = false; downloading = false
    }

    func openInstaller() {
        guard let installerURL else { return }
        if !NSWorkspace.shared.open(installerURL) {
            error = t("Can’t open the installer. Reveal it in Finder and open it manually.", "无法打开安装包，请在 Finder 中显示并手动打开。")
        }
    }

    func revealInstaller() {
        if let installerURL { NSWorkspace.shared.activateFileViewerSelecting([installerURL]) }
    }

    func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

    private func errorText(_ error: Error) -> String {
        switch (error as? ModuError)?.code {
        case "update-asset-unavailable": t("The latest release has no compatible installer yet. Check the release page or try again later.", "最新版本尚未提供兼容的安装包，请查看发布页面或稍后重试。")
        case "update-integrity-failed": t("Installer verification failed. Please download it again.", "安装包校验失败，请重新下载。")
        case "update-version-invalid": t("The release version could not be compared. Please check the release page.", "无法比较发布版本，请查看发布页面。")
        default: t("Couldn’t contact GitHub or save the installer. ", "无法访问 GitHub 或保存安装包。") + error.localizedDescription
        }
    }
}

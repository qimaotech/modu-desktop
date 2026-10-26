import AppKit
import ModuCore
import Observation

@MainActor @Observable
final class AppUpdateModel {
    private let preferences: AppPreferences
    private let service: AppUpdateService
    private let installer: AppUpdateInstaller
    private let application: URL
    private let helper: URL?
    private let requestRestart: @MainActor () -> Void
    private(set) var update: AppUpdate?
    private(set) var installerURL: URL?
    private(set) var checking = false
    private(set) var downloading = false
    private(set) var installing = false
    private(set) var restartPending = false
    private(set) var checked = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    @ObservationIgnored var onRestartFailure: (@MainActor () -> Void)?
    private var requestID = UUID()
    private var prepared: PreparedAppUpdate?
    var working: Bool { checking || downloading || installing || restartPending }
    var needsTerminationPreparation: Bool { task != nil || cleanupTask != nil || restartPending }

    init(preferences: AppPreferences, service: AppUpdateService = .init(), installer: AppUpdateInstaller = .init(),
         application: URL = Bundle.main.bundleURL, helper: URL? = Bundle.main.url(forResource: "modu-cli", withExtension: nil),
         requestRestart: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.preferences = preferences
        self.service = service
        self.installer = installer
        self.application = application
        self.helper = helper
        self.requestRestart = requestRestart
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

    func installAndRestart() {
        guard !working, let update else { return }
        guard let helper else {
            error = t("The bundled update installer is missing. Reinstall Modu and try again.", "内置更新程序缺失，请重新安装 Modu 后重试。")
            return
        }
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.resolvingSymlinksInPath() == application.resolvingSymlinksInPath()
        }) else {
            error = t("Quit other instances of Modu before installing the update.", "请先退出其他正在运行的 Modu 实例，再安装更新。")
            return
        }
        runInstallation { [self] id in
            if installerURL == nil {
                downloading = true
                let url = try await service.download(update)
                guard !Task.isCancelled, requestID == id else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                installerURL = url
                downloading = false
            }
            guard let installerURL else { return }
            let prepared = try await installer.prepare(installer: installerURL, update: update, application: application, helper: helper)
            guard !Task.isCancelled, requestID == id else {
                installer.discard(prepared)
                return
            }
            restart(afterPreparing: prepared)
        }
    }

    func runInstallation(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard !working else { return }
        error = nil; installing = true
        let id = UUID()
        requestID = id
        // Cancellation can append this installation to cleanupTask, so capture only earlier cleanup.
        let previousCleanup = cleanupTask
        task = Task {
            defer { if requestID == id { downloading = false; installing = false; task = nil } }
            do {
                await previousCleanup?.value
                guard !Task.isCancelled, requestID == id else { return }
                cleanupTask = nil
                try await operation(id)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                if (error as? ModuError)?.code == "update-integrity-failed" { installerURL = nil }
                self.error = errorText(error)
            }
        }
    }

    func cancel() {
        guard !restartPending else { return }
        requestID = UUID()
        if let task {
            task.cancel()
            let previousCleanup = cleanupTask
            cleanupTask = Task { await previousCleanup?.value; await task.value }
        }
        task = nil
        checking = false; downloading = false; installing = false
    }

    func prepareToTerminate() async -> Bool {
        await cleanupTask?.value
        cleanupTask = nil
        if let prepared {
            if handoffTask != nil { return true }
            do {
                try await installer.launch(prepared)
                monitorHandoff(prepared)
                return true
            } catch {
                finishFailedRestart(error, identifier: prepared.identifier)
                return false
            }
        }
        cancel()
        await cleanupTask?.value
        cleanupTask = nil
        return true
    }

    func restart(afterPreparing prepared: PreparedAppUpdate) {
        guard !restartPending else { return }
        self.prepared = prepared
        restartPending = true
        requestRestart()
    }

    private func monitorHandoff(_ prepared: PreparedAppUpdate) {
        let installer = installer
        handoffTask = Task { [weak self] in
            do {
                let failure = try await installer.waitForFailure(prepared)
                guard !Task.isCancelled else { return }
                self?.finishFailedRestart(failure, identifier: prepared.identifier)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishFailedRestart(error, identifier: prepared.identifier)
            }
        }
    }

    private func finishFailedRestart(_ error: Error, identifier: UUID) {
        guard let prepared, prepared.identifier == identifier else { return }
        installer.cancelHandoff(prepared)
        handoffTask?.cancel(); handoffTask = nil
        self.prepared = nil; restartPending = false
        self.error = errorText(error)
        onRestartFailure?()
    }

    func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

    private func errorText(_ error: Error) -> String {
        switch (error as? ModuError)?.code {
        case "update-asset-unavailable": t("The latest release has no compatible installer yet. Check the release page or try again later.", "最新版本尚未提供兼容的安装包，请查看发布页面或稍后重试。")
        case "update-integrity-failed": t("Installer verification failed. Please download it again.", "安装包校验失败，请重新下载。")
        case "update-version-invalid": t("The release version could not be compared. Please check the release page.", "无法比较发布版本，请查看发布页面。")
        case "update-location-unwritable": t("Modu can’t update in this location. Move it to a writable Applications folder and try again.", "无法在当前位置更新 Modu，请将应用移至可写入的 Applications 文件夹后重试。")
        case "update-system-unsupported": t("This update requires a newer version of macOS.", "此更新需要更高版本的 macOS。")
        case "update-exit-timeout": t("Modu did not exit in time. The update was not installed. Please try again.", "Modu 未能及时退出，尚未安装更新，请重试。")
        default: t("Couldn’t complete the update. ", "无法完成更新。") + error.localizedDescription
        }
    }
}

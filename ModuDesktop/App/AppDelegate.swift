import SwiftUI
import AppKit
import ModuCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var mainWindow: NSWindow?
    private(set) var startupTask: Task<Void, Never>?
    var reopenWindow: (() -> Void)?

    func start(model: AppModel, onReady: @escaping @MainActor () -> Void, onFinished: @escaping @MainActor (Bool) -> Void) {
        guard startupTask == nil, !model.started else { return }
        self.model = model
        startupTask = Task {
            defer { startupTask = nil }
            let needsCLISetup = await model.start(onReady: onReady)
            guard !Task.isCancelled else { return }
            onFinished(needsCLISetup)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenWindow?() }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        model?.mockWorkspace?.remove()
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true { model?.presentation.quitPending = true; model?.cancel(); return .terminateCancel }
        if model?.presentation.result != nil { model?.presentation.quitPending = true; return .terminateCancel }
        if let startupTask {
            model?.presentation.quitPending = true
            startupTask.cancel()
            Task {
                await startupTask.value
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

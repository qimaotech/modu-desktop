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
        model.globalShortcut.start { [weak self] in self?.toggleVisibility() }
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
        model?.updates.cancel()
        model?.globalShortcut.stop()
        #if DEBUG
        model?.mockWorkspace?.remove()
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, model.busy {
            guard model.operations.canCancel || model.cancelling else { return .terminateCancel }
            model.presentation.quitPending = true; model.cancel()
            return .terminateCancel
        }
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

    private func toggleVisibility() {
        if NSApp.isActive, !NSApp.isHidden, NSApp.orderedWindows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }) {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        let window = NSApp.orderedWindows.first(where: { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized })
            ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isMiniaturized })
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.attachedSheet?.makeKeyAndOrderFront(nil)
        } else { reopenWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }
}

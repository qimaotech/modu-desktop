import SwiftUI
import AppKit
import ModuCore
import Observation

@MainActor @Observable final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    @ObservationIgnored private(set) weak var mainWindow: NSWindow?
    private(set) var mainWindowIsOpen = false
    private(set) var startupTask: Task<Void, Never>?
    private(set) var terminationTask: Task<Void, Never>?
    private var terminationPrepared = false
    private let terminate: (NSApplication) -> Void
    var reopenWindow: (() -> Void)?

    override convenience init() {
        self.init(terminate: { $0.terminate(nil) })
    }

    init(terminate: @escaping (NSApplication) -> Void) {
        self.terminate = terminate
        super.init()
    }

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
        if model?.relaunch.restartPending != true { model?.mockWorkspace?.remove() }
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationTask != nil { return .terminateCancel }
        if let model, model.busy {
            if model.updates.restartPending || model.relaunch.restartPending { model.presentation.quitPending = true }
            if model.workspace.isReloading {
                model.presentation.quitPending = true
                return .terminateCancel
            }
            guard model.operations.canCancel || model.cancelling else { return .terminateCancel }
            model.presentation.quitPending = true; model.cancel()
            return .terminateCancel
        }
        if model?.presentation.result != nil { model?.presentation.quitPending = true; return .terminateCancel }
        if terminationPrepared { return .terminateNow }
        if startupTask != nil || model?.updates.needsTerminationPreparation == true || model?.relaunch.restartPending == true {
            let model = model
            model?.presentation.quitPending = true
            let startupTask = startupTask
            let relaunchRequested = model?.relaunch.restartPending == true
            startupTask?.cancel()
            terminationTask = Task {
                await startupTask?.value
                var canTerminate = await model?.updates.prepareToTerminate() ?? true
                if canTerminate { canTerminate = await model?.relaunch.prepareToTerminate() ?? true }
                terminationTask = nil
                guard canTerminate, !relaunchRequested || model?.relaunch.restartPending == true else { model?.presentation.quitPending = false; return }
                terminationPrepared = true
                defer { terminationPrepared = false }
                terminate(sender)
            }
            // A deferred AppKit quit runs a modal loop that can starve these MainActor tasks.
            return .terminateCancel
        }
        return .terminateNow
    }

    func observeMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        if let mainWindow { NotificationCenter.default.removeObserver(self, name: nil, object: mainWindow) }
        mainWindow = window
        mainWindowIsOpen = window.isVisible || window.isMiniaturized
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose), name: NSWindow.willCloseNotification, object: window)
    }

    func returnToMainWindow() {
        guard mainWindowIsOpen, let mainWindow else { return }
        NSApp.unhide(nil)
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.attachedSheet?.makeKeyAndOrderFront(nil)
    }

    @objc private func mainWindowDidBecomeKey() { mainWindowIsOpen = true }
    @objc private func mainWindowWillClose() { mainWindowIsOpen = false }

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

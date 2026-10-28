import SwiftUI
import AppKit
import ModuCore

struct ModuDesktopApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.launch()
    @State private var startupCompleted = false
    @State private var startupNeedsSetup = false
    @State private var startupWindowReady = false
    @State private var chromeHeight: CGFloat = 0
    @State private var setupChromeHeight: CGFloat = 32
    @State private var settingsChromeHeight: CGFloat = 32
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Modu", id: "main") {
            ContentView(model: model, chromeHeight: chromeHeight, startupCompleted: startupCompleted)
                .onAppear { delegate.model = model }
                .frame(minWidth: 900, minHeight: 600 - chromeHeight)
                .background(WindowChromeHeight(height: $chromeHeight, onWindow: configureMainWindow))
                .environment(\.locale, model.preferences.activeLocale.locale)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .onChange(of: scenePhase, initial: true) { _, _ in
            delegate.model = model
            guard !TestHost.isEnabled() else { return }
            if startupCompleted, scenePhase == .active { checkForUpdatesAutomatically() }
            delegate.reopenWindow = {
                guard startupWindowReady else { return }
                openWindow(id: model.workspace.record != nil || model.workspace.blocked != nil ? "main" : "setup")
            }
            delegate.start(model: model, onReady: {
                guard model.hasSavedWorkspace else { return }
                startupWindowReady = true
                openWindow(id: "main")
            }, onFinished: { needsCLISetup in
                startupCompleted = true
                if needsCLISetup || !model.hasSavedWorkspace { startupNeedsSetup = true }
                checkForUpdatesAutomatically()
            })
        }
        .onChange(of: canPresentStartupSetup) { _, present in
            guard present else { return }
            startupNeedsSetup = false; startupWindowReady = true
            openWindow(id: "setup"); dismissWindow(id: "main")
        }
        .onChange(of: canPresentAutomaticUpdate) { _, present in
            guard present else { return }
            model.updates.windowOpened()
            openWindow(id: "updates")
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands { AppCommands(model: model, startupWindowReady: startupWindowReady) }
        Window(model.text.string(.uiSetUpWorkspace), id: "setup") {
            SetupView(model: model, canReturnToMainWindow: { delegate.mainWindowIsOpen }, returnToMainWindow: delegate.returnToMainWindow).id(model.workspace.record?.root)
                .environment(\.locale, model.preferences.activeLocale.locale)
                .onAppear { delegate.model = model }.frame(width: 560).frame(minHeight: 320 - setupChromeHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(WindowChromeHeight(height: $setupChromeHeight))
                .background(WindowCloseHandler(shouldQuit: { !delegate.mainWindowIsOpen }, onClose: delegate.returnToMainWindow))
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        Window(model.text.string(.uiSoftwareUpdate), id: "updates") {
            AppUpdateView(model: model.updates)
                .environment(\.locale, model.preferences.activeLocale.locale)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        Settings {
            SettingsView(model: model).frame(width: 640, height: 480 - settingsChromeHeight)
                .background(WindowChromeHeight(height: $settingsChromeHeight))
                .background(SettingsWindowPlacement(size: CGSize(width: 640, height: 480), sourceWindow: { delegate.mainWindow }))
                .environment(\.locale, model.preferences.activeLocale.locale)
        }
        .windowToolbarStyle(.unifiedCompact)
    }
    private var canPresentStartupSetup: Bool {
        startupNeedsSetup && !model.busy && model.management.sheet == nil && model.presentation.result == nil && model.presentation.message == nil && !model.presentation.quitPending
    }

    private var canPresentAutomaticUpdate: Bool {
        startupWindowReady && scenePhase == .active && model.updates.automaticUpdatePending && !model.updates.working
            && !model.busy && model.management.sheet == nil && model.presentation.result == nil
            && model.presentation.message == nil && !model.presentation.quitPending
    }

    private func checkForUpdatesAutomatically() {
        guard !model.presentation.quitPending else { return }
        #if DEBUG
        guard model.mockWorkspace == nil else { return }
        #endif
        model.updates.checkAutomatically()
    }

    private func configureMainWindow(_ window: NSWindow) {
        if window.styleMask.contains(.fullSizeContentView) {
            let frame = window.frame
            // Keeping content below the toolbar preserves its native separator during live resizing.
            window.styleMask.remove(.fullSizeContentView)
            window.setFrame(frame, display: false)
        }
        window.titlebarSeparatorStyle = .line
        delegate.observeMainWindow(window)
    }
}

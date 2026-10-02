import SwiftUI
import AppKit
import ModuCore

@main
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
                .environment(\.locale, Locale(identifier: model.language))
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .onChange(of: scenePhase, initial: true) { _, _ in
            delegate.model = model
            guard !TestHost.isEnabled() else { return }
            delegate.reopenWindow = {
                guard startupWindowReady else { return }
                openWindow(id: model.workspace != nil || model.blocked != nil ? "main" : "setup")
            }
            delegate.start(model: model, onReady: {
                guard model.hasSavedWorkspace else { return }
                startupWindowReady = true
                openWindow(id: "main")
            }, onFinished: { needsCLISetup in
                startupCompleted = true
                if needsCLISetup || !model.hasSavedWorkspace { startupNeedsSetup = true }
            })
        }
        .onChange(of: canPresentStartupSetup) { _, present in
            guard present else { return }
            startupNeedsSetup = false; startupWindowReady = true
            openWindow(id: "setup"); dismissWindow(id: "main")
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .singleWindowList) {
                Button("Modu") { openWindow(id: "main") }.disabled(!startupWindowReady)
                Button(model.t("Modu Setup", "Modu 设置")) { openWindow(id: "setup") }.disabled(model.busy || !startupWindowReady)
            }
            CommandGroup(after: .newItem) {
                Button(model.t("Reload Workspace", "重新加载工作区")) { model.requestReload() }.disabled(!model.hasSavedWorkspace)
                Button(model.t("Refresh Changes", "刷新更改")) { model.refreshDetail() }.keyboardShortcut("r").disabled(model.selection == nil)
                Button(model.t("Open Workspace in Codex", "在 Codex 中打开工作区")) { if let codex = model.tools.first(where: { $0.id == "codex" }) { model.openTool(codex, workspaceRoot: true) } }.disabled(model.workspace == nil || !model.tools.contains { $0.id == "codex" })
                    .help(model.t("Start Codex from the workspace root to discover the workflow skill.", "从工作区根目录启动 Codex 以发现工作流技能。"))
                    .accessibilityHint(model.t("Start Codex from the workspace root to discover the workflow skill.", "从工作区根目录启动 Codex 以发现工作流技能。"))
            }
            CommandMenu(model.t("Actions", "操作")) {
                Button(model.t("Add Repository…", "添加仓库…")) { model.sheet = .add }.keyboardShortcut("n").disabled(model.busy || model.workspace == nil)
                Button(model.t("Create Worktree Group…", "创建工作树组…")) { model.sheet = .create }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy || model.sortedRepositories.isEmpty)
                Button(model.t("Update Repositories", "更新仓库")) { model.update() }.disabled(model.busy || model.sortedRepositories.isEmpty)
                Divider()
                ResourceActions(model: model, resource: model.selection)
            }
        }
        Window(model.t("Set Up Workspace", "设置工作区"), id: "setup") {
            SetupView(model: model).onAppear { delegate.model = model }.frame(width: 720, height: 520 - setupChromeHeight)
                .background(WindowChromeHeight(height: $setupChromeHeight))
                .background(WindowCloseHandler(quit: !model.hasSavedWorkspace))
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        Settings {
            SettingsView(model: model).frame(width: 640, height: 480 - settingsChromeHeight)
                .background(WindowChromeHeight(height: $settingsChromeHeight))
                .background(SettingsWindowPlacement(size: CGSize(width: 640, height: 480), sourceWindow: { delegate.mainWindow }))
                .environment(\.locale, Locale(identifier: model.language))
        }
        .windowToolbarStyle(.unifiedCompact)
    }
    private var canPresentStartupSetup: Bool {
        startupNeedsSetup && !model.busy && model.sheet == nil && model.result == nil && model.message == nil && !model.quitPending
    }

    private func configureMainWindow(_ window: NSWindow) {
        if window.styleMask.contains(.fullSizeContentView) {
            let frame = window.frame
            // Keeping content below the toolbar preserves its native separator during live resizing.
            window.styleMask.remove(.fullSizeContentView)
            window.setFrame(frame, display: false)
        }
        window.titlebarSeparatorStyle = .line
        delegate.mainWindow = window
    }
}

struct WindowChromeHeight: NSViewRepresentable {
    @Binding var height: CGFloat
    var onWindow: ((NSWindow) -> Void)? = nil
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow?(window)
            let measured = window.frame.height - window.contentLayoutRect.height
            if height != measured { height = measured }
        }
    }
}

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
        if model?.busy == true { model?.quitPending = true; model?.cancel(); return .terminateCancel }
        if model?.result != nil { model?.quitPending = true; return .terminateCancel }
        if let startupTask {
            model?.quitPending = true
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


struct WindowCloseHandler: NSViewRepresentable {
    var quit: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.quit = quit
            if window.delegate !== context.coordinator { context.coordinator.original = window.delegate; window.delegate = context.coordinator }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, NSWindowDelegate {
        var quit = false
        weak var original: (any NSWindowDelegate)?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if quit { NSApp.terminate(nil); return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}

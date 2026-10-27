import Foundation
import AppKit
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct SetupModelTests {
    @Test(arguments: [false, true])
    func setupCompletesAndSkillConflictsCanBeRetried(_ conflict: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let suite = fixture.directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ExternalTools(applicationURL: { id in
            id == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil
        }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools)
        let setup = SetupModel(model: model)
        let skill = fixture.root.appending(path: ".agents/skills/modu-workflow")
        if conflict {
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("user skill".utf8).write(to: skill)
        }
        await setup.checkCandidate(fixture.root)
        var ready = false
        let onReady: @MainActor () -> Void = {
            ready = true
        }
        setup.continueSetup(onReady: onReady)
        let operation = try #require(model.operation)
        #expect(model.busy && model.operations.kind == .setup && setup.settingUp)
        await operation.value
        #expect(!model.busy && model.operation == nil && !setup.working && !setup.settingUp)
        if conflict {
            #expect(!ready && model.workspace.record == nil && setup.skillConflict && setup.error != nil)
            #expect(try String(contentsOf: skill, encoding: .utf8) == "user skill")
            setup.continueSetup(onReady: onReady)
            await (try #require(model.operation)).value
        }
        #expect(ready && model.workspace.record?.root == fixture.root.path && model.hasSavedWorkspace)
        #expect(model.tools.map(\.id) == ["codex"])
        #expect(model.presentation.resultHost == .main && model.presentation.result == nil && !model.busy)
        await model.workspace.detailPreloadTask?.value
    }

    @Test(arguments: [false, true])
    func closingSetupReturnsToAnOpenMainWindow(_ miniaturized: Bool) {
        let delegate = AppDelegate()
        let main = MainWindowStub(miniaturized: miniaturized)
        delegate.observeMainWindow(main)
        var quitRequested = false
        let handler = WindowCloseHandler.Coordinator(shouldQuit: { !delegate.mainWindowIsOpen }, onClose: delegate.returnToMainWindow, terminate: { quitRequested = true })

        #expect(delegate.mainWindowIsOpen)
        #expect(handler.windowShouldClose(NSWindow()))
        #expect(main.broughtToFront && main.deminiaturized == miniaturized)
        #expect(!quitRequested)
    }

    @Test func closingSetupQuitsWhenTheMainWindowIsAbsentOrClosed() {
        let delegate = AppDelegate()
        var quitRequests = 0
        let handler = WindowCloseHandler.Coordinator(shouldQuit: { !delegate.mainWindowIsOpen }, onClose: delegate.returnToMainWindow, terminate: { quitRequests += 1 })
        let setup = NSWindow()

        #expect(!handler.windowShouldClose(setup) && quitRequests == 1)
        let main = MainWindowStub(miniaturized: false)
        delegate.observeMainWindow(main)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: main)
        main.open = false
        delegate.observeMainWindow(main)

        #expect(!delegate.mainWindowIsOpen)
        #expect(!handler.windowShouldClose(setup) && quitRequests == 2)
        #expect(!main.broughtToFront)

        main.open = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: main)
        #expect(delegate.mainWindowIsOpen)
        #expect(handler.windowShouldClose(setup) && quitRequests == 2)
        #expect(main.broughtToFront)
    }

    private final class MainWindowStub: NSWindow {
        var open = true
        let initiallyMiniaturized: Bool
        private(set) var deminiaturized = false
        private(set) var broughtToFront = false

        init(miniaturized: Bool) {
            initiallyMiniaturized = miniaturized
            super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        }

        override var isVisible: Bool { open && !initiallyMiniaturized }
        override var isMiniaturized: Bool { initiallyMiniaturized }
        override func deminiaturize(_ sender: Any?) { deminiaturized = true }
        override func makeKeyAndOrderFront(_ sender: Any?) { broughtToFront = true }
    }
}

import XCTest
import AppKit
import ModuCore

final class ModuDesktopUITests: XCTestCase {
    private var temporary: URL!
    private var suite: String!
    override func setUpWithError() throws {
        continueAfterFailure = false
        temporary = FileManager.default.temporaryDirectory.appending(path: "modu-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        suite = "ModuUITests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)?.set("en", forKey: "language")
    }
    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
    }
    @MainActor
    func testSetupRequiresCLI() throws {
        let app = try application(cliInstalled: false)
        app.launch()
        let install = app.buttons["Install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Choose…"].isEnabled)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Choose Workspace", "Choose Workspace")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Select a writable local directory"].exists)
        attach(app, name: "Setup")
        app.terminate()
    }
    @MainActor
    func testButtonHoverBackgrounds() throws {
        let root = temporary.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))

        let addButtons = app.buttons.matching(identifier: "Add Repository").allElementsBoundByIndex
        let add = try XCTUnwrap(addButtons.first { $0.frame.width > 24 })
        let icon = try XCTUnwrap(addButtons.first { $0.frame.width <= 24 })
        add.hover()
        try assertGradient(add)
        icon.hover()
        try assertGradient(icon)
        let corner = try pixel(icon, x: 0.08, y: 0.08)
        XCTAssertGreaterThan(corner.redComponent, 0.98)
        XCTAssertGreaterThan(try pixel(add, x: 0.5, y: 0.1).redComponent, 0.98)

        let codex = app.buttons["Codex"]
        let menu = app.descendants(matching: .any).matching(identifier: "Choose tool Agent").firstMatch
        if codex.exists && menu.exists {
            codex.hover()
            try assertGradient(codex)
            XCTAssertGreaterThan(try pixel(menu, x: 0.5, y: 0.1).redComponent, 0.98)
            menu.hover()
            try assertGradient(menu)
            XCTAssertGreaterThan(try pixel(codex, x: 0.5, y: 0.1).redComponent, 0.98)
        }
        add.click()
        XCTAssertTrue(app.textFields["repositoryURL"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        app.typeKey(",", modifierFlags: .command)
        let change = app.buttons["changeWorkspace"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        app.windows["Settings"].click()
        change.click()
        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 5))
        app.buttons["CancelButton"].click()

        func assertGradient(_ element: XCUIElement) throws {
            let top = try pixel(element, x: 0.5, y: 0.1)
            let bottom = try pixel(element, x: 0.5, y: 0.9)
            // Screen captures include the display color profile; PresentationTests checks the exact sRGB stops.
            XCTAssertLessThan(top.redComponent, bottom.redComponent - 0.025)
            XCTAssertLessThan(top.redComponent, 0.95)
            XCTAssertEqual(top.redComponent, top.greenComponent, accuracy: 0.025)
            XCTAssertEqual(bottom.redComponent, bottom.greenComponent, accuracy: 0.025)
        }
        func pixel(_ element: XCUIElement, x: CGFloat, y: CGFloat) throws -> NSColor {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: element.screenshot().pngRepresentation))
            return try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(bitmap.pixelsWide) * x), y: Int(CGFloat(bitmap.pixelsHigh) * y))?.usingColorSpace(.sRGB))
        }
    }
    @MainActor
    func testRepositorySearchKeepsHiddenSelectionsAndDoesNotSubmitOnReturn() throws {
        let root = temporary.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = WorkspaceStore(support: temporary.appending(path: "support"))
        var workspace = WorkspaceRecord(root: PathSafety.canonical(root).path)
        for name in ["repositories", "worktrees"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: false)
        }
        let names = ["repo-front", "repo-server"] + (1...7).map { "repo-other-\($0)" }
        workspace.repositories = names.map { Repository(url: "https://example.invalid/\($0).git") }
        for repo in workspace.repositories {
            try FileManager.default.createDirectory(at: workspace.repositoryURL(repo.id), withIntermediateDirectories: false)
        }
        try store.save(workspace)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "Create Worktree Group").firstMatch.click()
        let search = app.searchFields["repositorySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let groupName = app.textFields["groupName"]
        groupName.click()
        groupName.typeText("feature-search")
        XCTAssertEqual(groupName.value as? String, "feature-search")
        let create = app.buttons["Create"]
        let originalFrame = create.frame

        app.typeKey("f", modifierFlags: .command)
        app.typeText("FRONT")
        XCTAssertEqual(search.value as? String, "FRONT", app.debugDescription)
        let front = app.checkBoxes["repository-repo-front"]
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes["repository-repo-server"].exists)
        front.click()
        XCTAssertEqual(app.staticTexts["repositorySelectionCount"].value as? String, "1 / 9 selected")
        search.click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.exists)
        XCTAssertTrue(create.isEnabled)
        XCTAssertEqual(create.frame, originalFrame)

        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("server")
        XCTAssertEqual(search.value as? String, "server", app.debugDescription)
        let server = app.checkBoxes["repository-repo-server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.click()
        XCTAssertEqual(app.staticTexts["repositorySelectionCount"].value as? String, "2 / 9 selected")
        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("unmatched")
        XCTAssertTrue(app.staticTexts["No matching repositories"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["repositoryMatches"].value as? String, "0 matches")
        XCTAssertEqual(app.staticTexts["repositorySelectionCount"].value as? String, "2 / 9 selected")
        XCTAssertTrue(create.isEnabled)
        XCTAssertEqual(create.frame, originalFrame)
        app.descendants(matching: .any).matching(identifier: "clearRepositorySearch").firstMatch.click()
        XCTAssertEqual(search.value as? String, "")
        XCTAssertEqual((front.value as? NSNumber)?.boolValue, true)
        XCTAssertEqual((server.value as? NSNumber)?.boolValue, true)
        app.buttons["Cancel"].click()
        XCTAssertEqual(try store.load(root), workspace)
    }

    @MainActor
    func testEmptyWorkspaceFormAndLanguageSettings() async throws {
        let root = temporary.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let service = WorkspaceService(store: WorkspaceStore(support: temporary.appending(path: "support")))
        let opened = await service.openWorkspace(root)
        XCTAssertEqual(opened.status, "success")
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "Add Repository").firstMatch.click()
        let url = app.textFields["repositoryURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click(); url.typeText("/tmp/not-a-remote")
        app.buttons["Add"].click()
        XCTAssertTrue(app.staticTexts["Use an HTTPS, SSH, or SCP-style Git URL without embedded credentials."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        attach(app, name: "Settings")
        app.terminate()
    }
    @MainActor
    func testSidebarExpansionIsRestoredOnRelaunch() async throws {
        let root = temporary.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))

        let repositories = app.buttons["repositories"]
        let worktrees = app.buttons["worktrees"]
        XCTAssertTrue(repositories.waitForExistence(timeout: 5))
        XCTAssertEqual(repositories.value as? String, "Expanded")
        XCTAssertEqual(worktrees.value as? String, "Expanded")
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Modu Setup"].click()
        XCTAssertTrue(app.buttons["Choose…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose…"].isEnabled)
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 5))
        repositories.click()
        worktrees.click()
        XCTAssertEqual(repositories.value as? String, "Collapsed")
        XCTAssertEqual(worktrees.value as? String, "Collapsed")
        app.terminate()

        app.launch()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        XCTAssertEqual(repositories.value as? String, "Collapsed")
        XCTAssertEqual(worktrees.value as? String, "Collapsed")
    }

    @MainActor
    func testDeletedCLIPathOpensSetupOnRelaunch() throws {
        let root = temporary.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.terminate()
        let store = WorkspaceStore(support: temporary.appending(path: "support"))
        let record = try Data(contentsOf: store.recordURL(root))
        try FileManager.default.removeItem(at: temporary.appending(path: "bin/modu-cli"))

        app.launch()
        XCTAssertTrue(app.buttons["Install"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Choose…"].isEnabled)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertFalse(app.windows["Modu"].exists)
        XCTAssertFalse(app.windows["workspace"].exists)
        XCTAssertEqual(try Data(contentsOf: store.recordURL(root)), record)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Install"].exists)
    }

    @MainActor
    func testChangeWorkspaceCreatesDirectlyAndCancelKeepsWorkspace() async throws {
        let root = temporary.appending(path: "current-workspace")
        let candidate = temporary.appending(path: "candidate-workspace")
        for directory in [root, candidate] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let service = WorkspaceService(store: WorkspaceStore(support: temporary.appending(path: "support")))
        let opened = await service.openWorkspace(root)
        XCTAssertEqual(opened.status, "success")
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let change = app.buttons["changeWorkspace"]
        let currentWorkspace = app.windows["Settings"].staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", root.lastPathComponent, root.lastPathComponent)).firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.click()
        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Set Up Workspace"].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(change.isEnabled)
        XCTAssertTrue(currentWorkspace.exists)

        change.click()
        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(candidate.path)
        app.typeKey(.return, modifierFlags: [])
        app.buttons["Open"].click()
        let selectedPath = app.windows["Settings"].staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", candidate.lastPathComponent, candidate.lastPathComponent)).firstMatch
        XCTAssertTrue(selectedPath.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Set Up Workspace"].exists)
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.appending(path: ".git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.store.recordURL(candidate).path))
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.click()
        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertTrue(selectedPath.exists)
    }

    @MainActor private func application(cliInstalled: Bool = true) throws -> XCUIApplication {
        let support = temporary.appending(path: "support")
        let executable = InstallationService(support: support).executable
        let bin = temporary.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("PATH=\"$MODU_TEST_HOME_DIRECTORY/bin\"\n".utf8).write(to: temporary.appending(path: ".zprofile"))
        if cliInstalled {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The sandboxed UI runner quarantines executable files it writes; use a system executable as the CLI stand-in.
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            try FileManager.default.createSymbolicLink(at: bin.appending(path: "modu-cli"), withDestinationURL: executable)
        }
        let app = XCUIApplication()
        app.launchEnvironment["MODU_TEST_SUPPORT_DIRECTORY"] = support.path
        app.launchEnvironment["MODU_TEST_DEFAULTS"] = suite
        app.launchEnvironment["MODU_TEST_HOME_DIRECTORY"] = temporary.path
        app.launchEnvironment["MODU_TEST_LOGIN_SHELL"] = "/bin/zsh"
        app.launchEnvironment["ZDOTDIR"] = temporary.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        return app
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

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
    func testInstalledCLIWithoutSavedWorkspaceShowsSetupDirectly() throws {
        let app = try application()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Installed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Set Up Workspace"].exists)
        XCTAssertFalse(app.windows["Modu"].exists)
        XCTAssertTrue(app.buttons["Choose…"].isEnabled)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
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
    func testTitlebarSeparatorKeepsNativeThicknessAfterResizing() throws {
        let root = temporary.appending(path: "titlebar-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        let window = app.windows["titlebar-workspace"]
        XCTAssertEqual(window.frame.height, 800, accuracy: 1)
        try assertSeparatorVisible()

        for width: CGFloat in [900, 1200, 1000, 1200] {
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
            edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: width - window.frame.width, dy: 0)))
            XCTAssertEqual(window.frame.width, width, accuracy: 2)
            XCTAssertEqual(window.frame.height, 800, accuracy: 1)
            try assertSeparatorVisible()
        }

        func assertSeparatorVisible() throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
            let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
            let boundary = Int((app.toolbars.firstMatch.frame.maxY - window.frame.minY) * scale)
            for fraction: CGFloat in [0.1, 0.75, 0.9] {
                let x = Int(CGFloat(bitmap.pixelsWide) * fraction)
                let content = try XCTUnwrap(bitmap.colorAt(x: x, y: boundary + Int(4 * scale))?.usingColorSpace(.sRGB))
                let rows = boundary - Int(2 * scale)...boundary + Int(2 * scale)
                let contrasts = try rows.map { y in
                    let line = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    return abs(line.redComponent - content.redComponent)
                }
                let separatorPixels = contrasts.filter { $0 > 0.025 }.count
                XCTAssertEqual(separatorPixels, Int(scale.rounded()), "Titlebar separator must stay one point thick at width \(window.frame.width)")
            }
        }
    }
    @MainActor
    func testSettingsCentersOnOpenAndReopenAndPreservesPositionWhileVisible() throws {
        let root = temporary.appending(path: "settings-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        let mainFrame = app.windows.firstMatch.frame
        let desktopTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let screen = try XCTUnwrap(NSScreen.screens.first {
            let frame = $0.frame
            return CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
                .contains(CGPoint(x: mainFrame.midX, y: mainFrame.midY))
        })
        let visible = screen.visibleFrame
        let center = CGPoint(x: visible.midX, y: desktopTop - visible.midY)

        app.menuBars.menuBarItems["Modu"].click()
        app.menuItems["Settings…"].click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        assertCentered()

        let titlebar = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 16))
        titlebar.click(forDuration: 0.1, thenDragTo: titlebar.withOffset(CGVector(dx: 80, dy: 60)))
        let moved = settings.frame
        XCTAssertGreaterThan(abs(moved.midX - center.x), 40)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.matching(identifier: "Settings").count, 1)
        XCTAssertEqual(settings.frame.minX, moved.minX, accuracy: 1)
        XCTAssertEqual(settings.frame.minY, moved.minY, accuracy: 1)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        assertCentered()

        func assertCentered() {
            let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = settings.frame
                return abs(frame.width - 640) <= 1 && abs(frame.height - 480) <= 1
                    && abs(frame.midX - center.x) <= 1 && abs(frame.midY - center.y) <= 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        }
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
        try FileManager.default.removeItem(at: temporary.appending(path: ".local/bin/modu-cli"))

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
    func testReinstallCLIResumesSavedWorkspaceWithoutRelaunch() async throws {
        let root = temporary.appending(path: "saved-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        let installed = await ExternalTools().available()
        let expectedTools = ["Agent", "Editor"].compactMap { category in installed.first { $0.category == category } }
        for tool in expectedTools { UserDefaults(suiteName: suite)?.set(tool.id, forKey: "tool.\(tool.category)") }
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.terminate()
        let store = WorkspaceStore(support: temporary.appending(path: "support"))
        let record = try Data(contentsOf: store.recordURL(root))
        try FileManager.default.removeItem(at: temporary.appending(path: ".local/bin/modu-cli"))
        // Replace the initial system-executable stand-in with the app's real CLI installation.
        try FileManager.default.removeItem(at: InstallationService(support: store.support).executable)
        app.launch()
        let candidate = app.staticTexts["workspaceCandidate"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        XCTAssertEqual(candidate.value as? String, PathSafety.canonical(root).path)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertEqual(try Data(contentsOf: store.recordURL(root)), record)
        app.buttons["Install"].click()
        XCTAssertTrue(app.staticTexts["Installed"].waitForExistence(timeout: 15))
        XCTAssertEqual(candidate.value as? String, PathSafety.canonical(root).path)
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.windows["saved-workspace"].exists)
        for tool in expectedTools { XCTAssertTrue(app.buttons[tool.name].exists, "The \(tool.name) button should appear immediately after Continue.") }
        XCTAssertEqual(try Data(contentsOf: store.recordURL(root)), record)
    }

    @MainActor
    func testColdLaunchWaitsForWorkspaceBeforeShowingMainWindow() async throws {
        let root = temporary.appending(path: "startup-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launchEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_AUTHOR_NAME"] = "Modu Test"
        app.launchEnvironment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        app.launchEnvironment["GIT_COMMITTER_NAME"] = "Modu Test"
        app.launchEnvironment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.terminate()

        let monitor = temporary.appending(path: "workspace-monitor.sh")
        try Data("""
        : > "$MODU_TEST_HOME_DIRECTORY/workspace-started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_TEST_HOME_DIRECTORY/workspace-release" ]; do /bin/sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        let config = root.appending(path: ".git/config")
        var configuration = try String(contentsOf: config, encoding: .utf8)
        configuration += "\n[core]\n\tfsmonitor = /bin/sh \(monitor.path)\n\tfsmonitorHookVersion = 2\n"
        try Data(configuration.utf8).write(to: config)
        let ignore = root.appending(path: ".gitignore")
        var ignoreData = try Data(contentsOf: ignore)
        // A managed-file change makes initialization reach the gated index refresh.
        ignoreData.append(Data("\n".utf8))
        try ignoreData.write(to: ignore)
        defer { try? Data().write(to: temporary.appending(path: "workspace-release")) }

        app.launch()
        let workspaceStarted = await waitForStartupProbe("started", prefix: "workspace")
        XCTAssertTrue(workspaceStarted)
        XCTAssertEqual(app.windows.count, 0)
        try Data().write(to: temporary.appending(path: "workspace-release"))
        XCTAssertTrue(app.windows["startup-workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Let’s start"].exists)
        XCTAssertTrue(app.buttons["repositories"].exists)
        XCTAssertTrue(app.buttons["worktrees"].exists)
        XCTAssertFalse(app.windows["Modu"].exists)
        attach(app, name: "First main window contains the workspace")

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertFalse(app.windows["startup-workspace"].exists)
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuBarItems["Window"].menuItems["Modu"].click()
        XCTAssertTrue(app.windows["startup-workspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Let’s start"].exists)
    }

    @MainActor
    func testQuittingDuringSlowStartupCheckCancelsTheShell() async throws {
        let root = temporary.appending(path: "startup-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.terminate()
        try deferCLIPathCheck()

        app.launch()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 5))
        let shellStarted = await waitForStartupProbe("started")
        XCTAssertTrue(shellStarted)
        XCTAssertFalse(PathSafety.exists(temporary.appending(path: "cli-release")))
        app.typeKey("q", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        let shellCancelled = await waitForStartupProbe("cancelled")
        XCTAssertTrue(shellCancelled)
    }

    @MainActor
    func testStartupDisplaysWorkspaceBeforeSlowCLIPathCheck() async throws {
        let root = temporary.appending(path: "startup-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.terminate()
        try deferCLIPathCheck()

        app.launch()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 5))
        let shellStarted = await waitForStartupProbe("started")
        XCTAssertTrue(shellStarted)
        XCTAssertFalse(PathSafety.exists(temporary.appending(path: "cli-release")))
        XCTAssertTrue(app.windows["startup-workspace"].exists)
        XCTAssertFalse(app.buttons["Install"].exists)
        attach(app, name: "Workspace visible while shell waits")
        try Data().write(to: temporary.appending(path: "cli-release"))
        let shellFinished = await waitForStartupProbe("finished")
        XCTAssertTrue(shellFinished)
        XCTAssertTrue(app.staticTexts["Let’s start"].exists)
    }

    @MainActor
    func testCLIPathFailureWaitsForManagementSheetToClose() async throws {
        let root = temporary.appending(path: "startup-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = try application()
        app.launchEnvironment["MODU_TEST_WORKSPACE"] = root.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 10))
        app.terminate()
        let other = temporary.appending(path: "other-bin")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: other.appending(path: "modu-cli"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/false"))
        try deferCLIPathCheck(conflict: true)

        app.launch()
        XCTAssertTrue(app.staticTexts["Let’s start"].waitForExistence(timeout: 5))
        let shellStarted = await waitForStartupProbe("started")
        XCTAssertTrue(shellStarted)
        let add = try XCTUnwrap(app.buttons.matching(identifier: "Add Repository").allElementsBoundByIndex.first { $0.frame.width > 24 })
        add.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        try Data().write(to: temporary.appending(path: "cli-release"))
        let shellFinished = await waitForStartupProbe("finished")
        XCTAssertTrue(shellFinished)
        XCTAssertTrue(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.windows["Set Up Workspace"].exists)
        app.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertTrue(app.windows["Set Up Workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["workspaceCandidate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertTrue(app.buttons["Cancel"].exists)
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

    private func deferCLIPathCheck(conflict: Bool = false) throws {
        try Data("""
        trap ': > "$MODU_TEST_HOME_DIRECTORY/cli-cancelled"; exit 143' TERM INT
        : > "$MODU_TEST_HOME_DIRECTORY/cli-started"
        while [[ ! -e "$MODU_TEST_HOME_DIRECTORY/cli-release" ]]; do /bin/sleep 0.02; done
        TRAPEXIT() { : > "$MODU_TEST_HOME_DIRECTORY/cli-finished"; }
        \(conflict ? "PATH=\"$MODU_TEST_HOME_DIRECTORY/other-bin:$PATH\"" : "")
        """.utf8).write(to: temporary.appending(path: ".zshrc"))
    }
    @MainActor private func waitForStartupProbe(_ name: String, prefix: String = "cli") async -> Bool {
        let file = temporary.appending(path: "\(prefix)-\(name)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !PathSafety.exists(file), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return PathSafety.exists(file)
    }

    @MainActor private func application(cliInstalled: Bool = true) throws -> XCUIApplication {
        let support = temporary.appending(path: "support")
        let executable = InstallationService(support: support).executable
        let bin = temporary.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("PATH=\"$MODU_TEST_HOME_DIRECTORY/.local/bin:$MODU_TEST_HOME_DIRECTORY/bin:/usr/bin:/bin\"\n".utf8).write(to: temporary.appending(path: ".zprofile"))
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

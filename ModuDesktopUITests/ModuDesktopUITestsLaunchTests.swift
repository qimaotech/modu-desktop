import XCTest

final class ModuDesktopUITestsLaunchTests: XCTestCase {
    @MainActor
    func testLaunchAtMinimumWindowSize() {
        let app = XCUIApplication()
        let suite = "ModuLaunchTests.\(UUID().uuidString)"
        let support = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: support) }
        app.launchEnvironment["MODU_TEST_DEFAULTS"] = suite
        app.launchEnvironment["MODU_TEST_SUPPORT_DIRECTORY"] = support.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.width, 720)
        app.terminate()
    }
}

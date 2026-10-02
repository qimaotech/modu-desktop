import AppKit
import SwiftUI
import Testing
import ModuCore
@testable import ModuDesktop

@MainActor struct SettingsWindowPlacementTests {
    @Test func centersWithinVisibleDisplayBounds() {
        let size = CGSize(width: 640, height: 480)
        for (visibleFrame, origin) in [
            (CGRect(x: 0, y: 60, width: 1440, height: 800), CGPoint(x: 400, y: 220)),
            (CGRect(x: -1920, y: 30, width: 1920, height: 1050), CGPoint(x: -1280, y: 315)),
            (CGRect(x: 1440, y: 900, width: 1080, height: 1840), CGPoint(x: 1660, y: 1580))
        ] {
            #expect(SettingsWindowPlacement.Controller.centeredOrigin(size: size, visibleFrame: visibleFrame) == origin)
        }
    }

    @Test func centersOnFirstOpenAndAfterCloseButPreservesPositionWhileOpen() async throws {
        let window = makeWindow()
        defer { window.close() }
        let screen = try #require(window.screen ?? NSScreen.main)
        let centered = SettingsWindowPlacement.Controller.centeredOrigin(size: window.frame.size, visibleFrame: screen.visibleFrame)
        window.orderFront(nil)
        await settleWindow()
        expectCentered(window, at: centered)

        let moved = CGPoint(x: window.frame.origin.x + 80, y: window.frame.origin.y - 60)
        window.setFrameOrigin(moved)
        window.makeKeyAndOrderFront(nil)
        await settleWindow()
        #expect(window.frame.origin == moved)
        window.orderOut(nil)
        window.orderFront(nil)
        await settleWindow()
        #expect(window.frame.origin == moved)

        window.close()
        window.orderFront(nil)
        await settleWindow()
        expectCentered(window, at: centered)
    }

    @Test func waitsForFinalWindowSizeAndOnlyCentersOnce() async throws {
        let window = makeWindow(height: 500)
        defer { window.close() }
        let initial = window.frame.origin
        window.orderFront(nil)
        await settleWindow()
        #expect(window.frame.origin == initial)

        window.setFrame(CGRect(origin: initial, size: CGSize(width: 640, height: 480)), display: false)
        await settleWindow()
        let screen = try #require(window.screen ?? NSScreen.main)
        let centered = SettingsWindowPlacement.Controller.centeredOrigin(size: window.frame.size, visibleFrame: screen.visibleFrame)
        expectCentered(window, at: centered)

        let moved = CGPoint(x: window.frame.origin.x + 80, y: window.frame.origin.y - 60)
        window.setFrameOrigin(moved)
        window.setFrame(CGRect(origin: moved, size: CGSize(width: 640, height: 500)), display: false)
        window.setFrame(CGRect(origin: moved, size: CGSize(width: 640, height: 480)), display: false)
        await settleWindow()
        #expect(window.frame.origin == moved)
    }

    @Test func hostedSettingsPreservesPositionAcrossLanguageAndWorkspaceChanges() async throws {
        let suite = "ModuSettingsPlacement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let host = NSHostingController(rootView: SettingsContent(model: model))
        let window = NSWindow(contentViewController: host)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setFrameOrigin(CGPoint(x: 20, y: 40))
        window.orderFront(nil)
        await settleWindow()
        #expect(window.frame.size == CGSize(width: 640, height: 480))
        let screen = try #require(window.screen ?? NSScreen.main)
        let centered = SettingsWindowPlacement.Controller.centeredOrigin(size: window.frame.size, visibleFrame: screen.visibleFrame)
        expectCentered(window, at: centered)

        let moved = CGPoint(x: window.frame.origin.x + 80, y: window.frame.origin.y - 60)
        window.setFrameOrigin(moved)
        for language in ["zh", "en"] {
            model.language = language
            model.workspace = WorkspaceRecord(root: "/\(language)-workspace")
            await settleWindow()
            #expect(window.frame.origin == moved)
        }

        window.close()
        window.orderFront(nil)
        await settleWindow()
        expectCentered(window, at: centered)
    }

    private func makeWindow(height: CGFloat = 480) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentViewController = SettingsWindowPlacement.Controller(size: CGSize(width: 640, height: 480), sourceWindow: { nil })
        window.setFrame(CGRect(x: 20, y: 40, width: 640, height: height), display: false)
        return window
    }

    private func settleWindow() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func expectCentered(_ window: NSWindow, at origin: CGPoint) {
        // AppKit may round the half-point center when placing a transparent window.
        #expect(abs(window.frame.origin.x - origin.x) <= 0.5)
        #expect(abs(window.frame.origin.y - origin.y) <= 0.5)
    }

    private struct SettingsContent: View {
        var model: AppModel
        @State private var chromeHeight: CGFloat = 32

        var body: some View {
            SettingsView(model: model).frame(width: 640, height: 480 - chromeHeight)
                .background(WindowChromeHeight(height: $chromeHeight))
                .background(SettingsWindowPlacement(size: CGSize(width: 640, height: 480), sourceWindow: { nil }))
                .environment(\.locale, Locale(identifier: model.language))
        }
    }
}

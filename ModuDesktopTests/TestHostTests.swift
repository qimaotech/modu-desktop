import AppKit
import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct TestHostTests {
    @Test func onlyUnitTestHostsSuppressAutomaticStartup() {
        #expect(!TestHost.isEnabled(environment: [:]))
        #expect(!TestHost.isEnabled(environment: ["MODU_TEST_DEFAULTS": "isolated-preferences"]))
        #expect(TestHost.isEnabled(environment: ["MODU_UNIT_TEST_HOST": "1"]))
        #expect(TestHost.isEnabled(environment: ["XCTestBundlePath": "/tmp/ModuDesktopTests.xctest"]))
        #expect(!TestHost.isEnabled(environment: ["XCTestBundlePath": "/tmp/OtherTests.xctest"]))
    }

    @Test func unitTestHostHasNoVisibleAppWindowsAndRegistersItsIdentity() async throws {
        #expect(TestHost.isEnabled())
        try await Task.sleep(for: .milliseconds(200))
        #expect(NSApplication.shared.windows.allSatisfy { !$0.isVisible || $0.alphaValue == 0 })
        if let path = ProcessInfo.processInfo.environment["MODU_TEST_SESSION_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path)
            let identity = try Data(contentsOf: directory.appending(path: "hosts/\(ProcessInfo.processInfo.processIdentifier).json"))
            let value = try #require(JSONSerialization.jsonObject(with: identity) as? [String: Any])
            #expect(value["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier)
            #expect(value["executable"] as? String == Bundle.main.executableURL.map(PathSafety.canonical)?.path)
            #expect(WorkspaceStore.defaultSupport.path == directory.appending(path: "support").path)
            #expect(TestEnvironment.temporaryDirectory.path == directory.appending(path: "tmp").path)
            let marker = TestEnvironment.temporaryDirectory.appending(path: "host-test-marker")
            try Data().write(to: marker)
        }
    }
}

import Foundation
import AppKit
import MonoDeckCore

enum TestHost {
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        return environment["MONO_DECK_UNIT_TEST_HOST"] == "1"
            || environment["XCTestBundlePath"].map { URL(fileURLWithPath: $0).lastPathComponent == "MonoDeckTests.xctest" } == true
        #else
        return false
        #endif
    }

    static func registerIfNeeded() throws {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["MONO_DECK_TEST_SESSION_DIRECTORY"] else { return }
        let directory = try PathSafety.child("hosts", of: URL(fileURLWithPath: path), allowMissing: false)
        let application = NSRunningApplication.current
        guard let launchedAt = application.launchDate, let executable = application.executableURL else {
            throw MonoDeckError("test-host-unavailable", .couldNotIdentifyTestHostForCleanup)
        }
        let identity: [String: Any] = ["pid": application.processIdentifier, "launched-at": launchedAt.timeIntervalSince1970,
                                       "executable": PathSafety.canonical(executable).path]
        try JSONSerialization.data(withJSONObject: identity).write(to: directory.appending(path: "\(application.processIdentifier).json"), options: .atomic)
        #endif
    }
}

import Foundation
import AppKit
import ModuCore

extension AppModel {
    static func launch() -> AppModel {
        do {
            try TestHost.registerIfNeeded()
            return try makeForLaunch(arguments: ProcessInfo.processInfo.arguments)
        }
        catch {
            FileHandle.standardError.write(Data("Modu: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    static func makeForLaunch(arguments: [String]) throws -> AppModel {
        guard let index = arguments.firstIndex(of: "--mock") else {
            guard !arguments.contains("--mock-workspace") else { throw ModuError("invalid-input", "--mock-workspace requires --mock.") }
            return AppModel()
        }
        #if DEBUG
        guard arguments.filter({ $0 == "--mock" }).count == 1, index + 1 < arguments.count,
              let scenario = MockWorkspace.Scenario(rawValue: arguments[index + 1]),
              arguments.filter({ $0 == "--mock-workspace" }).count == 1,
              let workspaceIndex = arguments.firstIndex(of: "--mock-workspace"), workspaceIndex + 1 < arguments.count,
              arguments[workspaceIndex + 1].hasPrefix("/") else {
            throw ModuError("invalid-input", "Use the build script to prepare --mock linked-worktree-selected --mock-workspace <root>.")
        }
        return try MockWorkspace(scenario: scenario, workspace: URL(fileURLWithPath: arguments[workspaceIndex + 1])).makeModel()
        #else
        throw ModuError("debug-only", "Mock scenarios are only available in Debug builds.")
        #endif
    }
}

enum TestHost {
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        return environment["MODU_UNIT_TEST_HOST"] == "1"
            || environment["XCTestBundlePath"].map { URL(fileURLWithPath: $0).lastPathComponent == "ModuDesktopTests.xctest" } == true
        #else
        return false
        #endif
    }

    static func registerIfNeeded() throws {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["MODU_TEST_SESSION_DIRECTORY"] else { return }
        let directory = try PathSafety.child("hosts", of: URL(fileURLWithPath: path), allowMissing: false)
        let application = NSRunningApplication.current
        guard let launchedAt = application.launchDate, let executable = application.executableURL else {
            throw ModuError("test-host-unavailable", "Could not identify the test host for cleanup.")
        }
        let identity: [String: Any] = ["pid": application.processIdentifier, "launched-at": launchedAt.timeIntervalSince1970,
                                       "executable": PathSafety.canonical(executable).path]
        try JSONSerialization.data(withJSONObject: identity).write(to: directory.appending(path: "\(application.processIdentifier).json"), options: .atomic)
        #endif
    }
}

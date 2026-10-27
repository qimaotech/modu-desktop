import AppKit
import Foundation
import Testing
@testable import ModuCore

struct BuildAndRunScriptTests {
    @Test func verificationPreservesExistingInstances() async throws {
        let result = try await traceLogs(["--verify"])
        #expect(result.status == 0)
        #expect(result.text.hasPrefix("build\n"))
        #expect(result.text.contains("launch:"))
        #expect(!result.text.contains("stop") && !result.text.contains("log:"))
    }

    @Test(arguments: [("--logs", false), ("--telemetry", true)])
    func loggingUsesOnlyTheLaunchedInstance(_ mode: String, _ mock: Bool) async throws {
        let arguments = [mode] + (mock ? ["--mock", "linked-worktree-selected"] : [])
        let result = try await traceLogs(arguments)
        #expect(result.status == 0)
        #expect(result.text.hasPrefix("stop\n") == !mock)
        #expect(result.text.contains("launch:--activate"))
        let invocation = try #require(result.text.split(separator: "\n").first { $0.hasPrefix("log:") })
        #expect(invocation == (mode == "--telemetry"
                              ? "log:--process 12345 --predicate subsystem == \"fun.armantang.ModuDesktop\""
                              : "log:--process 12345"))
    }

    @Test(arguments: ["", "App instance PID: 0", "App instance PID: Modu", "App instance PID: 12345\nApp instance PID: 67890"])
    func loggingRejectsMissingOrAmbiguousInstanceIDs(_ output: String) async throws {
        let result = try await traceLogs(["--logs"], output: output)
        #expect(result.status == 1)
        #expect(!result.text.contains("log:"))
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("Could not identify the launched App instance"))
    }

    @Test func failedLaunchDoesNotStartLoggingEvenWhenItReportsAPID() async throws {
        let result = try await traceLogs(["--telemetry"], status: 23)
        #expect(result.status == 23)
        #expect(result.text.contains("App instance PID: 12345"))
        #expect(!result.text.contains("log:"))
    }

    @MainActor @Test func missingApplicationDoesNotReuseAnExistingInstance() async throws {
        let current = NSRunningApplication.current
        let temporary = TestEnvironment.temporaryDirectory
        let result = try await runHelper("verify_app", [temporary.appending(path: "missing-\(UUID().uuidString).app").path])
        #expect(result.status == 1)
        #expect(result.text.isEmpty)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("App launch failed:"))
        #expect(!current.isTerminated)
    }

    @Test func explicitQuitRejectsAnInvalidPID() async throws {
        let result = try await runHelper("quit_app", ["0"])
        #expect(result.status == 2)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("usage:"))
    }

    @MainActor @Test func explicitQuitRejectsAChangedTestHostIdentity() async throws {
        let application = NSRunningApplication.current
        let executable = try #require(application.executableURL)
        let launchedAt = try #require(application.launchDate)
        let file = TestEnvironment.temporaryDirectory.appending(path: "modu-test-identity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let identity: [String: Any] = ["pid": application.processIdentifier, "executable": executable.standardizedFileURL.resolvingSymlinksInPath().path,
                                       "launched-at": launchedAt.timeIntervalSince1970 + 60]
        try JSONSerialization.data(withJSONObject: identity).write(to: file)
        let result = try await runHelper("quit_app", ["--identity", file.path])
        #expect(result.status == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("test host identity changed"))
        #expect(!application.isTerminated)
    }

    @MainActor @Test func verificationKeepsItsInstanceUntilTheCallerExplicitlyQuits() async throws {
        let fixture = try await MockWorkspacePreparation.prepare()
        let existing = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "fun.armantang.ModuDesktop" }
        var running: NSRunningApplication?
        defer {
            let log = (try? String(contentsOf: fixture.directory.appending(path: "launch.log"), encoding: .utf8)) ?? ""
            let application = running ?? self.application(in: log)
            if let application, !application.isTerminated {
                _ = application.terminate()
                let start = ContinuousClock.now
                while !application.isTerminated && start.duration(to: .now) < .seconds(15) {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                }
            }
            if application?.isTerminated != false { fixture.remove() }
        }
        let result = try await runHelper("verify_app", [Bundle.main.bundleURL.path, "--mock", "linked-worktree-selected", "--mock-workspace", fixture.root.path])
        let application = try #require(self.application(in: result.text))
        running = application
        let pid = application.processIdentifier
        #expect(result.status == 0, "\(result.text)\n\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(!existing.contains { $0.processIdentifier == pid })
        #expect(!application.isTerminated)
        #expect(!result.text.contains("App exited"))
        #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
        let quit = try await runHelper("quit_app", [String(pid)])
        #expect(quit.status == 0)
        #expect(quit.text == "App exited (PID \(pid)).")
        #expect(application.isTerminated)
        #expect(!PathSafety.exists(fixture.directory))
        #expect(existing.allSatisfy { !$0.isTerminated })
    }

    @MainActor private func application(in output: String) -> NSRunningApplication? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("App instance PID: ") }),
              let pid = Int32(line.dropFirst("App instance PID: ".count)) else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func traceLogs(_ arguments: [String], output: String = "App instance PID: 12345", status: Int32 = 0) async throws -> CommandOutput {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu log tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        source "$1"
        TMPDIR="$2"
        launch_output="$3"
        launch_status="$4"
        stop_app() { echo stop; }
        build_app() { echo build; }
        launch_verified_app() { echo "launch:$1"; printf '%s\\n' "$launch_output"; return "$launch_status"; }
        stream_log() { printf 'log:%s\\n' "$*"; }
        main "${@:5}"
        """
        let result = try await CommandRunner().run("/bin/bash", ["-c", script, "modu-log-tests",
                                                              Self.root.appending(path: "script/build_and_run.sh").path,
                                                              directory.path, output, String(status)] + arguments)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        return result
    }

    private func runHelper(_ name: String, _ arguments: [String]) async throws -> CommandOutput {
        let cache = FileManager.default.temporaryDirectory.appending(path: "modu-verification-module-cache")
        return try await CommandRunner().run("/usr/bin/swift", ["-module-cache-path", cache.path,
                                                              Self.root.appending(path: "script/\(name).swift").path] + arguments, timeout: 60)
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}

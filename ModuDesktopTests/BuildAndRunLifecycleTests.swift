import Darwin
import Foundation
import Testing
@testable import ModuCore

@MainActor
struct BuildAndRunLifecycleTests {
    @Test(arguments: [(SIGINT, "--verify", true), (SIGTERM, "--verify", false),
                      (SIGTERM, "run", true), (SIGINT, "--logs", false)])
    func interruptedVerificationKeepsItsLiveInstanceAndData(_ signal: Int32, _ mode: String, _ printsPID: Bool) async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let own = try session.startApp(workspace: session.workspace)
        let unrelated = try session.startApp(workspace: session.otherWorkspace)
        let result = try await runScript(session, mode: mode, signal: signal, overrides: """
        launch_verified_app() {
          if \(printsPID); then echo "App instance PID: $test_pid"; fi
          if \(printsPID); then kill -"$test_signal" "$$"; else kill -"$test_signal" -- "-$$"; fi
          /bin/sleep 0.05
        }
        """, pid: own.processIdentifier)
        #expect(result.status == 128 + signal)
        #expect(own.isRunning)
        #expect(result.text.contains("App instance PID: \(own.processIdentifier)"))
        #expect(try String(contentsOf: session.workspace.appending(path: "sample.txt"), encoding: .utf8) == "own")
        try session.expectUnrelatedIsIntact(unrelated)
    }

    @Test(arguments: ["--verify", "--logs"])
    func interruptedVerificationWithoutAnInstanceCleansOnlyItsData(_ mode: String) async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let unrelated = try session.startApp(workspace: session.otherWorkspace)
        let result = try await runScript(session, mode: mode, overrides: """
        launch_verified_app() { kill -"$test_signal" -- "-$$"; /bin/sleep 0.05; }
        """)
        #expect(result.status == 128 + SIGTERM)
        #expect(!PathSafety.exists(session.directory))
        try session.expectUnrelatedIsIntact(unrelated)
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func debuggerExitWithoutRunCleansOnlyItsData(_ status: Int32) async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let unrelated = try session.startApp(workspace: session.otherWorkspace)
        let result = try await runScript(session, mode: "--debug", status: status, overrides: "lldb() { return \"$test_status\"; }")
        #expect(result.status == status)
        #expect(!PathSafety.exists(session.directory))
        try session.expectUnrelatedIsIntact(unrelated)
    }

    @Test(arguments: ["--debug", "--verify", "run", "--logs"])
    func completedLaunchKeepsItsLiveInstanceForExplicitQuit(_ mode: String) async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let own = try session.startApp(workspace: session.workspace)
        let unrelated = try session.startApp(workspace: session.otherWorkspace)
        let result = try await runScript(session, mode: mode, overrides: """
        lldb() { return 0; }
        launch_verified_app() { echo "App instance PID: $test_pid"; }
        """, pid: own.processIdentifier)
        #expect(result.status == 0)
        #expect(result.text.contains("App instance PID: \(own.processIdentifier)"))
        #expect(!result.text.contains("App instance PID: \(unrelated.processIdentifier)"))
        #expect(own.isRunning)
        #expect(PathSafety.exists(session.workspace))
        try session.expectUnrelatedIsIntact(unrelated)
    }

    @Test(arguments: [SIGINT, SIGTERM])
    func stoppingLogCollectionKeepsItsAppAndRemovesTemporaryCapture(_ signal: Int32) async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let own = try session.startApp(workspace: session.workspace)
        let unrelated = try session.startApp(workspace: session.otherWorkspace)
        let result = try await runScript(session, mode: "--logs", signal: signal, overrides: """
        launch_verified_app() { echo "App instance PID: $test_pid"; }
        stream_log() { kill -"$test_signal" -- "-$$"; /bin/sleep 0.05; }
        """, pid: own.processIdentifier)
        #expect(result.status == 128 + signal)
        #expect(own.isRunning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.base.path).allSatisfy { !$0.hasPrefix("modu-app-launch.") })
        try session.expectUnrelatedIsIntact(unrelated)
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func completedVerificationDoesNotKeepDataForAnExitedInstance(_ status: Int32) async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let exited = try session.startApp(workspace: session.workspace)
        exited.terminate()
        exited.waitUntilExit()
        let unrelated = try session.startApp(workspace: session.otherWorkspace)
        let result = try await runScript(session, mode: "--verify", status: status, overrides: """
        launch_verified_app() { echo "App instance PID: $test_pid"; return "$test_status"; }
        """, pid: exited.processIdentifier)
        #expect(result.status == status)
        #expect(!PathSafety.exists(session.directory))
        try session.expectUnrelatedIsIntact(unrelated)
    }

    @Test func unknownProcessStatePreservesDataAndTheOriginalFailure() async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        let result = try await runScript(session, mode: "--debug", status: 1, overrides: """
        lldb() { return "$test_status"; }
        find_mock_app() { return 2; }
        """)
        #expect(result.status == 1)
        #expect(PathSafety.exists(session.workspace))
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("Could not confirm mock App state"))
    }

    @Test func processLookupMatchesExecutableAndWholeWorkspaceArgument() async throws {
        let session = try await Session.allocate()
        defer { session.cleanup() }
        _ = try session.startApp(workspace: session.workspace.appendingPathExtension("other"))
        let lookup = Self.root.appending(path: "script/find_mock_app.py").path
        let absent = try await CommandRunner().run("/usr/bin/python3", [lookup, "--executable", "/bin/bash", "--workspace", session.workspace.path])
        #expect(absent.status == 1)
        let own = try session.startApp(workspace: session.workspace)
        let found = try await CommandRunner().run("/usr/bin/python3", [lookup, "--executable", "/bin/bash", "--workspace", session.workspace.path])
        #expect(found.status == 0)
        #expect(found.text == "App instance PID: \(own.processIdentifier)")
        let otherExecutable = try await CommandRunner().run("/usr/bin/python3", [lookup, "--executable", "/bin/sleep", "--workspace", session.workspace.path])
        #expect(otherExecutable.status == 1)
    }

    private func runScript(_ session: Session, mode: String, signal: Int32 = SIGTERM, status: Int32 = 0,
                           overrides: String, pid: Int32 = 0) async throws -> CommandOutput {
        let script = """
        source "$1"
        MOCK_DIRECTORY="$2"
        TMPDIR="${MOCK_DIRECTORY%/*}"
        APP_BINARY=/bin/bash
        test_pid="$3"
        test_signal="$4"
        test_status="$5"
        build_app() { :; }
        stream_log() { return "$test_status"; }
        \(overrides)
        main "${@:6}"
        """
        return try await CommandRunner().run("/bin/bash", ["-c", script, "modu-lifecycle-tests",
                                                          Self.root.appending(path: "script/build_and_run.sh").path,
                                                          session.directory.path, String(pid), String(signal), String(status),
                                                          mode, "--mock", "linked-worktree-selected"])
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @MainActor
    private final class Session {
        let base: URL
        let directory: URL
        let otherDirectory: URL
        var workspace: URL { directory.appending(path: "example-workspace") }
        var otherWorkspace: URL { otherDirectory.appending(path: "example-workspace") }
        var processes: [Process] = []

        init(base: URL, directory: URL, otherDirectory: URL) {
            self.base = base
            self.directory = directory
            self.otherDirectory = otherDirectory
        }

        static func allocate() async throws -> Session {
            let base = TestEnvironment.temporaryDirectory.appending(path: "modu lifecycle tests \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            do {
                var runner = CommandRunner()
                runner.environment["TMPDIR"] = base.path
                let script = BuildAndRunLifecycleTests.root.appending(path: "script/prepare_mock_workspace.py").path
                let own = try await runner.run("/usr/bin/python3", [script, "allocate"])
                let other = try await runner.run("/usr/bin/python3", [script, "allocate"])
                try #require(own.status == 0 && other.status == 0)
                let session = Session(base: base, directory: URL(fileURLWithPath: own.text), otherDirectory: URL(fileURLWithPath: other.text))
                for (workspace, contents) in [(session.workspace, "own"), (session.otherWorkspace, "unrelated")] {
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                    try contents.write(to: workspace.appending(path: "sample.txt"), atomically: true, encoding: .utf8)
                }
                return session
            } catch {
                try? FileManager.default.removeItem(at: base)
                throw error
            }
        }

        func startApp(workspace: URL) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "trap 'exit 0' TERM; while :; do /bin/sleep 0.05; done", "modu-lifecycle-app",
                                 "--mock", "linked-worktree-selected", "--mock-workspace", workspace.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
            return process
        }

        func expectUnrelatedIsIntact(_ process: Process) throws {
            #expect(process.isRunning)
            #expect(try String(contentsOf: otherWorkspace.appending(path: "sample.txt"), encoding: .utf8) == "unrelated")
        }

        func cleanup() {
            for process in processes {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: base)
        }
    }
}

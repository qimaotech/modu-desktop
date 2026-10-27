import Darwin
import Foundation
import Testing
@testable import ModuCore

struct TestTaskTests {
    @Test(arguments: ["passed", "zero", "skipped", "failed", "invalid-report", "report-failed"])
    func testTaskChecksActualExecutionAndAlwaysCleansItsEnvironment(_ outcome: String) async throws {
        let fixture = try TestTaskFixture(outcome: outcome)
        defer { fixture.remove() }
        let output = try await fixture.run()
        #expect(output.status == (outcome == "passed" ? 0 : outcome == "failed" ? 65 : 1))
        let invocation = try fixture.invocation()
        #expect(invocation.arguments.contains("-only-testing:ModuDesktopTests"))
        #expect(invocation.environment["MODU_UNIT_TEST_HOST"] == "1")
        #expect(invocation.environment["TEST_RUNNER_MODU_UNIT_TEST_HOST"] == "1")
        #expect(invocation.environment["MODU_TEST_WORKSPACE"] == nil)
        for key in ["MODU_TEST_SUPPORT_DIRECTORY", "MODU_TEST_HOME_DIRECTORY", "MODU_TEST_SESSION_DIRECTORY", "MODU_TEST_DEFAULTS", "MODU_TEST_LOGIN_SHELL", "TMPDIR"] {
            #expect(invocation.environment[key] == invocation.environment["TEST_RUNNER_\(key)"])
        }
        #expect(invocation.environment["MODU_TEST_DEFAULTS"] != "inherited-preferences")
        #expect(!PathSafety.exists(invocation.directory))
        #expect(try await fixture.defaultsExist(invocation.environment["MODU_TEST_DEFAULTS"]!) == false)
        #expect(try Data(contentsOf: fixture.sentinel) == Data("keep me".utf8))
        if outcome == "zero" || outcome == "skipped" {
            #expect(String(decoding: output.stderr, as: UTF8.self).contains("No tests executed"))
        }
    }

    @Test func filteredTestsKeepExplicitResultsAfterFailure() async throws {
        let fixture = try TestTaskFixture(outcome: "failed")
        defer { fixture.remove() }
        let results = fixture.directory.appending(path: "saved results.xcresult")
        let output = try await fixture.run(filter: "ModuDesktopTests/WorkflowTests", arguments: ["-resultBundlePath", results.path, "-quiet"])
        #expect(output.status == 65)
        let invocation = try fixture.invocation()
        #expect(invocation.arguments.contains("-only-testing:ModuDesktopTests/WorkflowTests"))
        #expect(invocation.arguments.filter { $0 == "-resultBundlePath" }.count == 1)
        #expect(invocation.arguments.last == "-quiet")
        #expect(PathSafety.exists(results) && !PathSafety.exists(invocation.directory))
    }

    @Test func enumerationDoesNotRequireExecutedTests() async throws {
        let fixture = try TestTaskFixture(outcome: "zero")
        defer { fixture.remove() }
        let output = try await fixture.run(arguments: ["-enumerate-tests"])
        #expect(output.status == 0)
        #expect(!PathSafety.exists(try fixture.invocation().directory))
    }

    @Test func unconfirmedHostCleanupFailsAndPreservesItsEnvironment() async throws {
        let fixture = try TestTaskFixture(outcome: "cleanup-failed")
        defer { fixture.remove() }
        let output = try await fixture.run()
        #expect(output.status == 1)
        #expect(PathSafety.exists(try fixture.invocation().directory))
        #expect(String(decoding: output.stderr, as: UTF8.self).contains("keeping environment"))
    }

    @Test func cancellationStopsOwnedHelpersAndCleansTheEnvironment() async throws {
        let fixture = try TestTaskFixture(outcome: "waiting")
        defer { fixture.remove() }
        let operation = Task { try await fixture.runCapturingLog() }
        defer { operation.cancel() }
        let pidFile = fixture.directory.appending(path: "helper.pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !PathSafety.exists(pidFile), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(try? Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let invocation = try fixture.invocation()
        operation.cancel()
        do { _ = try await operation.value; Issue.record("Expected cancellation") }
        catch { #expect((error as? ModuError)?.code == "cancelled") }
        #expect(kill(pid, 0) == -1)
        let log = try String(contentsOf: fixture.directory.appending(path: "cancellation.log"), encoding: .utf8)
        #expect(!PathSafety.exists(invocation.directory), "\(log)")
        #expect(try await fixture.defaultsExist(invocation.environment["MODU_TEST_DEFAULTS"]!) == false, "\(log)")
        #expect(PathSafety.exists(fixture.sentinel))
    }
}

private struct TestTaskInvocation: Decodable {
    let arguments: [String]
    let environment: [String: String]
    var directory: URL { URL(fileURLWithPath: environment["MODU_TEST_SESSION_DIRECTORY"]!) }
}

private struct TestTaskFixture {
    let directory: URL
    let sentinel: URL
    let runner: CommandRunner
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    init(outcome: String) throws {
        directory = TestEnvironment.temporaryDirectory.appending(path: "modu test task \(UUID().uuidString)")
        sentinel = directory.appending(path: "unrelated.txt")
        let bin = directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: sentinel)
        let build = """
        #!/usr/bin/python3
        import json, os, subprocess, sys, time
        from pathlib import Path
        base = Path(os.environ['MODU_SCRIPT_TEST_DIRECTORY'])
        environment = {key: value for key, value in os.environ.items() if key.startswith(('MODU_TEST_', 'TEST_RUNNER_MODU_TEST_')) or key in ('MODU_UNIT_TEST_HOST', 'TEST_RUNNER_MODU_UNIT_TEST_HOST', 'TMPDIR', 'TEST_RUNNER_TMPDIR')}
        (base / 'invocation.json').write_text(json.dumps({'arguments': sys.argv[1:], 'environment': environment}))
        subprocess.run(['/usr/bin/defaults', 'write', os.environ['MODU_TEST_DEFAULTS'], 'marker', 'test'], check=True)
        destination = Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
        destination.mkdir()
        if os.environ['MODU_SCRIPT_TEST_OUTCOME'] == 'cleanup-failed':
            (Path(os.environ['MODU_TEST_SESSION_DIRECTORY']) / 'hosts' / 'identity.json').write_text('{}')
        if os.environ['MODU_SCRIPT_TEST_OUTCOME'] == 'waiting':
            helper = subprocess.Popen(['/bin/sleep', '30'])
            (base / 'helper.pid').write_text(str(helper.pid))
            time.sleep(30)
        sys.exit(65 if os.environ['MODU_SCRIPT_TEST_OUTCOME'] == 'failed' else 0)
        """
        let report = """
        #!/usr/bin/python3
        import json, os, sys
        outcome = os.environ['MODU_SCRIPT_TEST_OUTCOME']
        if sys.argv[1] == 'swift': sys.exit(1)
        if outcome == 'report-failed': sys.exit(1)
        if outcome == 'invalid-report': print('invalid'); sys.exit(0)
        print(json.dumps({'totalTestCount': 0 if outcome == 'zero' else 2, 'skippedTests': 2 if outcome == 'skipped' else 0}))
        """
        for (name, text) in [("xcodebuild", build), ("xcrun", report)] {
            let file = bin.appending(path: name)
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        environment["TMPDIR"] = directory.path
        environment["MODU_TEST_DEFAULTS"] = "inherited-preferences"
        environment["MODU_TEST_WORKSPACE"] = "/unrelated-workspace"
        environment["MODU_UNIT_TEST_HOST"] = "1"
        environment["TEST_RUNNER_MODU_UNIT_TEST_HOST"] = "1"
        environment["MODU_SCRIPT_TEST_DIRECTORY"] = directory.path
        environment["MODU_SCRIPT_TEST_OUTCOME"] = outcome
        runner = CommandRunner(environment: environment)
    }

    func run(filter: String = "ModuDesktopTests", arguments: [String] = []) async throws -> CommandOutput {
        try await runner.run("/usr/bin/python3", [Self.root.appending(path: "script/run_tests.py").path, "--filter", filter, "--"] + arguments)
    }

    func invocation() throws -> TestTaskInvocation {
        try JSONDecoder().decode(TestTaskInvocation.self, from: Data(contentsOf: directory.appending(path: "invocation.json")))
    }

    func runCapturingLog() async throws -> CommandOutput {
        try await runner.run("/bin/bash", ["-c", "exec /usr/bin/python3 \"$1\" > \"$2\" 2>&1", "modu-test-task-cancellation",
                                            Self.root.appending(path: "script/run_tests.py").path,
                                            directory.appending(path: "cancellation.log").path])
    }

    func defaultsExist(_ suite: String) async throws -> Bool {
        try await runner.run("/usr/bin/defaults", ["read", suite]).status == 0
    }

    func remove() {
        if let invocation = try? invocation(), let suite = invocation.environment["MODU_TEST_DEFAULTS"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["delete", suite]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

#if DEBUG
import Darwin
import Foundation
import Testing
@testable import ModuCore

struct MockWorkspacePreparationTests {
    @Test func buildFailureCleansThePreparedSession() async throws {
        let directory = temporaryDirectory()
        do {
            let fixture = try await MockWorkspacePreparation.prepare(directory: directory, buildCommand: ["/usr/bin/false"])
            fixture.remove()
            Issue.record("Failed build should block preparation.")
        } catch { #expect((error as? ModuError)?.code == "mock-unavailable") }
        #expect(!PathSafety.exists(directory))
    }

    @Test func cancellationStopsTheBuildAndCleansTemporaryData() async throws {
        let directory = temporaryDirectory()
        let pidFile = directory.appending(path: "build.pid")
        let build = "import os, sys, time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        let task = Task { try await MockWorkspacePreparation.prepare(directory: directory, buildCommand: ["/usr/bin/python3", "-c", build, pidFile.path]) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(pidFile), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(try? Int32(String(contentsOf: pidFile, encoding: .utf8)))
        task.cancel()
        do {
            let fixture = try await task.value
            fixture.remove()
            Issue.record("Cancelled preparation should fail.")
        } catch { #expect(error is CancellationError || (error as? ModuError)?.code == "cancelled") }
        #expect(!PathSafety.exists(directory))
        #expect(kill(pid, 0) == -1)
    }

    @Test func appRejectsUnfinishedDataWithoutGeneratingOrDeletingIt() async throws {
        let fixture = try await MockWorkspacePreparation.prepare()
        defer { fixture.remove() }
        let marker = fixture.directory.appending(path: "mock-session.json")
        var session = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        session["ready"] = false
        try JSONSerialization.data(withJSONObject: session).write(to: marker)
        #expect(throws: (any Error).self) { try MockWorkspaceFixture(workspace: fixture.root) }
        #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
    }

    private func temporaryDirectory() -> URL {
        TestEnvironment.temporaryDirectory.appending(path: "modu-mock-\(UUID().uuidString.lowercased())")
    }
}
#endif

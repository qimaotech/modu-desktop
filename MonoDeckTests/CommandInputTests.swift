import Foundation
import Darwin
import Testing
@testable import MonoDeckCore

struct CommandInputTests {
    @Test func inputAndBothOutputPipesProgressTogether() async throws {
        let input = Data((0..<(1_024 * 1_024)).map { UInt8($0 % 251) })
        let output = try await CommandRunner().run("/bin/sh", ["-c", "dd if=/dev/zero bs=4096 count=64 2>/dev/null; dd if=/dev/zero bs=4096 count=64 >&2 2>/dev/null; cat"], input: input)
        #expect(output.status == 0)
        #expect(output.stdout == Data(repeating: 0, count: 256 * 1_024) + input)
        #expect(output.stderr == Data(repeating: 0, count: 256 * 1_024))
    }

    @Test func earlyClosedInputDoesNotSignalTheApplication() async throws {
        let output = try await CommandRunner().run("/bin/sh", ["-c", "exec 0<&-; printf done"], input: Data(repeating: 1, count: 1_024 * 1_024))
        #expect(output.status == 0 && output.text == "done")
        let empty = try await CommandRunner().run("/bin/cat", [], input: Data())
        #expect(empty.status == 0 && empty.stdout.isEmpty)
    }

    @Test(arguments: ["cancelled", "network-timeout"])
    func blockedInputStillHonorsCancellationAndTimeout(_ reason: String) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "mono-deck-command-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "pid")
        let task = Task {
            try await CommandRunner().run("/bin/sh", ["-c", "echo $$ > \"$1\"; trap 'exit 143' TERM INT; while :; do sleep 0.02; done", "mono-deck-input-test", pidFile.path], timeout: reason == "network-timeout" ? 1 : 30, input: Data(repeating: 1, count: 1_024 * 1_024))
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(pidFile), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(pid_t(text))
            if reason == "cancelled" { task.cancel() }
            do { _ = try await task.value; Issue.record("Expected the command to stop.") }
            catch { #expect((error as? MonoDeckError)?.code == reason) }
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        } catch {
            task.cancel(); _ = try? await task.value
            throw error
        }
    }

    @Test func ignoreChecksPreserveTrackedFilesNegationsAndNulSeparatedNames() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        try Data(".ignored/\nignored-*\n!ignored-keep\n".utf8).write(to: fixture.root.appending(path: ".gitignore"))
        try Data("tracked".utf8).write(to: fixture.root.appending(path: "ignored-tracked.txt"))
        _ = try await fixture.service.git.run(["add", "-f", "ignored-tracked.txt"], at: fixture.root)
        let paths = [".ignored/有\n换行", "ignored-new.txt", "ignored-keep", "ignored-tracked.txt", "visible.txt"]
        let ignored = try await fixture.service.git.ignoredPaths(paths, at: fixture.root)
        #expect(ignored == Set(paths.prefix(2)))
        #expect(try await fixture.service.git.ignoredPaths(["visible.txt"], at: fixture.root).isEmpty)
    }
}

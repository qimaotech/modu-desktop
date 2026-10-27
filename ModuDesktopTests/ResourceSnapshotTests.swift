import Foundation
import Testing
@testable import ModuCore

struct ResourceSnapshotTests {
    @Test(arguments: ["fetch-failed", "base-still-missing"])
    func missingBaseRecoveryFetchesOnceAndPreservesChanges(_ outcome: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        let path = record.repositoryURL("repo")
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
        if outcome == "fetch-failed" {
            _ = try await fixture.service.git.run(["config", "remote.origin.uploadpack", "/usr/bin/false"], at: path)
        } else {
            _ = try await fixture.service.git.run(["config", "remote.origin.followRemoteHEAD", "never"], at: path)
        }
        try Data("keep changes".utf8).write(to: path.appending(path: "new.txt"))
        let trace = fixture.directory.appending(path: "recovery-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))

        let snapshot = try await service.snapshot(.repository("repo"), in: record)

        #expect(snapshot.changes?.map(\.path) == ["new.txt"] && snapshot.changesError == nil)
        #expect(snapshot.summary?.headOID == head && snapshot.summaryError == nil)
        #expect(snapshot.summary?.baseOID == nil && snapshot.summary?.baseError != nil)
        let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(commands.filter { $0.contains("built-in: git fetch ") }.count == 1)
    }

    @Test(arguments: ["before-start", "between-resources", "after-completion"])
    func inspectionCancellationPreservesCompletedItems(_ timing: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        for group in ["first", "second"] { try await fixture.prepareEmptyGroup(group) }
        let record = try fixture.service.store.load(fixture.root)
        let inspection = Task {
            if timing == "before-start" { withUnsafeCurrentTask { $0?.cancel() } }
            return await fixture.service.inspect(record) { snapshot in
                let target = timing == "after-completion" ? "second" : "first"
                if snapshot.resource == .group(target) { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await inspection.value
        #expect(inspection.isCancelled)
        #expect(result.items.map(\.resource) == [.workspace(), .group("first"), .group("second")])
        let expected: [OperationStatus] = timing == "before-start" ? [.cancelled, .cancelled, .cancelled]
            : timing == "between-resources" ? [.success, .success, .cancelled] : [.success, .success, .success]
        #expect(result.items.map(\.status) == expected)
        #expect(result.status == (timing == "after-completion" ? .success : .cancelled))
        #expect(result.reasonCode == (timing == "after-completion" ? nil : "cancelled"))
        #expect(result.exitCode == (timing == "after-completion" ? 0 : 130))
    }

    @Test func inspectionCancellationKeepsEarlierFailures() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        for group in ["broken", "first", "second"] { try await fixture.prepareEmptyGroup(group) }
        let record = try fixture.service.store.load(fixture.root)
        try Data("gitdir: missing-git-directory\n".utf8).write(to: record.groupURL("broken").appending(path: ".git"))
        let inspection = Task {
            await fixture.service.inspect(record) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await inspection.value
        #expect(result.items.map(\.status) == [.success, .failed, .success, .cancelled])
        #expect(result.status == .partialSuccess && result.reasonCode == nil && result.exitCode == 1)
    }
}

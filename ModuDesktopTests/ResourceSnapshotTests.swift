import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

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

    @Test func scopedInspectionOnlyReadsTheRequestedResourceTypes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = try await prepare(fixture)
        let record = try service.store.load(fixture.root)
        let reads = fixture.directory.appending(path: "snapshot-reads")

        let repositories = await service.inspect(fixture.root, scope: .repositories)
        #expect(repositories.status == .success)
        #expect(repositories.items.map(\.resource) == [.workspace(), .repository("repo")])
        #expect(try readPaths(reads) == [PathSafety.identity(record.repositoryURL("repo"))])
        try FileManager.default.removeItem(at: reads)

        let worktrees = await service.inspect(fixture.root, scope: .worktrees)
        #expect(worktrees.status == .success)
        #expect(worktrees.items.map(\.resource) == [.workspace(), .group("feature"), .member("feature", "repo")])
        #expect(try readPaths(reads).sorted() == [PathSafety.identity(record.groupURL("feature")), PathSafety.identity(record.memberURL("feature", "repo"))].sorted())
    }

    @Test @MainActor func inspectionAndDetailPreloadShareOneStatusReadPerResource() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = try await prepare(fixture)
        let suite = fixture.directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: service)
        await model.workspace.reload()
        await model.workspace.detailPreloadTask?.value
        let record = try #require(model.workspace.record)
        let paths = try readPaths(fixture.directory.appending(path: "snapshot-reads")).filter { $0 != PathSafety.identity(record.rootURL) }
        #expect(paths.sorted() == service.resources(record).map { PathSafety.identity(record.rootURL.appending(path: $0.path)) }.sorted())
        #expect(model.workspace.states[Resource.member("feature", "repo").id]?.dirty == false)

        let path = record.memberURL("feature", "repo")
        try Data("new edit".utf8).write(to: path.appending(path: "new.txt"))
        model.workspace.selection = .member("feature", "repo")
        await model.workspace.details.detailTask?.value
        await model.workspace.detailPreloadTask?.value
        #expect(model.workspace.detail.changes?.map(\.path) == ["new.txt"])
    }

    private func prepare(_ fixture: Fixture) async throws -> WorkspaceService {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        let monitor = fixture.directory.appending(path: "snapshot-monitor")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$PWD" >> "$MODU_SNAPSHOT_READS"
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for root in [record.rootURL, record.repositoryURL("repo")] {
            _ = try await fixture.service.git.run(["config", "core.fsmonitor", monitor.path], at: root)
            _ = try await fixture.service.git.run(["config", "core.fsmonitorHookVersion", "2"], at: root)
        }
        var runner = fixture.service.git.runner
        runner.environment["MODU_SNAPSHOT_READS"] = fixture.directory.appending(path: "snapshot-reads").path
        return WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
    }

    private func readPaths(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { PathSafety.identity(URL(fileURLWithPath: String($0))) }
    }
}

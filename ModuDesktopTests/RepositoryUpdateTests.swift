import Foundation
import Testing
@testable import ModuCore

struct RepositoryUpdateTests {
    @Test(arguments: ["dirty", "staged", "untracked", "detached", "feature", "missing-base", "invalid-base", "origin-mismatch", "missing"])
    func preflightRejectsWithoutFetching(_ scenario: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success")
        let path = f.root.appending(path: "repositories/repo")
        let reason: String
        switch scenario {
        case "dirty", "staged", "untracked":
            try Data("local".utf8).write(to: path.appending(path: scenario == "untracked" ? "new" : "README"))
            if scenario == "staged" { _ = try await f.service.git.run(["add", "README"], at: path) }
            reason = "working-tree-dirty"
        case "detached":
            _ = try await f.service.git.run(["checkout", "--detach"], at: path)
            reason = "detached-head"
        case "feature":
            _ = try await f.service.git.run(["switch", "-c", "feature"], at: path)
            reason = "not-default-branch"
        case "missing-base":
            _ = try await f.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
            reason = "base-unavailable"
        case "invalid-base":
            _ = try await f.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"], at: path)
            reason = "base-unavailable"
        case "origin-mismatch":
            _ = try await f.service.git.run(["config", "remote.origin.url", "https://modu-test.invalid/other.git"], at: path)
            reason = "origin-mismatch"
        default:
            try FileManager.default.removeItem(at: path)
            reason = "resource-missing"
        }
        let (service, trace) = tracedService(f)
        let result = await service.updateRepositories(at: f.root)
        #expect(result.items.first?.reasonCode == reason)
        #expect(result.items.first?.effects.isEmpty == true)
        let commands = (try? String(contentsOf: trace, encoding: .utf8)) ?? ""
        #expect(!commands.contains(" fetch ") && !commands.contains("ls-remote"))
    }

    @Test func pullsNamedBaseOnceAndLeavesLinkedWorktreeUntouched() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success")
        try await f.commitWorkspace()
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        let path = f.root.appending(path: "repositories/repo"), source = f.directory.appending(path: "source")
        let member = f.root.appending(path: "worktrees/feature/repo")
        let original = try #require(await f.service.git.oid("HEAD", at: path))
        _ = try await f.service.git.run(["branch", "-m", "trunk"], at: path)
        _ = try await f.service.git.run(["update-ref", "refs/remotes/origin/trunk", original], at: path)
        _ = try await f.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], at: path)
        _ = try await f.service.git.run(["config", "pull.rebase", "true"], at: path)
        _ = try await f.service.git.run(["switch", "-c", "trunk"], at: source)
        try Data("upstream\n".utf8).write(to: source.appending(path: "README"))
        _ = try await f.service.git.run(["commit", "-am", "update trunk"], at: source)
        _ = try await f.service.git.run(["push", f.directory.appending(path: "repo.git").path, "trunk"], at: source)
        let (service, trace) = tracedService(f)
        let updated = await service.updateRepositories(at: f.root)
        #expect(updated.items.first?.data?["disposition"] == "updated", "\(updated.items)")
        #expect(try String(contentsOf: path.appending(path: "README"), encoding: .utf8) == "upstream\n")
        #expect(try await f.service.git.oid("HEAD", at: member) == original)
        #expect(try String(contentsOf: member.appending(path: "README"), encoding: .utf8) == "hello\n")
        #expect(try await f.service.git.oid("refs/remotes/origin/main", at: path) == original)
        #expect(try await f.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD"], at: path).text == "refs/remotes/origin/trunk")
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(commands.components(separatedBy: "\n").filter { $0.contains("built-in: git fetch ") }.count == 1)
        #expect(!commands.contains("ls-remote") && !commands.contains("worktree list") && !commands.contains("--git-common-dir"))
        #expect(await service.updateRepositories(at: f.root).items.first?.data?["disposition"] == "up-to-date")
    }

    @Test func divergentBaseDoesNotMergeOrRebaseLocalHistory() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success")
        let path = f.root.appending(path: "repositories/repo"), source = f.directory.appending(path: "source")
        _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "local"], at: path)
        let original = try #require(await f.service.git.oid("HEAD", at: path))
        _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "remote"], at: source)
        _ = try await f.service.git.run(["push", f.directory.appending(path: "repo.git").path, "main"], at: source)
        let result = await f.service.updateRepositories(at: f.root)
        #expect(result.status == "failed")
        #expect(result.items.first?.effects.first?.state == "applied")
        #expect(result.items.first?.data?["actual-head"] == original)
        #expect(result.items.first?.data?["working-tree"] == "clean")
        #expect(try await f.service.git.oid("HEAD", at: path) == original)
    }

    @Test func updatesAtMostSixAndRefillsSlotsWhileKeepingResultOrder() async throws {
        let batch = try await UpdateBatch(); defer { batch.fixture.remove() }
        let progress = UpdateProgress()
        let operation = Task { await batch.service.updateRepositories(at: batch.fixture.root) { progress.record($0.completed) } }
        do {
            try await batch.waitForStarts(6)
            try await Task.sleep(for: .milliseconds(150))
            #expect(try batch.started() == Set((0..<6).map { "repo\($0)" }))
            try Data().write(to: batch.probe.appending(path: "fail/repo3"))
            try batch.release(3)
            try await batch.waitForStarts(7)
            try batch.release(6)
            try await batch.waitForStarts(8)
            for index in 0..<8 { try batch.release(index) }
            let result = await operation.value
            #expect(result.status == "partial-success")
            #expect(result.items.map(\.resource.repo) == (0..<8).map { "repo\($0)" })
            #expect(result.items[3].status == "failed")
            #expect(result.items.enumerated().allSatisfy { $0.offset == 3 || $0.element.data?["disposition"] == "up-to-date" })
            #expect(progress.values == Array(0...8))
        } catch {
            operation.cancel(); _ = await operation.value
            throw error
        }
    }

    @Test func cancellationStopsAllActiveRepositoriesAndDoesNotStartQueuedOnes() async throws {
        let batch = try await UpdateBatch(); defer { batch.fixture.remove() }
        let operation = Task { await batch.service.updateRepositories(at: batch.fixture.root) }
        do {
            try await batch.waitForStarts(6)
            #expect(throws: ModuError.self) { try batch.service.store.lock(batch.fixture.root) }
            operation.cancel()
            let result = await operation.value
            #expect(result.status == "cancelled")
            #expect(try batch.started().count == 6)
            #expect(result.items.prefix(6).allSatisfy { $0.status == "cancelled" && $0.data?["working-tree"] == "clean" })
            #expect(result.items.suffix(2).allSatisfy { $0.reasonCode == "not-processed" && $0.effects.isEmpty })
            let lease = try batch.service.store.lock(batch.fixture.root)
            lease.unlock()
        } catch {
            operation.cancel(); _ = await operation.value
            throw error
        }
    }

    private func tracedService(_ f: Fixture) -> (WorkspaceService, URL) {
        let trace = f.directory.appending(path: "update-trace")
        var runner = f.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        return (WorkspaceService(store: f.service.store, git: Git(runner: runner)), trace)
    }
}

private struct UpdateBatch {
    let fixture: Fixture
    let service: WorkspaceService
    let probe: URL

    init() async throws {
        let f = try await Fixture()
        fixture = f
        #expect(await f.service.openWorkspace(f.root).status == "success")
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success")
        probe = f.directory.appending(path: "probe")
        for name in ["started", "release", "fail"] {
            try FileManager.default.createDirectory(at: probe.appending(path: name), withIntermediateDirectories: true)
        }
        let uploadPack = f.directory.appending(path: "upload-pack")
        try Data("""
        #!/bin/sh
        repo=$(basename "$1" .git)
        : > "$MODU_UPDATE_PROBE/started/$repo"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_UPDATE_PROBE/release/$repo" ]; do sleep 0.02; done
        if [ -e "$MODU_UPDATE_PROBE/fail/$repo" ]; then exit 1; fi
        exec /usr/bin/git upload-pack "$@"
        """.utf8).write(to: uploadPack)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uploadPack.path)
        let config = f.directory.appending(path: "gitconfig")
        var contents = try String(contentsOf: config, encoding: .utf8)
        contents += "\n[url \"\(f.directory.path)/\"]\n    insteadOf = https://modu-test.invalid/\n"
        try Data(contents.utf8).write(to: config)
        var record = try await f.service.load(f.root)
        record.repositories = []
        for index in 0..<8 {
            let repository = Repository(url: "https://modu-test.invalid/repo\(index).git")
            let path = record.repositoryURL(repository.id)
            try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: path)
            try FileManager.default.copyItem(at: f.directory.appending(path: "repo.git"), to: f.directory.appending(path: "repo\(index).git"))
            _ = try await f.service.git.run(["config", "remote.origin.url", repository.url], at: path)
            _ = try await f.service.git.run(["config", "remote.origin.uploadpack", "'\(uploadPack.path)'"], at: path)
            record.repositories.append(repository)
        }
        try f.service.store.save(record)
        var runner = f.service.git.runner
        runner.environment["MODU_UPDATE_PROBE"] = probe.path
        service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
    }

    func started() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: probe.appending(path: "started").path))
    }
    func release(_ index: Int) throws { try Data().write(to: probe.appending(path: "release/repo\(index)")) }
    func waitForStarts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try started().count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ModuError("test-timeout", "Expected \(count) concurrent update starts; got \(try started()).")
    }
}

private final class UpdateProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var values: [Int] { lock.withLock { recorded } }
    func record(_ count: Int) { lock.withLock { recorded.append(count) } }
}

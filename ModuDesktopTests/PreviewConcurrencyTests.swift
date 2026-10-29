import Foundation
import Testing
@testable import ModuCore

struct PreviewConcurrencyTests {
    @Test(arguments: ["remove-plan", "edit-plan", "remove-execute"])
    func slowRiskScansDoNotHoldTheWorkspaceLock(_ entry: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let scan = try await slowScan(fixture, record: record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let preview = Task {
            if entry == "edit-plan" {
                return await scan.service.editGroup("feature", repositories: [], at: fixture.root)
            }
            return await scan.service.remove(.member(group: "feature", repo: "repo"), at: fixture.root, execute: entry == "remove-execute")
        }
        do {
            try await waitFor(scan.started)
            let lease = try fixture.service.store.tryLock(fixture.root); lease.unlock()
            try Data().write(to: scan.release)
            let result = await preview.value
            if entry == "remove-execute" {
                #expect(result.status == .success)
                #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
                #expect(try fixture.service.store.load(fixture.root).groups["feature"]?.repositories == [])
            } else {
                #expect(result.status == .confirmationRequired)
                #expect(result.plan?.map(\.resource) == [.member("feature", "repo")])
                #expect(result.items.allSatisfy { $0.effects.isEmpty })
                #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
                #expect(PathSafety.exists(record.memberURL("feature", "repo")))
            }
        } catch {
            try? Data().write(to: scan.release)
            preview.cancel(); _ = await preview.value
            throw error
        }
    }

    @Test func directExecutionStillRejectsAnUnreadableIndexBeforeDeletingAnything() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let member = record.memberURL("feature", "repo")
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let index = record.repositoryURL("repo").appending(path: ".git/index")
        let invalidIndex = Data("invalid index".utf8)
        try invalidIndex.write(to: index)

        let result = await fixture.service.remove(.repository("repo"), at: fixture.root, execute: true)

        #expect(result.status == .failed && result.reasonCode == "git-failed")
        #expect(result.items.allSatisfy { $0.effects.isEmpty })
        #expect(PathSafety.exists(record.repositoryURL("repo")) && PathSafety.exists(member))
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try Data(contentsOf: index) == invalidIndex)
    }

    @Test func newlyRequiredRemovalsAfterAnUnlockedPreviewCannotExecuteWithoutConfirmation() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        _ = try await prepare(fixture)
        let other = "https://modu-test.invalid/other.git"
        _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", other], at: fixture.root)
        #expect(await fixture.service.addRepository(.init(url: other), at: fixture.root).status == .success)
        var record = try fixture.service.store.load(fixture.root)
        let trace = fixture.directory.appending(path: "edit-before-lock-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let lease = try fixture.service.store.tryLock(fixture.root); defer { lease.unlock() }
        let update = Task { await service.editGroup("feature", repositories: ["repo"], at: fixture.root) }
        do {
            try await waitFor(trace, containing: "check-ref-format refs/heads/feature")
            let member = record.memberURL("feature", "other")
            _ = try await fixture.service.git.run(["worktree", "add", "-b", "feature", member.path], at: record.repositoryURL("other"))
            record.groups["feature"]?.repositories.append("other")
            try fixture.service.store.save(record)
            lease.unlock()

            let result = await update.value

            #expect(result.status == .failed && result.reasonCode == "confirmation-changed")
            #expect(result.items.allSatisfy { $0.effects.isEmpty })
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(PathSafety.exists(member) && PathSafety.exists(record.memberURL("feature", "repo")))
        } catch {
            lease.unlock(); update.cancel(); _ = await update.value
            throw error
        }
    }

    @Test(arguments: ["remove", "edit"])
    func executionRejectsTargetsChangedDuringTheUnlockedRiskScan(_ operation: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let scan = try await slowScan(fixture, record: record)
        let preview = Task { try await scan.service.previewDelete(.member(group: "feature", repo: "repo"), at: fixture.root) }
        do {
            try await waitFor(scan.started)
            let lease = try fixture.service.store.tryLock(fixture.root)
            do {
                _ = try await fixture.service.git.run(["branch", "changed", "feature"], at: record.repositoryURL("repo"))
                _ = try await fixture.service.git.run(["symbolic-ref", "HEAD", "refs/heads/changed"], at: record.memberURL("feature", "repo"))
                lease.unlock()
            } catch { lease.unlock(); throw error }
            try Data().write(to: scan.release)
            let targets = try await preview.value
            #expect(targets.first?.branch == "feature")
            let result: OperationResult
            if operation == "edit" {
                result = await scan.service.editGroup("feature", repositories: [], at: fixture.root, authorization: targets)
            } else {
                result = await scan.service.remove(.member(group: "feature", repo: "repo"), at: fixture.root, authorization: targets)
            }
            #expect(result.status == .failed && result.reasonCode == "confirmation-changed")
            #expect(result.items.allSatisfy { $0.effects.isEmpty })
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(PathSafety.exists(record.memberURL("feature", "repo")))
        } catch {
            try? Data().write(to: scan.release)
            preview.cancel(); _ = try? await preview.value
            throw error
        }
    }

    private func prepare(_ fixture: Fixture) async throws -> WorkspaceRecord {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success)
        return try fixture.service.store.load(fixture.root)
    }

    private func slowScan(_ fixture: Fixture, record: WorkspaceRecord) async throws -> (service: WorkspaceService, started: URL, release: URL) {
        let probe = fixture.directory.appending(path: "preview-scan-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_PREVIEW_SCAN_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_PREVIEW_SCAN_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: record.repositoryURL("repo"))
        }
        var runner = fixture.service.git.runner
        runner.environment["MODU_PREVIEW_SCAN_PROBE"] = probe.path
        return (WorkspaceService(store: fixture.service.store, git: Git(runner: runner), trash: fixture.service.trashDirectory),
                probe.appending(path: "started"), probe.appending(path: "release"))
    }

    private func waitFor(_ path: URL, containing text: String? = nil) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let text {
                if (try? String(contentsOf: path, encoding: .utf8).contains(text)) == true { return }
            } else if PathSafety.exists(path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModuError("test-timeout", "The preview did not reach the expected Git scan.")
    }
}

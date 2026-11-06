import Foundation
import Darwin
import Testing
@testable import MonoDeckCore

struct WorktreeCleanupTests {
    @Test(arguments: ["non-internal", "missing-helper", "prepare-failed", "rename-failed"])
    func unavailableStagingFallsBackToGitDeletion(_ kind: String) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let member = record.memberURL("feature", "repo")
        let helper = fixture.directory.appending(path: "unused-cleanup-helper")
        let launched = fixture.directory.appending(path: "unexpected-cleanup")
        try Data("#!/bin/sh\n: > \"$MONO_DECK_UNEXPECTED_CLEANUP\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let temporary = kind == "rename-failed" ? member.appending(path: "temporary") : fixture.directory.appending(path: "removal-temporary")
        if kind == "prepare-failed" { try Data().write(to: temporary) }
        else { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false) }
        var service = fixture.service
        var runner = service.git.runner
        runner.environment["MONO_DECK_UNEXPECTED_CLEANUP"] = launched.path
        service.worktreeRemoval = .init(runner: runner, temporaryDirectory: temporary,
                                       helper: kind == "missing-helper" ? fixture.directory.appending(path: "missing-helper") : helper,
                                       isInternalLocalVolume: { _ in kind != "non-internal" })
        #expect(service.worktreeRemoval.canStage(member) == !["non-internal", "missing-helper"].contains(kind))

        let result = await service.deleteConfirmed(.member(groupName: "feature", repositoryID: "repo"), at: fixture.root)

        #expect(result.status == .success, "\(result.items)")
        #expect(!PathSafety.exists(member) && !PathSafety.exists(launched))
        #expect(try service.store.load(fixture.root).groups["feature"]?.repositoryIDs == [])
        #expect(try await service.git.registrations(at: record.repositoryURL("repo")).count == 1)
        #expect(try await service.git.oid("refs/heads/feature", at: record.repositoryURL("repo")) == nil)
    }

    @Test(arguments: ["delete", "cancelled", "edit"])
    func batchReturnsBeforeCleanupAndPreservesUnrelatedData(_ mode: String) async throws {
        let fixture = try await Fixture(template: .singleRepository)
        var canRemoveFixture = true
        defer { if canRemoveFixture { fixture.remove() } }
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let outside = fixture.directory.appending(path: "outside")
        _ = try await fixture.service.git.run(["worktree", "add", "-b", "outside", outside.path], at: record.repositoryURL("repo"))
        try FileManager.default.removeItem(at: outside)
        let probe = try WorktreeCleanupProbe(fixture)
        defer { probe.unlock() }
        let service = probe.service(fixture)
        let cancelAfterMember = mode == "cancelled"
        let keepsGroup = mode != "delete"
        do {
            let authorization: [DeletionTarget]?
            if mode == "edit" {
                authorization = try await service.previewDelete(.member(groupName: "feature", repositoryID: "repo"), at: fixture.root)
            } else { authorization = nil }
            let result = await Task {
                if let authorization {
                    return await service.editGroup("feature", repositoryIDs: [], at: fixture.root, authorization: authorization)
                }
                return await service.deleteConfirmed(.group("feature"), at: fixture.root) { progress in
                    if cancelAfterMember && progress.phase == .deleted && progress.target == Resource.member(groupName: "feature", repositoryID: "repo").path {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }.value
            let invocation = try await probe.invocation()
            #expect(result.status == (cancelAfterMember ? .cancelled : .success), "\(result.items)")
            #expect(invocation.entries.count == (keepsGroup ? 1 : 2))
            #expect(try probe.processIDs().count == 1)
            #expect(invocation.entries.allSatisfy { PathSafety.exists(invocation.directory.appending(path: $0)) })
            #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
            #expect(PathSafety.exists(record.groupURL("feature")) == keepsGroup)
            let registrations = try await service.git.registrations(at: record.repositoryURL("repo"))
            #expect(registrations.contains { $0.branch == "outside" }, "\(registrations)")
            #expect(!registrations.contains { $0.branch == "feature" }, "\(registrations)")
            #expect(try await service.git.oid("refs/heads/feature", at: record.repositoryURL("repo")) == nil)
            let saved = try service.store.load(fixture.root)
            #expect((saved.groups["feature"] != nil) == keepsGroup)
            if keepsGroup { #expect(saved.groups["feature"]?.repositoryIDs == []) }
            let retained = invocation.directory.appending(path: UUID().uuidString)
            try Data("keep me".utf8).write(to: retained)

            probe.unlock()
            try await probe.waitForExit()

            #expect(invocation.entries.allSatisfy { !PathSafety.exists(invocation.directory.appending(path: $0)) })
            #expect(try String(contentsOf: retained, encoding: .utf8) == "keep me")
        } catch {
            canRemoveFixture = await probe.stop()
            if !canRemoveFixture { Issue.record("Cleanup helper did not exit; retained fixture at \(fixture.directory.path).") }
            throw error
        }
    }

    @Test func failedUnregisterKeepsMovedDataOutOfCleanup() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        var canRemoveFixture = true
        defer { if canRemoveFixture { fixture.remove() } }
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let retainedName = "retained-user-data"
        try Data("keep me".utf8).write(to: record.groupURL("feature").appending(path: retainedName))
        _ = try await fixture.service.git.run(["worktree", "lock", record.groupURL("feature").path], at: fixture.root)
        let probe = try WorktreeCleanupProbe(fixture)
        defer { probe.unlock() }
        let service = probe.service(fixture)
        do {
            let result = await service.deleteConfirmed(.group("feature"), at: fixture.root)
            let invocation = try await probe.invocation()
            #expect(result.status == .partialSuccess)
            #expect(result.items.first?.status == .success && result.items.last?.reasonCode == "git-failed")
            #expect(result.items.last?.effects.first?.state == "unknown")
            #expect(invocation.entries.count == 1)
            #expect(!PathSafety.exists(record.groupURL("feature")))
            #expect(try service.store.load(fixture.root).groups["feature"]?.repositoryIDs == [])
            #expect(try await service.git.oid("refs/heads/feature", at: fixture.root) != nil)
            #expect(try await service.git.registrations(at: fixture.root).contains { $0.locked && $0.branch == "feature" })
            let retained = try #require(try FileManager.default.contentsOfDirectory(at: invocation.directory, includingPropertiesForKeys: nil).first {
                PathSafety.exists($0.appending(path: retainedName))
            })
            #expect(!invocation.entries.contains(retained.lastPathComponent))

            probe.unlock()
            try await probe.waitForExit()

            #expect(invocation.entries.allSatisfy { !PathSafety.exists(invocation.directory.appending(path: $0)) })
            #expect(try String(contentsOf: retained.appending(path: retainedName), encoding: .utf8) == "keep me")
        } catch {
            canRemoveFixture = await probe.stop()
            if !canRemoveFixture { Issue.record("Cleanup helper did not exit; retained fixture at \(fixture.directory.path).") }
            throw error
        }
    }
}

private final class WorktreeCleanupProbe {
    let directory: URL
    let temporary: URL
    let helper: URL
    let executable: URL
    private var descriptor: Int32

    init(_ fixture: Fixture) throws {
        directory = fixture.directory.appending(path: "cleanup-probe")
        temporary = directory.appending(path: "temporary")
        helper = directory.appending(path: "helper")
        executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$$" >> "$MONO_DECK_CLEANUP_PROBE/pids"
        printf '%s\\n' "$@" > "$MONO_DECK_CLEANUP_PROBE/arguments.tmp"
        /bin/mv "$MONO_DECK_CLEANUP_PROBE/arguments.tmp" "$MONO_DECK_CLEANUP_PROBE/arguments"
        exec "$MONO_DECK_CLEANUP_EXECUTABLE" "$@"
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        descriptor = open(temporary.appending(path: ".mono-deck-worktree-cleanup.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
    }

    func service(_ fixture: Fixture) -> WorkspaceService {
        var runner = fixture.service.git.runner
        runner.environment["TMPDIR"] = temporary.path
        runner.environment["MONO_DECK_CLEANUP_PROBE"] = directory.path
        runner.environment["MONO_DECK_CLEANUP_EXECUTABLE"] = executable.path
        var service = fixture.service
        service.worktreeRemoval = .init(runner: runner, temporaryDirectory: temporary, helper: helper, isInternalLocalVolume: { _ in true })
        return service
    }

    func invocation() async throws -> (directory: URL, entries: [String]) {
        let file = directory.appending(path: "arguments")
        try await waitUntil { PathSafety.exists(file) }
        let arguments = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        try #require(arguments.count >= 3 && arguments[0] == "--internal-cleanup-worktrees")
        return (URL(fileURLWithPath: arguments[1]), Array(arguments.dropFirst(2)))
    }

    func processIDs() throws -> [pid_t] {
        let file = directory.appending(path: "pids")
        guard PathSafety.exists(file) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    func waitForExit() async throws {
        try await waitUntil { try processIDs().allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    }

    func stop() async -> Bool {
        unlock()
        let processes = (try? processIDs()) ?? []
        for pid in processes where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) }
        do { try await waitForExit(); return true }
        catch {
            for pid in processes where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
            do { try await waitForExit(); return true }
            catch { return false }
        }
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MonoDeckError("test-timeout", "Expected the worktree cleanup helper to advance.")
    }
}

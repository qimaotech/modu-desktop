import Foundation
import Testing
@testable import MonoDeckCore

struct WorktreeCreationTests {
    @Test(arguments: ["root", "member"], ["prepared", "committed"])
    func cancellationDuringReferenceTransactionCleansTheNewBranch(_ kind: String, _ phase: String) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let probe = try installReferenceHook(at: repository, fixture: f, phase: phase)
        let task = Task { await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root) }
        let result: OperationResult
        do {
            try await waitFor(probe.started)
            task.cancel()
            result = await task.value
        } catch {
            task.cancel()
            try? Data().write(to: probe.release)
            _ = await task.value
            throw error
        }
        #expect(result.status == .cancelled, "\(result.items)")
        let resource: Resource = kind == "root" ? .group("feature") : .member(groupName: "feature", repositoryID: "repo")
        let item = try #require(result.items.first { $0.resource == resource })
        #expect(item.status == .cancelled && item.reasonCode == "cancelled")
        #expect(try await f.service.git.oid("refs/heads/feature", at: repository) == nil)
        #expect(!PathSafety.exists(record.rootURL.appending(path: resource.path)))
        let saved = try f.service.store.load(f.root)
        if kind == "root" { #expect(saved.groups["feature"] == nil) }
        else {
            #expect(saved.groups["feature"]?.repositoryIDs == [])
            #expect(PathSafety.exists(saved.groupURL("feature")))
            #expect(try await f.service.git.oid("refs/heads/feature", at: f.root) != nil)
        }
        if phase == "committed" {
            #expect(item.effects.contains { $0.action == "create-branch" && $0.target == "feature" && $0.state == "reverted" })
        }
        #expect(!item.effects.contains { $0.state == "unknown" })
        let lease = try f.service.store.tryLock(f.root); lease.unlock()
    }

    @Test(arguments: ["root", "member"])
    func cancellationDuringCheckoutKeepsTheReusedBranch(_ kind: String) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let oid = try #require(try await f.service.git.oid("HEAD", at: repository))
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", oid], at: repository)
        let started = f.directory.appending(path: "checkout-started"), release = f.directory.appending(path: "checkout-release")
        let hook = repository.appending(path: ".git/hooks/post-checkout")
        try Data("""
        #!/bin/sh
        : > "\(started.path)"
        trap 'exit 143' TERM INT
        while [ ! -e "\(release.path)" ]; do sleep 0.02; done
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let task = Task { await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root) }
        let result: OperationResult
        do {
            try await waitFor(started)
            task.cancel()
            result = await task.value
        } catch {
            task.cancel()
            try? Data().write(to: release)
            _ = await task.value
            throw error
        }
        #expect(result.status == .cancelled, "\(result.items)")
        #expect(try await f.service.git.oid("refs/heads/feature", at: repository) == oid)
        let resource: Resource = kind == "root" ? .group("feature") : .member(groupName: "feature", repositoryID: "repo")
        #expect(!PathSafety.exists(record.rootURL.appending(path: resource.path)))
        #expect(!result.items.flatMap(\.effects).contains { $0.action == "create-branch" && $0.state == "reverted" })
    }

    @Test func branchCleanupFailureReportsTheResidualBranch() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let probe = try installReferenceHook(at: f.root, fixture: f, phase: "committed", rejectDeletion: true)
        let task = Task { await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root) }
        let result: OperationResult
        do {
            try await waitFor(probe.started)
            task.cancel()
            result = await task.value
        } catch {
            task.cancel()
            try? Data().write(to: probe.release)
            _ = await task.value
            throw error
        }
        #expect(result.status == .failed && result.exitCode == 1)
        let item = try #require(result.items.first)
        #expect(item.reasonCode == "cleanup-failed" && item.causeCode == "cancelled")
        #expect(item.effects.contains { $0.action == "create-branch" && $0.target == "feature" && $0.state == "unknown" })
        #expect(try await f.service.git.oid("refs/heads/feature", at: f.root) != nil)
        #expect(try f.service.store.load(f.root).groups["feature"] == nil)
    }

    @Test(arguments: [("root", "ahead"), ("member", "diverged")])
    func reusedBranchReportsMissingBaseCommitsWithoutChangingItsHead(_ kind: String, _ history: String) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let original = try #require(try await f.service.git.oid("HEAD", at: repository))
        let base = history == "diverged" ? try await commit(after: original, message: "Base change", at: repository, git: f.service.git) : original
        let reused = try await commit(after: original, message: "Feature change", at: repository, git: f.service.git)
        _ = try await f.service.git.run(["update-ref", kind == "root" ? "refs/heads/main" : "refs/remotes/origin/main", base], at: repository)
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", reused], at: repository)
        let result = await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root)
        #expect(result.status == .success && result.exitCode == 0, "\(result.message ?? "") \(result.items)")
        let resource: Resource = kind == "root" ? .group("feature") : .member(groupName: "feature", repositoryID: "repo")
        let item = try #require(result.items.first { $0.resource == resource })
        let behind = history == "diverged"
        #expect(result.hasWarnings == behind && item.hasWarning == behind)
        if behind {
            #expect(item.data?["warning-code"] == "branch-behind-base")
            #expect(item.data?["reused-branch"] == "feature" && item.data?["behind-count"] == "1")
            #expect(item.data?["comparison-base"] == (kind == "root" ? "HEAD" : "origin/main"))
        } else { #expect(item.message == nil && item.data == nil) }
        #expect(try await f.service.git.oid("refs/heads/feature", at: repository) == reused)
        #expect(try await f.service.git.oid("HEAD", at: record.rootURL.appending(path: resource.path)) == reused)
    }

    @Test func reusedMemberWithUnavailableBaseKeepsItsBranchAndReportsTheComparison() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let repository = record.repositoryURL("repo")
        let oid = try #require(try await f.service.git.oid("HEAD", at: repository))
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", oid], at: repository)
        _ = try await f.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"], at: repository)
        let result = await f.service.createGroup("feature", repositoryIDs: ["repo"], at: f.root)
        #expect(result.status == .success && result.hasWarnings)
        let member = try #require(result.items.first { $0.resource.kind == .member })
        #expect(member.data?["warning-code"] == "branch-comparison-unavailable")
        #expect(member.data?["behind-count"] == nil && member.data?["comparison-error"] != nil)
        #expect(try await f.service.git.oid("HEAD", at: record.memberURL("feature", "repo")) == oid)
    }

    @Test func cliCreationReportsBranchWarningsWithoutChangingTheSuccessExitCode() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        let original = try #require(try await f.service.git.oid("HEAD", at: f.root))
        let base = try await commit(after: original, message: "Base change", at: f.root, git: f.service.git)
        _ = try await f.service.git.run(["update-ref", "refs/heads/main", base], at: f.root)
        let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
        var runner = f.service.git.runner
        runner.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] = f.service.store.support.path
        for json in [false, true] {
            let group = json ? "feature-json" : "feature-text"
            _ = try await f.service.git.run(["update-ref", "refs/heads/\(group)", original], at: f.root)
            let arguments = ["group", "create", group, "--repo", "repo", "--workspace", f.root.path] + (json ? ["--json"] : [])
            let output = try await runner.run(executable.path, arguments)
            #expect(output.status == 0, "\(output.text)")
            if json {
                let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
                #expect(result.status == .success && result.hasWarnings)
                #expect(result.items.first?.data?["behind-count"] == "1")
            } else {
                #expect(output.text.contains("group.create: success") && output.text.contains("1 commit behind 'workspace HEAD'"))
            }
            #expect(try await f.service.git.oid("HEAD", at: record.groupURL(group)) == original)
        }
    }

    private func installReferenceHook(at repository: URL, fixture: Fixture, phase: String, rejectDeletion: Bool = false) throws -> (started: URL, release: URL) {
        let started = fixture.directory.appending(path: "reference-started"), release = fixture.directory.appending(path: "reference-release")
        let zero = String(repeating: "0", count: 40)
        let hook = repository.appending(path: ".git/hooks/reference-transaction")
        try Data("""
        #!/bin/sh
        read old new ref
        if [ "\(rejectDeletion)" = true ] && [ "$1" = prepared ] && [ "$new" = "\(zero)" ]; then exit 1; fi
        if [ "$1" = "\(phase)" ] && [ "$ref" = refs/heads/feature ] && [ "$old" = "\(zero)" ] && [ "$new" != "\(zero)" ]; then
          : > "\(started.path)"
          trap 'exit 143' TERM INT
          while [ ! -e "\(release.path)" ]; do sleep 0.02; done
        fi
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        return (started, release)
    }

    private func waitFor(_ path: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(path))
    }

    private func commit(after parent: String, message: String, at repository: URL, git: Git) async throws -> String {
        let tree = try await git.run(["rev-parse", "--verify", "--end-of-options", "\(parent)^{tree}"], at: repository).text
        return try await git.run(["commit-tree", tree, "-p", parent, "-m", message], at: repository).text
    }
}

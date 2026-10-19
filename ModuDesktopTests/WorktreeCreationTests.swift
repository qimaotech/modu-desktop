import Foundation
import Testing
@testable import ModuCore

struct WorktreeCreationTests {
    @Test(arguments: ["root", "member"], ["prepared", "committed"])
    func cancellationDuringReferenceTransactionCleansTheNewBranch(_ kind: String, _ phase: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let probe = try installReferenceHook(at: repository, fixture: f, phase: phase)
        let task = Task { await f.service.createGroup("feature", repositories: ["repo"], at: f.root) }
        defer { task.cancel(); try? Data().write(to: probe.release) }
        try await waitFor(probe.started)
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled, "\(result.items)")
        let resource: Resource = kind == "root" ? .group("feature") : .member("feature", "repo")
        let item = try #require(result.items.first { $0.resource == resource })
        #expect(item.status == .cancelled && item.reasonCode == "cancelled")
        #expect(try await f.service.git.oid("refs/heads/feature", at: repository) == nil)
        #expect(!PathSafety.exists(record.rootURL.appending(path: resource.path)))
        let saved = try f.service.store.load(f.root)
        if kind == "root" { #expect(saved.groups["feature"] == nil) }
        else {
            #expect(saved.groups["feature"]?.repositories == [])
            #expect(PathSafety.exists(saved.groupURL("feature")))
            #expect(try await f.service.git.oid("refs/heads/feature", at: f.root) != nil)
        }
        if phase == "committed" {
            #expect(item.effects.contains { $0.action == "create-branch" && $0.target == "feature" && $0.state == "reverted" })
        }
        #expect(!item.effects.contains { $0.state == "unknown" })
        let lease = try f.service.store.lock(f.root); lease.unlock()
    }

    @Test(arguments: ["root", "member"])
    func cancellationDuringCheckoutKeepsTheReusedBranch(_ kind: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
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
        let task = Task { await f.service.createGroup("feature", repositories: ["repo"], at: f.root) }
        defer { task.cancel(); try? Data().write(to: release) }
        try await waitFor(started)
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled, "\(result.items)")
        #expect(try await f.service.git.oid("refs/heads/feature", at: repository) == oid)
        let resource: Resource = kind == "root" ? .group("feature") : .member("feature", "repo")
        #expect(!PathSafety.exists(record.rootURL.appending(path: resource.path)))
        #expect(!result.items.flatMap(\.effects).contains { $0.action == "create-branch" && $0.state == "reverted" })
    }

    @Test func branchCleanupFailureReportsTheResidualBranch() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await prepare(f)
        let probe = try installReferenceHook(at: f.root, fixture: f, phase: "committed", rejectDeletion: true)
        let task = Task { await f.service.createGroup("feature", repositories: ["repo"], at: f.root) }
        defer { task.cancel(); try? Data().write(to: probe.release) }
        try await waitFor(probe.started)
        task.cancel()
        let result = await task.value
        #expect(result.status == .failed && result.exitCode == 1)
        let item = try #require(result.items.first)
        #expect(item.reasonCode == "cleanup-failed" && item.causeCode == "cancelled")
        #expect(item.effects.contains { $0.action == "create-branch" && $0.target == "feature" && $0.state == "unknown" })
        #expect(try await f.service.git.oid("refs/heads/feature", at: f.root) != nil)
        #expect(try f.service.store.load(f.root).groups["feature"] == nil)
    }

    @Test(arguments: ["root", "member"], ["same", "behind", "ahead", "diverged"])
    func reusedBranchReportsMissingBaseCommitsWithoutChangingItsHead(_ kind: String, _ history: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let original = try #require(try await f.service.git.oid("HEAD", at: repository))
        let base = ["behind", "diverged"].contains(history) ? try await commit(after: original, message: "Base change", at: repository, git: f.service.git) : original
        let reused = ["ahead", "diverged"].contains(history) ? try await commit(after: original, message: "Feature change", at: repository, git: f.service.git) : original
        _ = try await f.service.git.run(["update-ref", kind == "root" ? "refs/heads/main" : "refs/remotes/origin/main", base], at: repository)
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", reused], at: repository)
        let result = await f.service.createGroup("feature", repositories: ["repo"], at: f.root)
        #expect(result.status == .success && result.exitCode == 0, "\(result.message ?? "") \(result.items)")
        let resource: Resource = kind == "root" ? .group("feature") : .member("feature", "repo")
        let item = try #require(result.items.first { $0.resource == resource })
        let behind = ["behind", "diverged"].contains(history)
        #expect(result.hasWarnings == behind && item.hasWarning == behind)
        if behind {
            #expect(item.data?["warning-code"] == "branch-behind-base")
            #expect(item.data?["reused-branch"] == "feature" && item.data?["behind-count"] == "1")
            #expect(item.data?["comparison-base"] == (kind == "root" ? "HEAD" : "origin/main"))
            #expect(item.message?.contains("1 commit behind") == true)
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            let items = try #require(json["items"] as? [[String: Any]])
            #expect(items.contains { ($0["data"] as? [String: String])?["warning-code"] == "branch-behind-base" })
        } else { #expect(item.message == nil && item.data == nil) }
        #expect(try await f.service.git.oid("refs/heads/feature", at: repository) == reused)
        #expect(try await f.service.git.oid("HEAD", at: record.rootURL.appending(path: resource.path)) == reused)
    }

    @Test(arguments: ["missing", "invalid"])
    func reusedMemberWithUnavailableBaseKeepsItsBranchAndReportsTheComparison(_ kind: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let repository = record.repositoryURL("repo")
        let oid = try #require(try await f.service.git.oid("HEAD", at: repository))
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", oid], at: repository)
        let arguments = kind == "missing" ? ["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"] : ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"]
        _ = try await f.service.git.run(arguments, at: repository)
        let result = await f.service.createGroup("feature", repositories: ["repo"], at: f.root)
        #expect(result.status == .success && result.hasWarnings)
        let member = try #require(result.items.first { $0.resource.kind == .member })
        #expect(member.data?["warning-code"] == "branch-comparison-unavailable")
        #expect(member.data?["behind-count"] == nil && member.data?["comparison-error"] != nil)
        #expect(try await f.service.git.oid("HEAD", at: record.memberURL("feature", "repo")) == oid)
    }

    @Test func editingNewMembersUsesTheSameBranchComparison() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == .success)
        #expect(await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, execute: true).status == .success)
        let repository = record.repositoryURL("repo")
        let original = try #require(try await f.service.git.oid("HEAD", at: repository))
        let base = try await commit(after: original, message: "Base change", at: repository, git: f.service.git)
        _ = try await f.service.git.run(["update-ref", "refs/remotes/origin/main", base], at: repository)
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", original], at: repository)
        let result = await f.service.editGroup("feature", repositories: ["repo"], at: f.root)
        #expect(result.status == .success && result.hasWarnings)
        #expect(result.items.count == 1 && result.items.first?.data?["behind-count"] == "1")
    }

    @Test(arguments: [false, true])
    func cliCreationReportsBranchWarningsWithoutChangingTheSuccessExitCode(_ json: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let original = try #require(try await f.service.git.oid("HEAD", at: f.root))
        let base = try await commit(after: original, message: "Base change", at: f.root, git: f.service.git)
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", original], at: f.root)
        _ = try await f.service.git.run(["update-ref", "refs/heads/main", base], at: f.root)
        let executable = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        var runner = f.service.git.runner
        runner.environment["MODU_TEST_SUPPORT_DIRECTORY"] = f.service.store.support.path
        let arguments = ["worktree", "create", "feature", "--repo", "repo", "--workspace", f.root.path] + (json ? ["--json"] : [])
        let output = try await runner.run(executable.path, arguments)
        #expect(output.status == 0, "\(output.text)")
        if json {
            let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
            #expect(result.status == .success && result.hasWarnings)
            #expect(result.items.first?.data?["behind-count"] == "1")
        } else {
            #expect(output.text.contains("worktree.create: success") && output.text.contains("1 commit behind 'workspace HEAD'"))
        }
        #expect(try await f.service.git.oid("HEAD", at: record.groupURL("feature")) == original)
    }

    @Test func workspaceImportReportsWarningsForAReusedRootBranch() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let original = try #require(try await f.service.git.oid("HEAD", at: f.root))
        let base = try await commit(after: original, message: "Base change", at: f.root, git: f.service.git)
        _ = try await f.service.git.run(["update-ref", "refs/heads/feature", original], at: f.root)
        _ = try await f.service.git.run(["update-ref", "refs/heads/main", base], at: f.root)
        let yaml = """
        version: 1
        repositories: []
        groups:
          feature:
            created-at: "2026-10-12T10:00:00Z"
            repositories: []
        """
        let result = await f.service.importWorkspaceYAML(yaml, at: f.root)
        #expect(result.status == .success && result.hasWarnings, "\(result.message ?? "") \(result.items)")
        #expect(result.items.first?.data?["behind-count"] == "1")
        #expect(try f.service.store.load(f.root).groups["feature"]?.repositories == [])
        #expect(try await f.service.git.oid("refs/heads/feature", at: f.root) == original)
    }

    private func prepare(_ f: Fixture) async throws -> WorkspaceRecord {
        #expect(await f.service.openWorkspace(f.root).status == .success)
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
        try await f.commitWorkspace()
        return try f.service.store.load(f.root)
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

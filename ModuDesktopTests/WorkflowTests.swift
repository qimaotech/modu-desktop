import Foundation
import Testing
@testable import ModuCore

struct WorkflowTests {
    @Test func deletionPreviewChecksMembersConcurrentlyAndPreservesOrderAndRisks() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await prepare(f)
        var record = try await f.service.load(f.root)
        let other = Repository(url: "https://modu-test.invalid/other.git")
        try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL(other.id))
        _ = try await f.service.git.run(["config", "remote.origin.url", other.url], at: record.repositoryURL(other.id))
        record.repositories.append(other)
        try f.service.store.save(record)
        _ = try await f.service.git.ensureIgnore([other.id], at: f.root)
        try await f.commitWorkspace()
        #expect(await f.service.createGroup("feature", repositories: ["repo", other.id], at: f.root).status == "success")
        record = try await f.service.load(f.root)
        let member = record.memberURL("feature", "repo")
        try Data("/ignored/\n/ignored.txt\n".utf8).write(to: record.repositoryURL("repo").appending(path: ".git/info/exclude"))
        let ignored = member.appending(path: "ignored/nested")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: ignored.appending(path: "file.txt"))
        try Data("ignored".utf8).write(to: member.appending(path: "ignored.txt"))
        try Data("changed".utf8).write(to: record.memberURL("feature", other.id).appending(path: "README"))

        let probe = f.directory.appending(path: "delete-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_DELETE_PROBE/$(basename "$PWD")"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_DELETE_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for repo in ["repo", other.id] {
            for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
                _ = try await f.service.git.run(arguments, at: record.repositoryURL(repo))
            }
        }
        var runner = f.service.git.runner
        runner.environment["MODU_DELETE_PROBE"] = probe.path
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let preview = Task { try await service.previewDelete(.group("feature"), at: f.root) }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while (!PathSafety.exists(probe.appending(path: "repo")) || !PathSafety.exists(probe.appending(path: other.id))), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(PathSafety.exists(probe.appending(path: "repo")) && PathSafety.exists(probe.appending(path: other.id)))
            try Data().write(to: probe.appending(path: "release"))
            let targets = try await preview.value
            #expect(targets.map(\.resource) == [.member("feature", "repo"), .member("feature", other.id), .group("feature")])
            #expect(targets.allSatisfy { $0.branch == "feature" && $0.exists && $0.registered })
            #expect(targets[0].risks.contains("Working tree is clean."))
            #expect(targets[0].risks.contains("Ignored files will be permanently deleted."))
            #expect(targets[1].risks.contains("1 changed paths will be permanently deleted."))
            #expect(targets[2].risks.contains { $0.contains("commits are not reachable") })
            try FileManager.default.removeItem(at: ignored.appending(path: "file.txt"))
            let fileOnly = try await service.previewDelete(.member(group: "feature", repo: "repo"), at: f.root)
            #expect(fileOnly[0].risks.contains("Ignored files will be permanently deleted."))
            try FileManager.default.removeItem(at: member.appending(path: "ignored.txt"))
            let empty = try await service.previewDelete(.member(group: "feature", repo: "repo"), at: f.root)
            #expect(!empty[0].risks.contains("Ignored files will be permanently deleted."))
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            preview.cancel()
            _ = try? await preview.value
            throw error
        }
    }
    @Test func actualBranchDeletionAndConfirmationChange() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        let member = f.root.appending(path: "worktrees/feature/repo")
        let old = try await f.service.previewDelete(.member(group: "feature", repo: "repo"), at: f.root)
        _ = try await f.service.git.run(["switch", "-c", "external-branch"], at: member)
        let changed = await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, authorization: old)
        #expect(changed.reasonCode == "confirmation-changed")
        #expect(PathSafety.exists(member))
        let deleted = await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, execute: true)
        #expect(deleted.status == "success")
        let main = f.root.appending(path: "repositories/repo")
        #expect(try await f.service.git.oid("refs/heads/feature", at: main) != nil)
        #expect(try await f.service.git.oid("refs/heads/external-branch", at: main) == nil)
    }
    @Test func detachedAndMissingWorktrees() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        let member = f.root.appending(path: "worktrees/feature/repo")
        _ = try await f.service.git.run(["checkout", "--detach"], at: member)
        let preview = try await f.service.previewDelete(.member(group: "feature", repo: "repo"), at: f.root)
        #expect(preview[0].detached); #expect(preview[0].branch == nil)
        #expect(await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, execute: true).status == "success")
        #expect(try await f.service.git.oid("refs/heads/feature", at: f.root.appending(path: "repositories/repo")) != nil)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        try FileManager.default.removeItem(at: member)
        let missing = await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, execute: true)
        #expect(missing.status == "success", "\(missing.message ?? "") \(missing.items)")
    }
    @Test func creationFailureRetainsSavedRootAndCleansNewBranch() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let failingStore = WorkspaceStore(support: f.service.store.support) { data, url in
            let record = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
            if record.groups["feature"]?.repositories.isEmpty == false { throw ModuError("fixture-write-failed", "Injected member save failure") }
            try data.write(to: url, options: .atomic)
        }
        let service = WorkspaceService(store: failingStore, git: f.service.git)
        let result = await service.createGroup("feature", repositories: ["repo"], at: f.root)
        #expect(result.status == "partial-success")
        let record = try await f.service.load(f.root)
        #expect(record.groups["feature"]?.repositories == [])
        #expect(PathSafety.exists(record.groupURL("feature")))
        #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
        #expect(try await f.service.git.oid("refs/heads/feature", at: record.repositoryURL("repo")) == nil)
    }
    @Test func uncertainSaveKeepsResourcesAndRecordsEffects() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let failing = WorkspaceStore(support: f.service.store.support) { data, url in
            let record = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
            if record.groups["feature"] != nil { try Data("invalid".utf8).write(to: url); throw ModuError("fixture-failure", "Injected uncertain save") }
            try data.write(to: url)
        }
        let result = await WorkspaceService(store: failing, git: f.service.git).createGroup("feature", repositories: ["repo"], at: f.root)
        #expect(result.items.first?.reasonCode == "save-outcome-unknown")
        #expect(result.items.last?.resource == .member("feature", "repo"))
        #expect(result.items.last?.reasonCode == "not-processed")
        #expect(PathSafety.exists(f.root.appending(path: "worktrees/feature")))
    }
    @Test func yamlRoundTripAndEmptyImportBoundary() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        #expect(await f.service.editGroup("feature", repositories: [], at: f.root).status == "confirmation-required")
        #expect(await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, execute: true).status == "success")
        let yaml = try await f.service.exportYAML(at: f.root)
        #expect(!yaml.contains("root:")); #expect(!yaml.contains("branch:"))
        let rejected = await f.service.importWorkspaceYAML(yaml, at: f.root)
        #expect(rejected.reasonCode == "workspace-not-empty")
        let second = f.directory.appending(path: "second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        #expect(await f.service.openWorkspace(second).status == "success")
        let imported = await f.service.importWorkspaceYAML(yaml, at: second)
        #expect(imported.status == "success", "\(imported.message ?? "") \(imported.items)")
        #expect(try await f.service.load(second).groups["feature"]?.repositories == [])
    }
    @Test func yamlAppendDeduplicatesAndDoesNotChangeName() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = await f.service.openWorkspace(f.root)
        #expect(await f.service.addRepository(.init(url: f.remoteURL, name: "Custom"), at: f.root).status == "success")
        let result = await f.service.importRepositoryYAML("values: [\(f.remoteURL), \(f.remoteURL)]", at: f.root)
        #expect(result.status == "skipped")
        #expect(try await f.service.load(f.root).repositories.first?.name == "Custom")
        #expect(result.items.map(\.reasonCode) == ["already-exists", "duplicate-url"])
        let conflict = await f.service.importRepositoryYAML("a: https://other.invalid/repo.git\nb: https://another.invalid/repo.git", at: f.root)
        #expect(conflict.items.allSatisfy { $0.reasonCode == "repository-conflict" })
    }
    @Test func fastForwardAndIgnoredProtection() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let source = f.directory.appending(path: "source"), main = f.root.appending(path: "repositories/repo")
        try Data("upstream\n".utf8).write(to: source.appending(path: "README"))
        _ = try await f.service.git.run(["add", "README"], at: source)
        _ = try await f.service.git.run(["commit", "-m", "upstream"], at: source)
        _ = try await f.service.git.run(["push", f.directory.appending(path: "repo.git").path, "main"], at: source)
        let updated = await f.service.updateRepositories(at: f.root)
        #expect(updated.items.first?.data?["disposition"] == "updated", "\(updated.items)")
        #expect(try String(contentsOf: main.appending(path: "README"), encoding: .utf8) == "upstream\n")
        try Data("/secret\n".utf8).write(to: main.appending(path: ".git/info/exclude"))
        try Data("local-secret".utf8).write(to: main.appending(path: "secret"))
        try Data("remote".utf8).write(to: source.appending(path: "secret"))
        _ = try await f.service.git.run(["add", "secret"], at: source)
        _ = try await f.service.git.run(["commit", "-m", "add secret path"], at: source)
        _ = try await f.service.git.run(["push", f.directory.appending(path: "repo.git").path, "main"], at: source)
        let protected = await f.service.updateRepositories(at: f.root)
        #expect(protected.status == "failed")
        #expect(try String(contentsOf: main.appending(path: "secret"), encoding: .utf8) == "local-secret")
    }
    @Test func changesAndCommitsIndependentOfBase() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let main = f.root.appending(path: "repositories/repo")
        let base = try #require(await f.service.git.oid("HEAD", at: main))
        for index in 0..<32 { _ = try await f.service.git.run(["commit", "--allow-empty", "-m", "commit \(index)"], at: main) }
        let head = try #require(await f.service.git.oid("HEAD", at: main))
        #expect(try await f.service.git.commits(at: main, head: head, base: base).count == 30)
        #expect(try await f.service.git.commits(at: main, head: head, base: base, skip: 30).count == 2)
        _ = try await f.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: main)
        try Data("new".utf8).write(to: main.appending(path: "untracked"))
        #expect(try await f.service.git.summary(at: main, origin: f.remoteURL).baseError != nil)
        #expect(try await f.service.git.changes(at: main).contains { $0.path == "untracked" })
    }
    @Test(arguments: [false, true])
    func groupInspectionShowsOwnGitStateWithoutRequiringOrigin(_ hasRemote: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        if hasRemote { _ = try await f.service.git.run(["remote", "add", "upstream", f.remoteURL], at: f.root) }
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        let record = try await f.service.load(f.root)
        let group = Resource.group("feature")
        let head = try #require(await f.service.git.oid("HEAD", at: record.groupURL("feature")))
        try Data("member".utf8).write(to: record.memberURL("feature", "repo").appending(path: "member.txt"))
        let cleanInspection = await f.service.inspect(f.root)
        let clean = try #require(cleanInspection.items.first { $0.resource == group })
        #expect(clean.status == "success")
        #expect(clean.data?["working-tree"] == "clean")
        #expect(clean.data?["head"] == "feature" && clean.data?["head-oid"] == head)
        #expect(clean.data?["base"] == nil)
        #expect((clean.data?["base-error"] != nil) == hasRemote)

        try Data("group".utf8).write(to: record.groupURL("feature").appending(path: "group.txt"))
        let dirtyInspection = await f.service.inspect(f.root)
        let dirty = try #require(dirtyInspection.items.first { $0.resource == group })
        #expect(dirty.status == "success" && dirty.data?["working-tree"] == "dirty")
        #expect(dirty.data?["head-oid"] == head)
    }
    @Test func unsafeResourcesAndUncommittedIgnoreAreRejected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let outside = f.directory.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.root.appending(path: "repositories"), withDestinationURL: outside)
        #expect(await f.service.openWorkspace(f.root).status == "failed")
        try FileManager.default.removeItem(at: f.root.appending(path: "repositories"))
        _ = await f.service.openWorkspace(f.root)
        try await f.commitWorkspace()
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success")
        _ = try await f.service.git.run(["branch", "feature", "HEAD~1"], at: f.root)
        let result = await f.service.createGroup("feature", repositories: ["repo"], at: f.root)
        #expect(result.reasonCode == "workspace-ignore-required")
        #expect(!PathSafety.exists(f.root.appending(path: "worktrees/feature")))
    }
    @Test func cliDoesNotWriteCoverageProfiles() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        let executable = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        var runner = f.service.git.runner
        runner.environment["MODU_TEST_SUPPORT_DIRECTORY"] = f.service.store.support.path
        runner.environment.removeValue(forKey: "LLVM_PROFILE_FILE")
        for arguments in [["--version"], ["--help"], ["repo", "list", "--json", "--workspace", f.root.path]] {
            let output = try await runner.run(executable.path, arguments, at: f.root)
            #expect(output.status == 0, "\(output.text)")
            #expect(!PathSafety.exists(f.root.appending(path: "default.profraw")))
        }
    }
    @Test func cliJSONContractAndMissingUpdateMembersHaveNoEffects() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let executable = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        var runner = f.service.git.runner
        runner.environment["MODU_TEST_SUPPORT_DIRECTORY"] = f.service.store.support.path
        let original = try Data(contentsOf: f.service.store.recordURL(f.root))
        let failure = try await runner.run(executable.path, ["--workspace", f.root.path, "worktree", "update", "feature", "--execute", "--json"])
        #expect(failure.status == 2)
        let json = try JSONSerialization.jsonObject(with: failure.stdout) as! [String: Any]
        #expect(json["schema-version"] as? Int == 1)
        #expect(json["reason-code"] as? String == "invalid-input")
        #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == original)
        let list = try await runner.run(executable.path, ["--workspace", f.root.path, "repo", "list", "--json"])
        #expect(list.status == 0, "\(list.text)")
        let result = try JSONDecoder().decode(OperationResult.self, from: list.stdout)
        #expect(result.items.count == 1)
        let preview = try await runner.run(executable.path, ["repo", "remove", "repo", "--json", "--workspace", f.root.path])
        #expect(preview.status == 1)
        #expect(try JSONDecoder().decode(OperationResult.self, from: preview.stdout).status == "confirmation-required")
    }
    @Test func groupNameHEADIsAlwaysAnExplicitLocalBranch() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let result = await f.service.createGroup("HEAD", repositories: ["repo"], at: f.root)
        #expect(result.status == "success", "\(result.message ?? "") \(result.items)")
        let root = f.root.appending(path: "worktrees/HEAD")
        #expect(try await f.service.git.run(["symbolic-ref", "HEAD"], at: root).text == "refs/heads/HEAD")
        #expect(try await f.service.git.run(["symbolic-ref", "HEAD"], at: root.appending(path: "repo")).text == "refs/heads/HEAD")
        #expect(await f.service.remove(.group("HEAD"), at: f.root, execute: true).status == "success")
    }
    @Test(arguments: ["saved", "missing", "corrupt", "stale"])
    func workspaceOpeningUsesHistoryWithoutRecoveringDiskResources(_ history: String) async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        #expect(await f.service.createGroup("empty", repositories: ["repo"], at: f.root).status == "success")
        #expect(await f.service.remove(.member(group: "empty", repo: "repo"), at: f.root, execute: true).status == "success")
        let group = f.root.appending(path: "worktrees/feature")
        let member = group.appending(path: "repo")
        _ = try await f.service.git.run(["checkout", "-b", "different-branch"], at: group)
        _ = try await f.service.git.run(["checkout", "--detach"], at: member)
        let head = try await f.service.git.oid("HEAD", at: member)
        try Data("user changes".utf8).write(to: member.appending(path: "README"))
        let record = f.service.store.recordURL(f.root)
        var saved = try await f.service.load(f.root)
        saved.repositories[0].name = "Custom"
        saved.groups["feature"]?.createdAt = "2001-01-01T00:00:00Z"
        saved.groups["empty"]?.createdAt = "2002-01-01T00:00:00Z"
        switch history {
        case "missing": try FileManager.default.removeItem(at: record)
        case "corrupt": try Data("invalid".utf8).write(to: record)
        case "stale": try f.service.store.save(WorkspaceRecord(root: PathSafety.canonical(f.root).path))
        default: try f.service.store.save(saved)
        }
        let original = PathSafety.exists(record) ? try Data(contentsOf: record) : nil
        let unmanaged = f.root.appending(path: "repositories/unmanaged")
        try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: false)
        let opened = await f.service.openWorkspace(f.root)
        if history == "saved" || history == "stale" {
            #expect(opened.status == "success", "\(opened.items)")
            #expect(try await f.service.load(f.root) == (history == "saved" ? saved : WorkspaceRecord(root: PathSafety.canonical(f.root).path)))
        } else {
            #expect(opened.status == "failed")
            #expect(opened.items.first?.reasonCode == (history == "missing" ? "workspace-not-empty" : "invalid-configuration"))
        }
        if let original { #expect(try Data(contentsOf: record) == original) }
        else { #expect(!PathSafety.exists(record)) }
        #expect(PathSafety.exists(unmanaged))
        #expect(try await f.service.git.oid("HEAD", at: member) == head)
        #expect(try await f.service.git.run(["symbolic-ref", "--short", "HEAD"], at: group).text == "different-branch")
        #expect(try await f.service.git.run(["symbolic-ref", "HEAD"], at: member, allowFailure: true).status != 0)
        #expect(try String(contentsOf: member.appending(path: "README"), encoding: .utf8) == "user changes")
        #expect(opened.items.allSatisfy { $0.effects.isEmpty })
    }
    @Test(arguments: ["origin", "name", "symlink", "group", "member", "root"])
    func unavailableDiskResourcesKeepHistoryAndReportTheirState(_ kind: String) async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == "success")
        let repository = f.root.appending(path: "repositories/repo")
        let group = f.root.appending(path: "worktrees/feature")
        let record = f.service.store.recordURL(f.root)
        let original = try Data(contentsOf: record)
        var expected = try await f.service.load(f.root)
        switch kind {
        case "origin": _ = try await f.service.git.run(["config", "remote.origin.url", "/tmp/local-repo"], at: repository)
        case "name":
            try FileManager.default.moveItem(at: repository, to: repository.deletingLastPathComponent().appending(path: "wrong-name"))
            expected.repositories = []
            expected.groups["feature"]?.repositories = []
        case "symlink":
            let outside = f.directory.appending(path: "outside-repo")
            try FileManager.default.moveItem(at: repository, to: outside)
            try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)
        case "group", "member":
            let path = kind == "group" ? group : group.appending(path: "repo")
            try FileManager.default.removeItem(at: path.appending(path: ".git"))
            _ = try await f.service.git.run(["init"], at: path)
        default: try FileManager.default.removeItem(at: f.root.appending(path: ".git"))
        }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        #expect(try await f.service.load(f.root) == expected)
        if kind != "name" { #expect(try Data(contentsOf: record) == original) }
        let inspection = await f.service.inspect(f.root)
        if kind != "name" {
            let resource: Resource = kind == "group" || kind == "root" ? .group("feature") : kind == "member" ? .member("feature", "repo") : .repository("repo")
            #expect(inspection.items.first { $0.resource == resource }?.status == "failed")
        }
        let actualRepository = kind == "name" ? repository.deletingLastPathComponent().appending(path: "wrong-name") : repository
        #expect(PathSafety.exists(actualRepository) && PathSafety.exists(group))
    }
    private func prepare(_ fixture: Fixture) async throws {
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
    }
}

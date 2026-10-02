import Foundation
import Testing
@testable import ModuCore

struct ModuCoreTests {
    @Test func urlAndStatusParsing() throws {
        for url in ["https://example.test/team/service.git", "ssh://git@example.test/team/service", "git@example.test:team/service.git"] { #expect(try RepositoryIdentity(url).name == "service") }
        for url in ["/tmp/repo", "file:///tmp/repo", "https://token@example.test/team/a", "https://u:p@example.test/a", "ssh://git@example.test/../..", "git@example.test:x/../../"] { #expect(throws: ModuError.self) { try RepositoryIdentity(url) } }
        let changes = try Git.parseChanges(Data("AD file\0R  new\npath\0old\tpath\0?? untracked\0UU conflict\0".utf8))
        #expect(changes.first { $0.path == "file" }?.index == "A")
        #expect(changes.first { $0.path == "file" }?.workingTree == "D")
        #expect(changes.first { $0.path == "new\npath" }?.originalPath == "old\tpath")
        #expect(changes.first { $0.path == "conflict" }?.conflict == true)
        let encoded = try JSONEncoder().encode(ItemResult(.repository("service")))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["reason-code"] is NSNull); #expect(object["message"] is NSNull)
    }
    @Test func configurationAndYAMLValidation() throws {
        #expect(throws: (any Error).self) { try ConfigValidation.validateDocument("{\"version\":1,\"version\":1}", workspace: true) }
        #expect(throws: (any Error).self) { try ConfigValidation.validateDocument("version: 1\nunknown: true", workspace: false) }
        #expect(throws: (any Error).self) { try WorkspaceService.repositoryURLs(in: "items: [oops") }
        let urls = try WorkspaceService.repositoryURLs(in: "a:\n  - https://example.test/a.git\n  - nested: git@example.test:b\n  - echo https://example.test/c\nhttps://example.test/key: ignored")
        #expect(urls == ["https://example.test/a.git", "git@example.test:b"])
        #expect(try WorkspaceService.repositoryURLs(in: "url: &repo https://example.test/a.git\nagain: *repo").count == 2)
        #expect(throws: (any Error).self) { try WorkspaceService.repositoryURLs(in: "loop: &loop [*loop]") }
    }
    @Test(arguments: ["new", "recorded", "missing-metadata"])
    func openingNonGitWorkspaceInitializesGit(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let root = fixture.root
        let notes = root.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: notes)
        switch kind {
        case "recorded": try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(root).path))
        case "missing-metadata":
            #expect(await fixture.service.openWorkspace(root).status == "success")
            try await fixture.commitWorkspace()
            try FileManager.default.removeItem(at: root.appending(path: ".git"))
        default: break
        }
        #expect(try await fixture.service.candidate(root) == PathSafety.canonical(root))
        #expect(!PathSafety.exists(root.appending(path: ".git")))
        let opened = await fixture.service.openWorkspace(root)
        #expect(opened.status == "success", "\(opened.items)")
        #expect(opened.items.flatMap(\.effects).contains { $0.action == "git-init" })
        try await fixture.service.git.checkRepository(root, main: true)
        #expect(try await fixture.service.git.oid("HEAD", at: root) != nil)
        #expect(try await fixture.service.git.run(["ls-files"], at: root).text == ".gitignore")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "keep me")
        #expect(try await fixture.service.load(root).repositories.isEmpty)
        let reopened = await fixture.service.openWorkspace(root)
        #expect(reopened.status == "success")
        #expect(!reopened.items.flatMap(\.effects).contains { $0.action == "git-init" })
    }
    @Test(arguments: ["repositories", "worktrees"])
    func unregisteredNonemptyWorkspaceIsRejectedWithoutWrites(_ name: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let directory = fixture.root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appending(path: ".user-data")
        try Data("keep me".utf8).write(to: file)
        do { _ = try await fixture.service.candidate(fixture.root); Issue.record("Expected the nonempty directory to be rejected.") }
        catch { #expect((error as? ModuError)?.code == "workspace-not-empty") }
        let opened = await fixture.service.openWorkspace(fixture.root)
        #expect(opened.status == "failed" && opened.items.first?.reasonCode == "workspace-not-empty")
        #expect(opened.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
    }
    @Test(arguments: ["nested", "bare", "corrupt", "worktree"])
    func openingWorkspaceDoesNotInitializeUnsupportedGitLayouts(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        switch kind {
        case "nested": _ = try await fixture.service.git.run(["init"], at: fixture.directory)
        case "bare": _ = try await fixture.service.git.run(["init", "--bare"], at: fixture.root)
        case "corrupt": try FileManager.default.createDirectory(at: fixture.root.appending(path: ".git"), withIntermediateDirectories: false)
        default: _ = try await fixture.service.git.run(["worktree", "add", "-b", "feature", fixture.root.path], at: fixture.directory.appending(path: "source"))
        }
        let opened = await fixture.service.openWorkspace(fixture.root)
        #expect(opened.status == "failed")
        #expect(opened.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
        #expect(!PathSafety.exists(fixture.root.appending(path: ".gitignore")))
    }
    @Test func workspaceAndGroupLifecycle() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let opened = await fixture.service.openWorkspace(fixture.root)
        #expect(opened.status == "success", "\(opened.items)")
        let added = await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root)
        #expect(added.status == "success", "\(added.items)")
        let ignoreFile = fixture.root.appending(path: ".gitignore")
        let ignoreContents = Data("# modu\n/repositories/\n/worktrees/\n/repo/\n".utf8)
        #expect(try Data(contentsOf: ignoreFile) == ignoreContents)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        #expect(try Data(contentsOf: ignoreFile) == ignoreContents)
        let created = await fixture.service.createGroup("feature-test", repositories: ["repo"], at: fixture.root)
        #expect(created.status == "success", "\(created.items) \(created.message ?? "")")
        let record = try await fixture.service.load(fixture.root)
        #expect(record.groups["feature-test"]?.repositories == ["repo"])
        #expect(try await fixture.service.git.registrations(at: fixture.root).count == 2)
        #expect(try await fixture.service.git.registrations(at: record.repositoryURL("repo")).count == 2)
        let preview = try await fixture.service.previewDelete(.member(group: "feature-test", repo: "repo"), at: fixture.root)
        #expect(preview[0].branch == "feature-test")
        let removed = await fixture.service.remove(.member(group: "feature-test", repo: "repo"), at: fixture.root, authorization: preview)
        #expect(removed.status == "success", "\(removed.items)")
        #expect(try await fixture.service.load(fixture.root).groups["feature-test"]?.repositories == [])
        let deleted = await fixture.service.remove(.group("feature-test"), at: fixture.root, execute: true)
        #expect(deleted.status == "success", "\(deleted.items) \(deleted.message ?? "")")
        #expect(try await fixture.service.load(fixture.root).groups.isEmpty)
    }
    @Test func ignoreRulesUseModuSectionAndPreserveExistingContent() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let file = fixture.root.appending(path: ".gitignore")
        let rules = "/repositories/\n/worktrees/\n"
        let cases = [
            ("", "# modu\n" + rules),
            ("# user\nbuild/", "# user\nbuild/\n# modu\n" + rules),
            ("# modu", "# modu\n" + rules),
            ("# modu\n/existing/\n", "# modu\n/existing/\n" + rules),
            ("# modu\n/existing/\n# user\n!repositories/\n!worktrees/\n", "# user\n!repositories/\n!worktrees/\n# modu\n/existing/\n" + rules),
            ("# modu\r\n/existing/\r\n# user\r\nbuild/\r\n", "# user\r\nbuild/\r\n# modu\r\n/existing/\r\n" + rules),
            ("# modu-workflow\nbuild/\n", "# modu-workflow\nbuild/\n# modu\n" + rules)
        ]
        for (original, expected) in cases {
            try Data(original.utf8).write(to: file)
            #expect(try await fixture.service.git.ensureIgnore(["repositories", "worktrees"], at: fixture.root))
            #expect(try Data(contentsOf: file) == Data(expected.utf8))
            #expect(try await fixture.service.git.ignored(["repositories", "worktrees"], contents: Data(contentsOf: file)).isEmpty)
            #expect(try await fixture.service.git.ensureIgnore(["repositories", "worktrees"], at: fixture.root) == false)
            #expect(try Data(contentsOf: file) == Data(expected.utf8))
        }
        let existingRules = Data("# user\n/*/\n".utf8)
        try existingRules.write(to: file)
        #expect(try await fixture.service.git.ensureIgnore(["repositories", "worktrees"], at: fixture.root) == false)
        #expect(try Data(contentsOf: file) == existingRules)
    }
    @Test func lockAndUnmanagedWorktreeBlockDeletion() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = await f.service.openWorkspace(f.root)
        let lease = try f.service.store.lock(f.root)
        #expect(throws: ModuError.self) { try f.service.store.lock(f.root) }
        lease.unlock()
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success")
        let main = f.root.appending(path: "repositories/repo")
        _ = try await f.service.git.run(["worktree", "add", "-b", "outside", f.directory.appending(path: "outside").path], at: main)
        let result = await f.service.remove(.repository("repo"), at: f.root, execute: true)
        #expect(result.reasonCode == "unmanaged-worktree")
        #expect(PathSafety.exists(main))
        #expect(try await f.service.load(f.root).repositories.count == 1)
    }
    @Test func cancellationTerminatesProcessGroup() async throws {
        let runner = CommandRunner()
        let task = Task { try await runner.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect((error as? ModuError)?.code == "cancelled") }
    }
}

struct Fixture {
    let directory: URL
    let root: URL
    let service: WorkspaceService
    let remoteURL = "https://modu-test.invalid/repo.git"
    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "modu-tests-\(UUID().uuidString)")
        root = directory.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = directory.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = directory.appending(path: "gitconfig").path
        environment["GIT_AUTHOR_NAME"] = "Modu Test"; environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Modu Test"; environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        let remote = directory.appending(path: "repo.git")
        try Data("[url \"\(remote.path)\"]\n    insteadOf = \(remoteURL)\n[protocol \"file\"]\n    allow = always\n[init]\n    defaultBranch = main\n".utf8).write(to: directory.appending(path: "gitconfig"))
        let git = Git(runner: CommandRunner(environment: environment))
        let trash = directory.appending(path: "trash")
        service = WorkspaceService(store: .init(support: directory.appending(path: "support")), git: git, trash: { source in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        })
        _ = try await git.run(["init", "-b", "main"], at: source)
        try Data("hello\n".utf8).write(to: source.appending(path: "README"))
        _ = try await git.run(["add", "README"], at: source)
        _ = try await git.run(["commit", "-m", "fixture"], at: source)
        _ = try await git.run(["clone", "--bare", source.path, remote.path], at: directory)
    }
    func commitWorkspace() async throws {
        _ = try await service.git.run(["add", ".gitignore"], at: root)
        if try await service.git.run(["diff", "--cached", "--quiet"], at: root, allowFailure: true).status != 0 {
            _ = try await service.git.run(["commit", "-m", "workspace"], at: root)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

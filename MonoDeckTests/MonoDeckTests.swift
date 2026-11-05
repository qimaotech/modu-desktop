import Foundation
import Testing
@testable import MonoDeckCore

extension WorkspaceService {
    func deleteConfirmed(_ request: DeleteRequest, at root: URL, authorization: [DeletionTarget]? = nil, progress: ProgressHandler = { _ in }) async -> OperationResult {
        if let authorization { return await delete(request, at: root, authorization: authorization, progress: progress) }
        let preview = await delete(request, at: root)
        guard preview.status == .confirmationRequired, let plan = preview.plan else { return preview }
        return await delete(request, at: root, authorization: plan.deletions, progress: progress)
    }
}

struct MonoDeckCoreTests {
    @Test func urlAndStatusParsing() throws {
        for url in ["https://example.test/team/service.git", "ssh://git@example.test/team/service", "git@example.test:team/service.git"] { #expect(try RepositoryIdentity(url).id == "service") }
        for url in ["/tmp/repo", "file:///tmp/repo", "https://token@example.test/team/a", "https://u:p@example.test/a", "ssh://git@example.test/../..", "git@example.test:x/../../"] { #expect(throws: MonoDeckError.self) { try RepositoryIdentity(url) } }
        let status = Data("AD file\0R  new\npath\0old\tpath\0?? untracked\0UU conflict\0".utf8)
        let changes = try Git.parseChanges(status)
        #expect(try Git.countChanges(status) == 4)
        #expect(try Git.countChanges(Data()) == 0)
        for invalid in ["bad\0", "R  new\0"] {
            #expect(throws: MonoDeckError.self) { try Git.countChanges(Data(invalid.utf8)) }
            #expect(throws: MonoDeckError.self) { try Git.parseChanges(Data(invalid.utf8)) }
        }
        #expect(changes.first { $0.path == "file" }?.index == "A")
        #expect(changes.first { $0.path == "file" }?.workingTree == "D")
        #expect(changes.first { $0.path == "new\npath" }?.originalPath == "old\tpath")
        #expect(changes.first { $0.path == "conflict" }?.conflict == true)
    }
    @Test func configurationAndYAMLValidation() throws {
        #expect(throws: (any Error).self) { try WorkspaceDocumentValidation.validateRecordDocument("{\"version\":2,\"version\":2}") }
        #expect(throws: (any Error).self) { try WorkspaceDocumentValidation.validateConfigurationDocument("version: 2\nunknown: true") }
        #expect(throws: (any Error).self) { try WorkspaceService.repositoryURLs(in: "items: [oops") }
        let urls = try WorkspaceService.repositoryURLs(in: "a:\n  - https://example.test/a.git\n  - nested: git@example.test:b\n  - echo https://example.test/c\nhttps://example.test/key: ignored")
        #expect(urls == ["https://example.test/a.git", "git@example.test:b"])
        #expect(try WorkspaceService.repositoryURLs(in: "url: &repo https://example.test/a.git\nagain: *repo").count == 2)
        #expect(throws: (any Error).self) { try WorkspaceService.repositoryURLs(in: "loop: &loop [*loop]") }
        #expect(throws: (any Error).self) { try WorkspaceService.repositoryURLs(in: "unknown: *missing") }
        let aliased = """
        first: &first [https://example.test/a.git, git@example.test:b]
        second: &second [*first, *first]
        third: *second
        """
        #expect(try WorkspaceService.repositoryURLs(in: aliased) == Array(repeating: urls, count: 5).flatMap { $0 })
    }
    @Test(arguments: ["url-aliases", "text-aliases", "deep-aliases"])
    func repositoryYAMLRejectsExcessiveExpansion(_ kind: String) throws {
        let value = kind == "text-aliases" ? "ordinary text" : "https://example.test/repo.git"
        var yaml = "l0: &a0 \(value)\n"
        for index in 1...(kind == "deep-aliases" ? 150 : 18) {
            let previous = "*a\(index - 1)"
            let aliases = kind == "deep-aliases" ? previous : "\(previous), \(previous)"
            yaml += "l\(index): &a\(index) [\(aliases)]\n"
        }
        do {
            _ = try WorkspaceService.repositoryURLs(in: yaml)
            Issue.record("Excessive YAML expansion should fail.")
        } catch {
            let failure = try #require(error as? MonoDeckError)
            #expect(failure.code == "invalid-input")
            #expect(failure.userMessage == .yamlTooComplexToImport)
        }
    }
    @Test(arguments: ["new", "recorded", "missing-metadata"])
    func openingNonGitWorkspaceInitializesGit(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let root = fixture.root
        let notes = root.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: notes)
        switch kind {
        case "recorded": try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(root).path))
        case "missing-metadata":
            #expect(await fixture.service.openWorkspace(root).status == .success)
            try FileManager.default.removeItem(at: root.appending(path: ".git"))
        default: break
        }
        #expect(try await fixture.service.candidate(root) == PathSafety.canonical(root))
        #expect(!PathSafety.exists(root.appending(path: ".git")))
        let opened = await fixture.service.openWorkspace(root)
        #expect(opened.status == .success, "\(opened.items)")
        #expect(opened.items.flatMap(\.effects).contains { $0.action == "git-init" })
        try await fixture.service.git.checkRepository(root, main: true)
        #expect(try await fixture.service.git.oid("HEAD", at: root) != nil)
        #expect(try await fixture.service.git.run(["ls-files"], at: root).text == ".gitignore")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "keep me")
        #expect(try await fixture.service.load(root).repositories.isEmpty)
        let reopened = await fixture.service.openWorkspace(root)
        #expect(reopened.status == .success)
        #expect(!reopened.items.flatMap(\.effects).contains { $0.action == "git-init" })
    }
    @Test(arguments: ["valid", "missing", "invalid", "unsupported-version", "missing-root"])
    func savedWorkspaceCandidateRequiresValidRecordWithoutWrites(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(fixture.root).path))
        let file = fixture.service.store.recordURL(fixture.root)
        switch kind {
        case "missing": try FileManager.default.removeItem(at: file)
        case "invalid": try Data("invalid".utf8).write(to: file)
        case "unsupported-version":
            var record = try fixture.service.store.load(fixture.root)
            record.version = 1
            try JSONEncoder().encode(record).write(to: file)
        case "missing-root": try FileManager.default.removeItem(at: fixture.root)
        default: break
        }
        let before = PathSafety.exists(file) ? try Data(contentsOf: file) : nil
        do {
            let candidate = try await fixture.service.candidate(fixture.root, requireExistingRecord: true)
            #expect(kind == "valid" && candidate == PathSafety.canonical(fixture.root))
        } catch {
            #expect(kind != "valid")
            if kind == "missing" { #expect((error as? MonoDeckError)?.code == "workspace-record-missing") }
            if kind == "invalid" || kind == "unsupported-version" {
                let failure = MonoDeckError.wrap(error)
                #expect(failure.code == "invalid-workspace-record")
                #expect(failure.message.contains(file.path))
            }
        }
        #expect((PathSafety.exists(file) ? try Data(contentsOf: file) : nil) == before)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.root.appending(path: "repositories")))
        #expect(!PathSafety.exists(fixture.root.appending(path: "worktrees")))
        if kind == "missing-root" { #expect(!PathSafety.exists(fixture.root)) }
    }

    @Test(arguments: ["repositories", "worktrees"])
    func unregisteredNonemptyWorkspaceIsRejectedWithoutWrites(_ name: String) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let directory = fixture.root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appending(path: ".user-data")
        try Data("keep me".utf8).write(to: file)
        do { _ = try await fixture.service.candidate(fixture.root); Issue.record("Expected the nonempty directory to be rejected.") }
        catch { #expect((error as? MonoDeckError)?.code == "workspace-not-empty") }
        let opened = await fixture.service.openWorkspace(fixture.root)
        #expect(opened.status == .failed && opened.items.first?.reasonCode == "workspace-not-empty")
        #expect(opened.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
    }
    @Test(arguments: ["nested", "bare", "corrupt", "worktree"])
    func openingWorkspaceDoesNotInitializeUnsupportedGitLayouts(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: kind == "worktree"); defer { fixture.remove() }
        switch kind {
        case "nested": _ = try await fixture.service.git.run(["init"], at: fixture.directory)
        case "bare": _ = try await fixture.service.git.run(["init", "--bare"], at: fixture.root)
        case "corrupt": try FileManager.default.createDirectory(at: fixture.root.appending(path: ".git"), withIntermediateDirectories: false)
        default: _ = try await fixture.service.git.run(["worktree", "add", "-b", "feature", fixture.root.path], at: fixture.directory.appending(path: "source"))
        }
        let opened = await fixture.service.openWorkspace(fixture.root)
        #expect(opened.status == .failed)
        #expect(opened.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
        #expect(!PathSafety.exists(fixture.root.appending(path: ".gitignore")))
    }
    @Test func workspaceAndGroupLifecycle() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let opened = await fixture.service.openWorkspace(fixture.root)
        #expect(opened.status == .success, "\(opened.items)")
        let ignoreFile = fixture.root.appending(path: ".gitignore")
        var ignoreContents = try Data(contentsOf: ignoreFile)
        ignoreContents.append(Data("/repo/\n".utf8))
        let added = await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root)
        #expect(added.status == .success, "\(added.items)")
        #expect(try Data(contentsOf: ignoreFile) == ignoreContents)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        #expect(try Data(contentsOf: ignoreFile) == ignoreContents)
        let created = await fixture.service.createGroup("feature-test", repositoryIDs: ["repo"], at: fixture.root)
        #expect(created.status == .success, "\(created.items) \(created.message ?? "")")
        let record = try await fixture.service.load(fixture.root)
        #expect(record.groups["feature-test"]?.repositoryIDs == ["repo"])
        #expect(try await fixture.service.git.registrations(at: fixture.root).count == 2)
        #expect(try await fixture.service.git.registrations(at: record.repositoryURL("repo")).count == 2)
        let preview = try await fixture.service.previewDelete(.member(groupName: "feature-test", repositoryID: "repo"), at: fixture.root)
        #expect(preview[0].branch == "feature-test")
        #expect(await fixture.service.editGroup("feature-test", repositoryIDs: [], at: fixture.root).status == .confirmationRequired)
        let removed = await fixture.service.delete(.member(groupName: "feature-test", repositoryID: "repo"), at: fixture.root, authorization: preview)
        #expect(removed.status == .success, "\(removed.items)")
        #expect(try await fixture.service.load(fixture.root).groups["feature-test"]?.repositoryIDs == [])
        let deleted = await fixture.service.deleteConfirmed(.group("feature-test"), at: fixture.root)
        #expect(deleted.status == .success, "\(deleted.items) \(deleted.message ?? "")")
        #expect(try await fixture.service.load(fixture.root).groups.isEmpty)
    }
    @Test func newWorkspaceIgnoreProtectsGeneratedFiles() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let ignoredPaths = [
            "app.log", "node_modules/package/index.js", "dist/index.js", ".vscode/settings.json", ".DS_Store",
            "repositories/repo/README", "worktrees/feature/README"
        ]
        let ignored = try await fixture.service.git.run(["-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", "--"] + ignoredPaths + [".vscode/extensions.json", "README.md"], at: fixture.root)
        #expect(ignored.text.components(separatedBy: "\n") == ignoredPaths)
    }
    @Test func ignoreRulesUseMonoDeckSectionAndPreserveExistingContent() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let file = fixture.root.appending(path: ".gitignore")
        let rules = "/repositories/\n/worktrees/\n"
        let cases = [
            ("", "# mono-deck\n" + rules),
            ("# user\nbuild/", "# user\nbuild/\n# mono-deck\n" + rules),
            ("# mono-deck", "# mono-deck\n" + rules),
            ("# mono-deck\n/existing/\n", "# mono-deck\n/existing/\n" + rules),
            ("# mono-deck\n/existing/\n# user\n!repositories/\n!worktrees/\n", "# user\n!repositories/\n!worktrees/\n# mono-deck\n/existing/\n" + rules),
            ("# mono-deck\r\n/existing/\r\n# user\r\nbuild/\r\n", "# user\r\nbuild/\r\n# mono-deck\r\n/existing/\r\n" + rules),
            ("# mono-deck-workflow\nbuild/\n", "# mono-deck-workflow\nbuild/\n# mono-deck\n" + rules)
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
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let lease = try f.service.store.tryLock(f.root)
        #expect(throws: MonoDeckError.self) { try f.service.store.tryLock(f.root) }
        lease.unlock()
        let main = f.root.appending(path: "repositories/repo")
        _ = try await f.service.git.run(["worktree", "add", "-b", "outside", f.directory.appending(path: "outside").path], at: main)
        let result = await f.service.deleteConfirmed(.repository("repo"), at: f.root)
        #expect(result.reasonCode == "unmanaged-worktree")
        #expect(PathSafety.exists(main))
        #expect(try await f.service.load(f.root).repositories.count == 1)
    }
}

struct Fixture: Sendable {
    let directory: URL
    let root: URL
    let service: WorkspaceService
    let remoteURL = "https://mono-deck-test.invalid/repo.git"
    init(createRemote: Bool = true) async throws {
        try self.init(directory: TestEnvironment.temporaryDirectory.appending(path: "mono-deck-tests-\(UUID().uuidString)"))
        do {
            if createRemote { try await restore(.repositorySeed) }
        } catch {
            remove()
            throw error
        }
    }
    init(template: FixtureTemplate) async throws {
        try self.init(directory: TestEnvironment.temporaryDirectory.appending(path: "mono-deck-tests-\(UUID().uuidString)"))
        do { try await restore(template) }
        catch { remove(); throw error }
    }
    func prepareWorkspace() async throws {
        try Task.checkCancellation()
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
              !PathSafety.exists(service.store.recordURL(root)) else {
            throw MonoDeckError("fixture-not-empty", "Workspace preparation requires an empty, unregistered directory.")
        }
        let template = try await FixtureTemplates.shared.fixture(for: .emptyWorkspace)
        defer { if !FixtureTemplates.isSessionScoped { template.remove() } }
        try Task.checkCancellation()
        try copyWorkspace(from: template)
        try Task.checkCancellation()
    }
    private init(directory: URL) throws {
        self.directory = directory
        root = directory.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = directory.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = directory.appending(path: "gitconfig").path
        environment["GIT_AUTHOR_NAME"] = "MonoDeck Test"; environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "MonoDeck Test"; environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
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
    }
    func runCLI(_ arguments: [String], environment: [String: String] = [:]) async throws -> CommandOutput {
        let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
        var runner = service.git.runner
        runner.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] = service.store.support.path
        runner.environment.merge(environment) { _, value in value }
        return try await runner.run(executable.path, arguments, at: directory)
    }

    func prepareGroup(_ name: String, repositoryIDs: [String]) async throws {
        // Deletion tests need real worktrees without repeating the group creation workflow.
        try await prepareEmptyGroup(name)
        var record = try service.store.load(root)
        for repository in repositoryIDs {
            _ = try await service.git.run(["worktree", "add", "--no-track", "-b", name,
                                           record.memberURL(name, repository).path, "origin/main"], at: record.repositoryURL(repository))
        }
        record.groups[name]?.repositoryIDs = repositoryIDs
        try service.store.save(record)
    }
    func prepareEmptyGroup(_ name: String) async throws {
        var record = try service.store.load(root)
        // Empty groups are valid after member removal; prepare that state without creating and deleting a member.
        _ = try await service.git.run(["worktree", "add", "-b", name, record.groupURL(name).path], at: root)
        record.groups[name] = WorktreeGroup()
        try service.store.save(record)
    }
    func commitWorkspace() async throws {
        _ = try await service.git.run(["add", ".gitignore"], at: root)
        if try await service.git.run(["diff", "--cached", "--quiet"], at: root, allowFailure: true).status != 0 {
            _ = try await service.git.run(["commit", "-m", "workspace"], at: root)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    private func restore(_ kind: FixtureTemplate) async throws {
        try Task.checkCancellation()
        let template = try await FixtureTemplates.shared.fixture(for: kind)
        defer { if !FixtureTemplates.isSessionScoped { template.remove() } }
        try Task.checkCancellation()
        if kind != .emptyWorkspace {
            try FileManager.default.removeItem(at: directory.appending(path: "source"))
            for name in ["source", "repo.git"] {
                try FileManager.default.copyItem(at: template.directory.appending(path: name), to: directory.appending(path: name))
            }
        }
        if kind != .repositorySeed { try copyWorkspace(from: template) }
        try Task.checkCancellation()
    }

    private func copyWorkspace(from template: Fixture) throws {
        for file in try FileManager.default.contentsOfDirectory(at: template.root, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: file, to: root.appending(path: file.lastPathComponent))
        }
        var record = try template.service.store.load(template.root)
        record.root = PathSafety.canonical(root).path
        try service.store.save(record)
    }

    fileprivate static func makeTemplate(_ kind: FixtureTemplate) async throws -> Fixture {
        let fixture = try Fixture(directory: TestEnvironment.temporaryDirectory.appending(path: "mono-deck-fixture-template-\(UUID().uuidString)"))
        do {
            let git = fixture.service.git
            if kind != .emptyWorkspace {
                if kind == .singleRepository {
                    try await fixture.restore(.repositorySeed)
                } else {
                    let source = fixture.directory.appending(path: "source")
                    _ = try await git.run(["init", "-b", "main"], at: source)
                    try Data("hello\n".utf8).write(to: source.appending(path: "README"))
                    _ = try await git.run(["add", "README"], at: source)
                    _ = try await git.run(["commit", "-m", "fixture"], at: source)
                    _ = try await git.run(["clone", "--bare", source.path, fixture.directory.appending(path: "repo.git").path], at: fixture.directory)
                }
            }
            if kind != .repositorySeed {
                let opened = await fixture.service.openWorkspace(fixture.root)
                try #require(opened.status == .success, "\(opened.items)")
            }
            if kind == .singleRepository {
                let added = await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root)
                try #require(added.status == .success, "\(added.items)")
            }
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }
}

enum FixtureTemplate: Hashable, Sendable {
    case repositorySeed, emptyWorkspace, singleRepository
}

private actor FixtureTemplates {
    static let shared = FixtureTemplates()
    static let isSessionScoped = ProcessInfo.processInfo.environment["MONO_DECK_TEST_SESSION_DIRECTORY"] != nil
    private var fixtures: [FixtureTemplate: Task<Fixture, Error>] = [:]

    func fixture(for kind: FixtureTemplate) async throws -> Fixture {
        // Xcode runs without the session cleanup provided by task test.
        if !Self.isSessionScoped { return try await Fixture.makeTemplate(kind) }
        if let task = fixtures[kind] { return try await task.value }
        // Publish only a completed template; concurrent callers share its preparation.
        let task = Task { try await Fixture.makeTemplate(kind) }
        fixtures[kind] = task
        return try await task.value
    }
}

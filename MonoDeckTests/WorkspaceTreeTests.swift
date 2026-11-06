import Foundation
import Testing
@testable import MonoDeckCore

struct WorkspaceTreeTests {
    @Test func treeUsesPhysicalHierarchyWhileTheWorkspaceIsLocked() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try await prepare(fixture)
        try await fixture.prepareEmptyGroup("a-empty")
        let unregistered = record.repositoryURL("unregistered")
        try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: unregistered)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let lease = try fixture.service.store.tryLock(fixture.root); defer { lease.unlock() }

        #expect(try await fixture.service.store.locate(explicit: fixture.root.path, cwd: fixture.root) == record.rootURL)
        #expect(try await fixture.service.candidate(fixture.root).path == record.root)
        let tree = try await fixture.service.workspaceTree(fixture.root)

        #expect(tree == WorkspaceTreeNode(.workspace, path: record.root, children: [
            .init(.auxiliaryDirectory, path: "repositories", children: [.init(.mainWorktree, path: "repo")]),
            .init(.auxiliaryDirectory, path: "worktrees", children: [
                .init(.group, path: "a-empty", children: []),
                .init(.group, path: "feature", children: [.init(.linkedWorktree, path: "repo")])
            ])
        ]))
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func treeQueriesOnlyTheWorkspaceRootAndReadsCurrentDirectoryStructure() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        _ = try await prepare(fixture)
        try await fixture.prepareGroup("review", repositoryIDs: ["repo"])
        let trace = fixture.directory.appending(path: "workspace-tree-trace")
        var git = fixture.service.git
        git.runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: git)

        let first = try await service.workspaceTree(fixture.root)

        #expect(first.children?[1].children?.map(\.path) == ["feature", "review"])
        let firstCommands = try String(contentsOf: trace, encoding: .utf8).components(separatedBy: "\n")
        #expect(firstCommands.filter { $0.contains("built-in: git ") }.count == 1)
        #expect(firstCommands.filter { $0.contains("built-in: git rev-parse --show-toplevel") }.count == 1)
        #expect(!firstCommands.contains { $0.contains("remote.origin.url") || $0.contains("worktree list") })

        try await fixture.prepareGroup("later", repositoryIDs: ["repo"])
        try Data().write(to: trace)

        let second = try await service.workspaceTree(fixture.root)

        let groups = try #require(second.children?[1].children)
        #expect(groups.map(\.path) == ["feature", "later", "review"])
        #expect(groups.allSatisfy { $0.children == [.init(.linkedWorktree, path: "repo")] })
        let secondCommands = try String(contentsOf: trace, encoding: .utf8).components(separatedBy: "\n")
        #expect(secondCommands.filter { $0.contains("built-in: git ") }.count == 1)
        #expect(secondCommands.filter { $0.contains("built-in: git rev-parse --show-toplevel") }.count == 1)
        #expect(!secondCommands.contains { $0.contains("remote.origin.url") || $0.contains("worktree list") })
    }

    @Test(arguments: ["repository", "group", "member"], ["missing", "file", "symlink", "missing-git", "wrong-git-type", "git-symlink"])
    func resourcesWithMissingOrUnsafeLayoutsAreFilteredWithoutChangingTheirRecords(_ target: String, _ kind: String) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let resource: URL
        switch target {
        case "repository": resource = record.repositoryURL("repo")
        case "group": resource = record.groupURL("feature")
        default: resource = record.memberURL("feature", "repo")
        }
        let path = kind.contains("git") ? resource.appending(path: ".git") : resource
        let moved = fixture.directory.appending(path: "moved-resource")
        try FileManager.default.moveItem(at: path, to: moved)
        switch kind {
        case "file": try Data().write(to: path)
        case "symlink", "git-symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
        case "wrong-git-type":
            if target == "repository" { try Data().write(to: path) }
            else { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        default: break
        }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))

        let tree = try await fixture.service.workspaceTree(fixture.root)

        let children = try #require(tree.children)
        #expect(children[0].children?.map(\.path) == (target == "repository" ? [] : ["repo"]))
        if target == "group" { #expect(children[1].children?.isEmpty == true) }
        else {
            let group = try #require(children[1].children?.first)
            #expect(group.path == "feature")
            #expect(group.children?.map(\.path) == (target == "member" ? [] : ["repo"]))
        }
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try fixture.service.store.load(fixture.root) == record)
    }

    @Test(arguments: ["wrong-origin", "member-origin", "group-head", "member-head", "foreign-group", "foreign-member", "unregistered-group", "unregistered-member", "invalid-group-pointer", "invalid-member-pointer"])
    func treeShowsRegisteredDirectoryLayoutsWithoutCertifyingGitHealthOrOwnership(_ kind: String) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let repository = record.repositoryURL("repo")
        let member = record.memberURL("feature", "repo")
        switch kind {
        case "wrong-origin": _ = try await fixture.service.git.run(["config", "remote.origin.url", "https://mono-deck-test.invalid/other.git"], at: repository)
        case "member-origin":
            _ = try await fixture.service.git.run(["config", "extensions.worktreeConfig", "true"], at: repository)
            _ = try await fixture.service.git.run(["config", "--worktree", "remote.origin.url", "https://mono-deck-test.invalid/other.git"], at: member)
        case "group-head", "member-head":
            _ = try await fixture.service.git.run(["symbolic-ref", "HEAD", "refs/heads/missing"], at: kind == "group-head" ? record.groupURL("feature") : member)
        case "unregistered-group", "unregistered-member":
            let main = kind == "unregistered-group" ? record.rootURL : repository
            try FileManager.default.removeItem(at: main.appending(path: ".git/worktrees"))
        case "invalid-group-pointer", "invalid-member-pointer":
            let path = kind == "invalid-group-pointer" ? record.groupURL("feature") : member
            try Data("invalid".utf8).write(to: path.appending(path: ".git"))
        default:
            let path = kind == "foreign-group" ? record.groupURL("feature") : member
            let foreign = fixture.directory.appending(path: "source/.git")
            try Data("gitdir: \(foreign.path)\n".utf8).write(to: path.appending(path: ".git"))
        }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))

        let tree = try await fixture.service.workspaceTree(fixture.root)

        let children = try #require(tree.children)
        #expect(children[0].children == [.init(.mainWorktree, path: "repo")])
        #expect(children[1].children == [.init(.group, path: "feature", children: [.init(.linkedWorktree, path: "repo")])])
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try fixture.service.store.load(fixture.root) == record)
    }

    @Test(arguments: ["record", "git"])
    func invalidWorkspaceRootsAreReportedInsteadOfFiltered(_ kind: String) async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        if kind == "record" { try Data("invalid".utf8).write(to: fixture.service.store.recordURL(fixture.root)) }
        else { try FileManager.default.removeItem(at: fixture.root.appending(path: ".git")) }
        do {
            _ = try await fixture.service.workspaceTree(fixture.root)
            Issue.record("Expected an invalid workspace root to be reported.")
        } catch {
            let failure = try #require(error as? MonoDeckError)
            #expect(failure.code != "cancelled")
            if kind == "record" { #expect(failure.code == "invalid-workspace-record") }
        }
    }

    @Test func cancelledTreeQueriesDoNotProduceASuccessfulEmptyTree() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let query = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.workspaceTree(fixture.root)
        }
        do {
            _ = try await query.value
            Issue.record("Expected a cancelled workspace tree query to be reported.")
        } catch { #expect((error as? MonoDeckError)?.code == "cancelled") }
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func localInspectionDoesNotFetchOrRefreshTheGitIndex() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let record = try fixture.service.store.load(fixture.root)
        let path = record.repositoryURL("repo")
        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
        _ = try await fixture.service.git.run(["config", "remote.origin.uploadpack", "/usr/bin/false"], at: path)
        let readme = path.appending(path: "README")
        let attributes = try FileManager.default.attributesOfItem(atPath: readme.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(2)], ofItemAtPath: readme.path)
        let index = path.appending(path: ".git/index")
        let originalIndex = try Data(contentsOf: index)
        let originalRecord = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let trace = fixture.directory.appending(path: "local-inspection-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let lease = try fixture.service.store.tryLock(fixture.root); defer { lease.unlock() }

        let inspection = await service.inspect(fixture.root, scope: .repositories)

        #expect(inspection.status == .success)
        let item = try #require(inspection.items.first { $0.resource == .repository("repo") })
        #expect(item.data?["working-tree"] == "clean" && item.data?["base-error"] != nil)
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(!commands.contains("built-in: git fetch "))
        #expect(try Data(contentsOf: index) == originalIndex)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == originalRecord)
    }

    private func prepare(_ fixture: Fixture) async throws -> WorkspaceRecord {
        var record = try fixture.service.store.load(fixture.root)
        record.repositories[0].displayNameOverride = "Display name"
        try fixture.service.store.save(record)
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        return try fixture.service.store.load(fixture.root)
    }
}

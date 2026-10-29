import Foundation
import Testing
@testable import ModuCore

struct WorkspaceTreeTests {
    @Test func treeUsesPhysicalHierarchyWhileTheWorkspaceIsLocked() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
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

    @Test(arguments: ["missing-repository", "missing-member", "wrong-origin", "foreign-group", "foreign-member", "symlink"])
    func invalidResourcesAreFilteredWithoutChangingTheirRecords(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let repository = record.repositoryURL("repo")
        let member = record.memberURL("feature", "repo")
        switch kind {
        case "missing-repository", "symlink":
            let moved = fixture.directory.appending(path: "moved-repository")
            try FileManager.default.moveItem(at: repository, to: moved)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: moved) }
        case "missing-member": try FileManager.default.removeItem(at: member)
        case "wrong-origin": _ = try await fixture.service.git.run(["config", "remote.origin.url", "https://modu-test.invalid/other.git"], at: repository)
        default:
            let path = kind == "foreign-group" ? record.groupURL("feature") : member
            let foreign = fixture.directory.appending(path: "source/.git")
            try Data("gitdir: \(foreign.path)\n".utf8).write(to: path.appending(path: ".git"))
        }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))

        let tree = try await fixture.service.workspaceTree(fixture.root)

        let children = try #require(tree.children)
        let expectedRepositories = ["missing-repository", "wrong-origin", "symlink"].contains(kind) ? [] : ["repo"]
        #expect(children[0].children?.map(\.path) == expectedRepositories)
        if kind == "foreign-group" { #expect(children[1].children?.isEmpty == true) }
        else {
            let group = try #require(children[1].children?.first)
            #expect(group.path == "feature" && group.children?.isEmpty == true)
        }
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try fixture.service.store.load(fixture.root) == record)
    }

    @Test func treeKeepsDirtyDetachedLockedWorktreesWithoutARemoteBase() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let original = try await fixture.service.workspaceTree(fixture.root)
        let repository = record.repositoryURL("repo")
        let member = record.memberURL("feature", "repo")
        try Data("Local changes".utf8).write(to: repository.appending(path: "README"))
        _ = try await fixture.service.git.run(["checkout", "--detach", "HEAD"], at: member)
        _ = try await fixture.service.git.run(["worktree", "lock", member.path], at: repository)
        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: repository)

        #expect(try await fixture.service.workspaceTree(fixture.root) == original)
    }

    @Test(arguments: ["record", "git"])
    func invalidWorkspaceRootsAreReportedInsteadOfFiltered(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        if kind == "record" { try Data("invalid".utf8).write(to: fixture.service.store.recordURL(fixture.root)) }
        else { try FileManager.default.removeItem(at: fixture.root.appending(path: ".git")) }
        do {
            _ = try await fixture.service.workspaceTree(fixture.root)
            Issue.record("Expected an invalid workspace root to be reported.")
        } catch {
            let failure = try #require(error as? ModuError)
            #expect(failure.code != "cancelled")
            if kind == "record" { #expect(failure.code == "invalid-configuration") }
        }
    }

    @Test func cancelledTreeQueriesDoNotProduceASuccessfulEmptyTree() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let query = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.workspaceTree(fixture.root)
        }
        do {
            _ = try await query.value
            Issue.record("Expected a cancelled workspace tree query to be reported.")
        } catch { #expect((error as? ModuError)?.code == "cancelled") }
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func localInspectionDoesNotFetchOrRefreshTheGitIndex() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
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
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL, name: "Display name"), at: fixture.root).status == .success)
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success)
        return try fixture.service.store.load(fixture.root)
    }
}

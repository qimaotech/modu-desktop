import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct DetailCacheTests {
    @Test(arguments: [Resource.group("a"), Resource.member("a", "repo")])
    func deletionKeepsUnaffectedSelectionVisibleAndRefreshesItsGitState(_ selected: Resource) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let base = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
        for arguments in [["remote", "add", "origin", fixture.remoteURL], ["update-ref", "refs/remotes/origin/main", base], ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]] {
            _ = try await fixture.service.git.run(arguments, at: fixture.root)
        }
        for name in ["a", "b"] {
            #expect(await fixture.service.createGroup(name, repositories: ["repo"], at: fixture.root).status == .success)
        }
        let record = try fixture.service.store.load(fixture.root)
        let path = try PathSafety.child(selected.path, of: fixture.root, allowMissing: false)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "selected change"], at: path)
        try Data("pending".utf8).write(to: path.appending(path: "pending.txt"))
        let probe = fixture.directory.appending(path: "deletion-detail-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MODU_DELETION_DETAIL_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let model = AppModel(defaults: initial.defaults, service: service)
        model.workspace.record = record
        model.workspace.expandedGroups = ["a", "b"]
        model.workspace.selection = selected
        try await waitForDetail(model)
        let head = try #require(model.workspace.detail.summary?.headOID)
        let commitIDs = try #require(model.workspace.detail.commits?.map(\.id))
        #expect(model.workspace.detail.summary?.head == selected.group && commitIDs.count == 1)
        #expect(model.workspace.detail.changes?.map(\.path) == ["pending.txt"])
        let authorization = try await service.previewDelete(.group("b"), at: fixture.root)

        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        if [ -e "$MODU_DELETION_DETAIL_PROBE/completed" ]; then
            : > "$MODU_DELETION_DETAIL_PROBE/started"
            trap 'exit 143' TERM INT
            while [ ! -e "$MODU_DELETION_DETAIL_PROBE/release" ]; do sleep 0.02; done
        fi
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        let repository = selected.repo.map { record.repositoryURL($0) } ?? record.rootURL
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await service.git.run(arguments, at: repository)
        }
        model.management.sheet = .delete
        model.management.run { service, root, progress in
            let outcome = await service.remove(.group("b"), at: root, authorization: authorization, progress: progress)
            // Simulate a local edit before the post-deletion refresh.
            _ = try? await service.git.run(["commit", "--allow-empty", "-m", "after deletion"], at: path)
            try? Data("new".utf8).write(to: path.appending(path: "after.txt"))
            try? Data().write(to: probe.appending(path: "completed"))
            return outcome
        }
        let operation = try #require(model.operation)
        do {
            try await waitForProbe(probe.appending(path: "started"))
            #expect(!model.busy && model.management.sheet == nil && model.presentation.result == nil)
            #expect(model.workspace.record?.groups["b"] == nil)
            #expect(model.workspace.detailLoading)
            #expect(model.workspace.selection == selected)
            #expect(model.workspace.detail.summary?.head == "a" && model.workspace.detail.summary?.headOID == head)
            #expect(model.workspace.detail.commits?.map(\.id) == commitIDs)
            #expect(model.workspace.detail.changes?.map(\.path) == ["pending.txt"])
            try Data().write(to: probe.appending(path: "release"))
            await operation.value
            try await waitForDetail(model)
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.detail.summary?.head == "a")
            #expect(model.workspace.detail.summary?.headOID != head)
            #expect(model.workspace.detail.commits?.first?.subject == "after deletion")
            #expect(model.workspace.detail.changes?.map(\.path) == ["after.txt", "pending.txt"])
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await operation.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func creationSelectsGroupBeforeSlowGitReadsAndPreservesLaterSelection(_ blocksCreatedGroup: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = try #require(initial.workspace.record)
        let probe = fixture.directory.appending(path: "creation-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MODU_CREATION_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let model = AppModel(defaults: initial.defaults, service: service)
        model.workspace.record = record
        model.workspace.selection = .repository("repo")
        try await waitForDetail(model)
        await model.workspace.detailPreloadTask?.value

        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        if [ -e "$MODU_CREATION_PROBE/completed" ]; then
            : > "$MODU_CREATION_PROBE/started"
            trap 'exit 143' TERM INT
            while [ ! -e "$MODU_CREATION_PROBE/release" ]; do sleep 0.02; done
        fi
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        let blockedRepository = blocksCreatedGroup ? record.rootURL : record.repositoryURL("repo")
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await service.git.run(arguments, at: blockedRepository)
        }
        model.management.sheet = .create
        // Checkout also invokes fsmonitor; only block the reads after creation.
        model.management.run({ service, root, progress in
            let outcome = await service.createGroup("feature", repositories: ["repo"], at: root, progress: progress)
            try? Data().write(to: probe.appending(path: "completed"))
            return outcome
        }, select: .group("feature"))
        let operation = try #require(model.operation)
        do {
            try await waitForProbe(probe.appending(path: "started"))
            #expect(!model.busy && model.management.sheet == nil && model.presentation.result == nil)
            #expect(model.workspace.record?.groups["feature"]?.repositories == ["repo"])
            #expect(model.workspace.selection == .group("feature") && model.workspace.expandedGroups.contains("feature"))
            #expect(model.workspace.currentURL == record.groupURL("feature"))
            if blocksCreatedGroup { #expect(model.workspace.detailLoading) }
            else { #expect(!model.workspace.detailLoading && model.workspace.detail.summary?.head == "feature") }

            model.workspace.selection = .repository("repo")
            try Data().write(to: probe.appending(path: "release"))
            await operation.value
            #expect(model.workspace.selection == .repository("repo"))
            try await waitForDetail(model)
            await model.workspace.detailPreloadTask?.value
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await operation.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test func cachedDetailsAppearImmediatelyAndRefreshLocalChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let repository = Resource.repository("repo")
        let path = try #require(model.workspace.record?.repositoryURL("repo"))

        model.workspace.selection = repository
        #expect(model.workspace.detailLoading && model.workspace.detail.summary == nil)
        try await waitForDetail(model)
        let head = try #require(model.workspace.detail.summary?.headOID)
        #expect(model.workspace.detail.changes?.isEmpty == true)
        #expect(model.workspace.detail.commits?.isEmpty == true)

        model.workspace.selection = nil
        #expect(model.workspace.currentURL == model.workspace.record?.rootURL)
        #expect(model.workspace.detail.summary == nil && !model.workspace.detailLoading)
        try Data("changed".utf8).write(to: path.appending(path: "new.txt"))
        model.workspace.selection = repository
        #expect(model.workspace.detailLoading)
        #expect(model.workspace.detail.summary?.headOID == head)
        #expect(model.workspace.detail.changes?.isEmpty == true)
        #expect(model.workspace.detail.commits?.isEmpty == true)
        try await waitForDetail(model)
        #expect(model.workspace.detail.changes?.map(\.path) == ["new.txt"])

        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
        model.workspace.refreshDetail()
        #expect(model.workspace.detail.changes?.map(\.path) == ["new.txt"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.base == "origin/main" && model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.detail.commits?.isEmpty == true && model.workspace.detail.commitsError == nil)
        #expect(model.workspace.detail.changes?.map(\.path) == ["new.txt"])

        try FileManager.default.removeItem(at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary == nil && model.workspace.detail.summaryError != nil)
        #expect(model.workspace.detail.changes == nil && model.workspace.detail.changesError != nil)
        #expect(model.workspace.states[repository.id]?.available == false)
        #expect(model.workspace.states[repository.id]?.dirty == nil)
    }

    @Test func reloadPreloadsSeparateSnapshotsForRepositoriesGroupsAndMembers() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        let record = try #require(model.workspace.record)
        try Data("main".utf8).write(to: record.repositoryURL("repo").appending(path: "main.txt"))
        try Data("group".utf8).write(to: record.groupURL("feature").appending(path: "group.txt"))
        try Data("member".utf8).write(to: record.memberURL("feature", "repo").appending(path: "member.txt"))

        await model.workspace.reload()
        await model.workspace.detailPreloadTask?.value
        #expect(model.workspace.selection == nil && model.workspace.detail.summary == nil && !model.workspace.detailLoading)
        model.workspace.selection = .repository("repo")
        #expect(model.workspace.detail.changes?.map(\.path) == ["main.txt"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.changes?.map(\.path) == ["main.txt"])
        model.workspace.selection = .group("feature")
        #expect(model.workspace.detail.changes?.map(\.path) == ["group.txt"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.head == "feature")
        #expect(model.workspace.detail.summary?.hasRemotes == false)
        #expect(model.workspace.detail.summary?.base == nil && model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.detail.changes?.map(\.path) == ["group.txt"])
        #expect(model.workspace.detail.commits?.isEmpty == true && model.workspace.detail.commitsError == nil)
        #expect(model.workspace.states[Resource.group("feature").id]?.dirty == true)
        model.workspace.selection = .member("feature", "repo")
        #expect(model.workspace.detail.changes?.map(\.path) == ["member.txt"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.head == "feature")
        #expect(model.workspace.detail.changes?.map(\.path) == ["member.txt"])

        model.workspace.selection = .repository("repo")
        #expect(model.workspace.detail.changes?.map(\.path) == ["main.txt"])
        model.workspace.selection = nil
        #expect(model.workspace.detail.changes == nil && !model.workspace.detailLoading)
        model.workspace.selection = .member("feature", "repo")
        #expect(model.workspace.detail.changes?.map(\.path) == ["member.txt"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.head == "feature")
        #expect(model.workspace.detail.changes?.map(\.path) == ["member.txt"])

        model.workspace.selection = .group("feature")
        #expect(model.workspace.detail.changes?.map(\.path) == ["group.txt"])
        try await waitForDetail(model)
        await model.workspace.detailPreloadTask?.value
        try FileManager.default.removeItem(at: record.groupURL("feature"))
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary == nil && model.workspace.detail.summaryError != nil)
        #expect(model.workspace.detail.changes == nil && model.workspace.detail.changesError != nil)
        #expect(model.workspace.detail.commits == nil && model.workspace.detail.commitsError != nil)
        #expect(model.workspace.states[Resource.group("feature").id]?.available == false)
    }

    @Test func groupDetailsRefreshWhenRemotesAreAddedAndRemoved() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture, repository: false)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.prepareEmptyGroup("feature")
        model.workspace.record = try fixture.service.store.load(fixture.root)
        let path = try #require(model.workspace.record?.groupURL("feature"))
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "group change"], at: path)
        try Data("group".utf8).write(to: path.appending(path: "group.txt"))
        model.workspace.selection = .group("feature")
        try await waitForDetail(model)
        let head = try #require(model.workspace.detail.summary?.headOID)
        #expect(model.workspace.detail.summary?.hasRemotes == false)
        #expect(model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.detail.commits?.isEmpty == true && model.workspace.detail.commitsError == nil)

        _ = try await fixture.service.git.run(["init", "--bare", "--initial-branch=main", fixture.directory.appending(path: "repo.git").path], at: fixture.directory)
        _ = try await fixture.service.git.run(["remote", "add", "origin", fixture.remoteURL], at: fixture.root)
        _ = try await fixture.service.git.run(["push", "-u", "origin", "HEAD"], at: fixture.root)
        #expect(try await fixture.service.git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true).status == 1)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.base == "origin/main")
        #expect(model.workspace.detail.commits?.map(\.subject) == ["group change"])

        _ = try await fixture.service.git.run(["remote", "remove", "origin"], at: fixture.root)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.hasRemotes == false && model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.detail.summary?.base == nil)
        #expect(model.workspace.detail.commits?.isEmpty == true && model.workspace.detail.commitsError == nil && !model.workspace.detail.canLoadMore)
        #expect(model.workspace.detail.summary?.head == "feature" && model.workspace.detail.summary?.headOID == head)
        #expect(model.workspace.detail.changes?.map(\.path) == ["group.txt"])
    }

    @Test func commitReadFailureAlertsOnlyForTheCurrentSelection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = try #require(model.workspace.record?.repositoryURL("repo"))
        _ = try await fixture.service.git.run(["config", "log.date", "invalid-date-format"], at: path)

        model.workspace.refreshDetail()
        await model.workspace.detailPreloadTask?.value
        #expect(model.presentation.message == nil)

        model.workspace.selection = .repository("repo")
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.baseOID != nil && model.workspace.detail.changesError == nil)
        #expect(model.workspace.detail.commitsError != nil)
        #expect(model.presentation.messageTitle == model.text.string(.uiCanTReadCommits))
        #expect(model.presentation.message?.contains("invalid-date-format") == true)
        #expect(model.presentation.messageHost == .main)

        model.presentation.message = nil
        model.workspace.refreshDetail()
        let cancelled = try #require(model.workspace.details.detailTask)
        model.workspace.selection = nil
        await cancelled.value
        await model.workspace.detailPreloadTask?.value
        #expect(cancelled.isCancelled && model.presentation.message == nil)
    }

    @Test func paginationSurvivesSelectionButNotNewHeadsOrWorkspaces() async throws {
        let resource = Resource.repository("repo")
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = try PathSafety.child(resource.path, of: fixture.root, allowMissing: false)
        for index in 0..<31 {
            _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "change \(index)"], at: path)
        }
        model.workspace.selection = resource
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.base == "origin/main")
        #expect(model.workspace.detail.commits?.count == 30 && model.workspace.detail.canLoadMore)
        _ = try await fixture.service.git.run(["config", "log.date", "invalid-date-format"], at: path)
        model.workspace.loadMore()
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.count == 30 && model.workspace.detail.canLoadMore)
        #expect(model.presentation.messageTitle == model.text.string(.uiCanTReadCommits))
        #expect(model.presentation.message?.contains("invalid-date-format") == true)
        model.presentation.message = nil
        _ = try await fixture.service.git.run(["config", "--unset", "log.date"], at: path)
        model.workspace.loadMore()
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.count == 31 && !model.workspace.detail.canLoadMore)
        model.workspace.selection = nil
        model.workspace.selection = resource
        #expect(model.workspace.detail.commits?.count == 31 && !model.workspace.detail.canLoadMore)
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.count == 31 && !model.workspace.detail.canLoadMore)

        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "new head"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.count == 30 && model.workspace.detail.canLoadMore)
        #expect(model.workspace.detail.commits?.first?.subject == "new head")

        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: next).status == .success)
        model.workspace.refreshDetail()
        try await model.switchTo(next)
        #expect(model.workspace.selection == nil && model.workspace.detail.summary == nil)
        model.workspace.selection = .repository("repo")
        #expect(model.workspace.detail.commits == nil || model.workspace.detail.commits?.isEmpty == true)
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.isEmpty == true)
        #expect(model.workspace.detail.summary?.head == "main")
    }

    @Test func selectionAndWorkspaceSwitchCancelPreloading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }

        model.workspace.refreshDetail()
        let initialPreload = try #require(model.workspace.detailPreloadTask)
        model.workspace.selection = .repository("repo")
        #expect(initialPreload.isCancelled)
        #expect(model.workspace.detailPreloadTask == nil && model.workspace.detailLoading)
        await initialPreload.value
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.head == "main")

        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: next).status == .success)
        try Data("next".utf8).write(to: next.appending(path: "repositories/repo/next.txt"))
        try await model.switchTo(next)
        await model.workspace.detailPreloadTask?.value
        #expect(model.workspace.selection == nil)
        model.workspace.selection = .repository("repo")
        #expect(model.workspace.detail.changes?.map(\.path) == ["next.txt"])
        try await waitForDetail(model)

        let switching = AppModel(defaults: model.defaults, service: fixture.service)
        switching.workspace.record = try fixture.service.store.load(fixture.root)
        switching.workspace.refreshDetail()
        let stalePreload = try #require(switching.workspace.detailPreloadTask)
        try await switching.switchTo(next)
        #expect(stalePreload.isCancelled)
        await stalePreload.value
        await switching.workspace.detailPreloadTask?.value
        switching.workspace.selection = .repository("repo")
        #expect(switching.workspace.detail.changes?.map(\.path) == ["next.txt"])
        try await waitForDetail(switching)
    }

    private func makeModel(_ fixture: Fixture, repository: Bool = true) async throws -> AppModel {
        let skill = try #require(Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "modu-workflow"))
        #expect(await fixture.service.openWorkspace(fixture.root, skill: skill).status == .success)
        if repository { #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success) }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        return model
    }

    private func waitForDetail(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.workspace.detailLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!model.workspace.detailLoading, "Repository detail did not finish loading.")
    }

    private func waitForProbe(_ path: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(path), "Background inspection did not reach the blocked repository.")
    }
}

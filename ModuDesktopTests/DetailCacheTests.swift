import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct DetailCacheTests {
    @Test(arguments: [Resource.group("a"), Resource.member("a", "repo"), Resource.member("b", "repo")])
    func deletionKeepsUnaffectedSelectionVisibleAndRefreshesItsGitState(_ selected: Resource) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.commitWorkspace()
        let base = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
        for arguments in [["remote", "add", "origin", fixture.remoteURL], ["update-ref", "refs/remotes/origin/main", base], ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]] {
            _ = try await fixture.service.git.run(arguments, at: fixture.root)
        }
        for name in ["a", "b"] {
            #expect(await fixture.service.createGroup(name, repositories: ["repo"], at: fixture.root).status == "success")
        }
        let record = try await fixture.service.load(fixture.root)
        let path = try PathSafety.child(selected.path, of: fixture.root, allowMissing: false)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "selected change"], at: path)
        try Data("pending".utf8).write(to: path.appending(path: "pending.txt"))
        let probe = fixture.directory.appending(path: "deletion-detail-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MODU_DELETION_DETAIL_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let model = AppModel(defaults: initial.defaults, service: service)
        model.workspace = record
        model.expandedGroups = ["a", "b"]
        model.selection = selected
        try await waitForDetail(model)
        await model.detailPreloadTask?.value
        let head = try #require(model.detail.summary?.headOID)
        let commitIDs = try #require(model.detail.commits?.map(\.id))
        #expect(model.detail.summary?.head == selected.group && commitIDs.count == 1)
        #expect(model.detail.changes?.map(\.path) == ["pending.txt"])
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
        model.sheet = .delete
        model.run { service, root, progress in
            let outcome = await service.remove(.group("b"), at: root, authorization: authorization, progress: progress)
            if selected.group == "a" {
                // Simulate a local edit before the post-deletion refresh.
                _ = try? await service.git.run(["commit", "--allow-empty", "-m", "after deletion"], at: path)
                try? Data("new".utf8).write(to: path.appending(path: "after.txt"))
            }
            try? Data().write(to: probe.appending(path: "completed"))
            return outcome
        }
        let operation = try #require(model.operation)
        do {
            try await waitForProbe(probe.appending(path: "started"))
            #expect(!model.busy && model.sheet == nil && model.result == nil)
            #expect(model.workspace?.groups["b"] == nil)
            if selected.group == "a" {
                #expect(model.detailLoading)
                #expect(model.selection == selected)
                #expect(model.detail.summary?.head == "a" && model.detail.summary?.headOID == head)
                #expect(model.detail.commits?.map(\.id) == commitIDs)
                #expect(model.detail.changes?.map(\.path) == ["pending.txt"])
                #expect(RepositoryDetailView(model: model).showsChanges && RepositoryDetailView(model: model).showsCommits)
            } else {
                #expect(model.selection == nil && model.currentURL == record.rootURL && !model.detailLoading)
                #expect(model.detail.summary == nil && model.detail.changes == nil && model.detail.commits == nil)
            }
            try Data().write(to: probe.appending(path: "release"))
            await operation.value
            try await waitForDetail(model)
            await model.detailPreloadTask?.value
            if selected.group == "a" {
                #expect(model.detail.summary?.head == "a")
                #expect(model.detail.summary?.headOID != head)
                #expect(model.detail.commits?.first?.subject == "after deletion")
                #expect(model.detail.changes?.map(\.path) == ["after.txt", "pending.txt"])
            } else {
                #expect(model.selection == nil && model.currentURL == record.rootURL)
                #expect(model.detail.summary == nil && model.detail.commits == nil && model.detail.changes == nil)
            }
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await operation.value
            await model.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func creationSelectsGroupBeforeSlowGitReadsAndPreservesLaterSelection(_ blocksCreatedGroup: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.commitWorkspace()
        let record = try #require(initial.workspace)
        let probe = fixture.directory.appending(path: "creation-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MODU_CREATION_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let model = AppModel(defaults: initial.defaults, service: service)
        model.workspace = record
        model.selection = .repository("repo")
        try await waitForDetail(model)
        await model.detailPreloadTask?.value

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
        model.sheet = .create
        // Checkout also invokes fsmonitor; only block the reads after creation.
        model.run({ service, root, progress in
            let outcome = await service.createGroup("feature", repositories: ["repo"], at: root, progress: progress)
            try? Data().write(to: probe.appending(path: "completed"))
            return outcome
        }, select: .group("feature"))
        let operation = try #require(model.operation)
        do {
            try await waitForProbe(probe.appending(path: "started"))
            #expect(!model.busy && model.sheet == nil && model.result == nil)
            #expect(model.workspace?.groups["feature"]?.repositories == ["repo"])
            #expect(model.selection == .group("feature") && model.expandedGroups.contains("feature"))
            #expect(model.currentURL == record.groupURL("feature"))
            #expect(!RepositoryDetailView(model: model).showsChanges)
            #expect(!RepositoryDetailView(model: model).showsCommits)
            if blocksCreatedGroup { #expect(model.detailLoading) }
            else { #expect(!model.detailLoading && model.detail.summary?.head == "feature") }

            model.selection = .repository("repo")
            try Data().write(to: probe.appending(path: "release"))
            await operation.value
            #expect(model.selection == .repository("repo"))
            try await waitForDetail(model)
            await model.detailPreloadTask?.value
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await operation.value
            await model.detailPreloadTask?.value
            throw error
        }
    }

    @Test func cachedDetailsAppearImmediatelyAndRefreshLocalChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let repository = Resource.repository("repo")
        let path = try #require(model.workspace?.repositoryURL("repo"))

        model.selection = repository
        #expect(model.detailLoading && model.detail.summary == nil)
        try await waitForDetail(model)
        let head = try #require(model.detail.summary?.headOID)
        #expect(model.detail.changes?.isEmpty == true)
        #expect(model.detail.commits?.isEmpty == true)

        model.selection = nil
        #expect(model.currentURL == model.workspace?.rootURL)
        #expect(model.detail.summary == nil && !model.detailLoading)
        try Data("changed".utf8).write(to: path.appending(path: "new.txt"))
        model.selection = repository
        #expect(model.detailLoading)
        #expect(model.detail.summary?.headOID == head)
        #expect(model.detail.changes?.isEmpty == true)
        #expect(model.detail.commits?.isEmpty == true)
        try await waitForDetail(model)
        #expect(model.detail.changes?.map(\.path) == ["new.txt"])

        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
        model.refreshDetail()
        #expect(model.detail.changes?.map(\.path) == ["new.txt"])
        try await waitForDetail(model)
        #expect(model.detail.summary != nil && model.detail.summary?.baseOID == nil)
        #expect(model.detail.commits == nil && model.detail.commitsError != nil)
        #expect(model.detail.changes?.map(\.path) == ["new.txt"])

        try FileManager.default.removeItem(at: path)
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.summary == nil && model.detail.summaryError != nil)
        #expect(model.detail.changes == nil && model.detail.changesError != nil)
        #expect(model.states[repository.id]?.available == false)
        #expect(model.states[repository.id]?.dirty == nil)
    }

    @Test(arguments: [Resource.repository("repo"), Resource.group("feature"), Resource.member("feature", "repo")])
    func activationPublishesToolsAndKeepsSelectionWhileBackgroundInspectionWaits(_ selected: Resource) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        var record = try #require(initial.workspace)
        let other = Repository(url: "https://modu-test.invalid/other.git")
        try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL(other.id))
        _ = try await fixture.service.git.run(["config", "remote.origin.url", other.url], at: record.repositoryURL(other.id))
        record.repositories.append(other)
        try fixture.service.store.save(record)
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        record = try await fixture.service.load(fixture.root)

        let probe = fixture.directory.appending(path: "detail-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MODU_DETAIL_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? probe.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: initial.defaults, service: service, toolService: tools)
        model.workspace = record
        model.selection = selected
        try await waitForDetail(model)
        await model.detailPreloadTask?.value
        #expect(model.detail.changes?.isEmpty == true)

        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_DETAIL_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_DETAIL_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await service.git.run(arguments, at: record.repositoryURL(other.id))
        }
        let selectedPath = try PathSafety.child(selected.path, of: record.rootURL, allowMissing: false)
        try Data("changed".utf8).write(to: selectedPath.appending(path: "new.txt"))
        #expect(model.tools.isEmpty)
        let reload = Task { await model.activate() }
        do {
            try await waitForProbe(probe.appending(path: "started"))
            #expect(model.tools.map(\.id) == ["codex"])
            #expect(!model.detailLoading)
            #expect(model.detail.changes?.map(\.path) == ["new.txt"])
            #expect(model.states[selected.id]?.dirty == true)

            let next = selected.kind == "member" ? Resource.repository("repo") : Resource.member("feature", "repo")
            let nextPath = try PathSafety.child(next.path, of: record.rootURL, allowMissing: false)
            try Data("next".utf8).write(to: nextPath.appending(path: "next.txt"))
            model.selection = next
            try await waitForDetail(model)
            #expect(model.detail.changes?.map(\.path) == ["next.txt"])
            #expect(model.states[next.id]?.dirty == true)

            try Data().write(to: probe.appending(path: "release"))
            await reload.value
            await model.detailPreloadTask?.value
            #expect(model.selection == next)
            #expect(model.detail.changes?.map(\.path) == ["next.txt"])
            #expect(model.states[next.id]?.dirty == true)
            #expect(model.states[Resource.repository(other.id).id]?.available == true)
            #expect(model.states[Resource.repository(other.id).id]?.dirty == false)
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await reload.value
            await model.detailPreloadTask?.value
            throw error
        }
    }

    @Test func mainGroupAndMemberWorktreesHaveSeparateSnapshots() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        model.workspace = try await fixture.service.load(fixture.root)
        let record = try #require(model.workspace)
        try Data("main".utf8).write(to: record.repositoryURL("repo").appending(path: "main.txt"))
        try Data("group".utf8).write(to: record.groupURL("feature").appending(path: "group.txt"))
        try Data("member".utf8).write(to: record.memberURL("feature", "repo").appending(path: "member.txt"))

        model.selection = .repository("repo")
        try await waitForDetail(model)
        #expect(model.detail.changes?.map(\.path) == ["main.txt"])
        model.selection = .group("feature")
        try await waitForDetail(model)
        #expect(model.detail.summary?.head == "feature")
        #expect(model.detail.summary?.hasRemotes == false)
        #expect(model.detail.summary?.base == nil && model.detail.summary?.baseError == nil)
        #expect(model.detail.changes?.map(\.path) == ["group.txt"])
        #expect(model.detail.commits?.isEmpty == true && model.detail.commitsError == nil)
        #expect(model.states[Resource.group("feature").id]?.dirty == true)
        model.selection = .member("feature", "repo")
        #expect(model.detail.changes == nil || model.detail.changes?.map(\.path) == ["member.txt"])
        try await waitForDetail(model)
        #expect(model.detail.summary?.head == "feature")
        #expect(model.detail.changes?.map(\.path) == ["member.txt"])

        model.selection = .repository("repo")
        #expect(model.detail.changes?.map(\.path) == ["main.txt"])
        model.selection = nil
        #expect(model.detail.changes == nil && !model.detailLoading)
        model.selection = .member("feature", "repo")
        #expect(model.detail.changes?.map(\.path) == ["member.txt"])
        try await waitForDetail(model)
        #expect(model.detail.summary?.head == "feature")
        #expect(model.detail.changes?.map(\.path) == ["member.txt"])

        model.selection = .group("feature")
        #expect(model.detail.changes?.map(\.path) == ["group.txt"])
        try await waitForDetail(model)
        await model.detailPreloadTask?.value
        try FileManager.default.removeItem(at: record.groupURL("feature"))
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.summary == nil && model.detail.summaryError != nil)
        #expect(model.detail.changes == nil && model.detail.changesError != nil)
        #expect(model.detail.commits == nil && model.detail.commitsError != nil)
        #expect(model.states[Resource.group("feature").id]?.available == false)
    }

    @Test func groupDetailsRefreshWhenRemotesAreAddedAndRemoved() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.commitWorkspace()
        let base = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        model.workspace = try await fixture.service.load(fixture.root)
        let path = try #require(model.workspace?.groupURL("feature"))
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "group change"], at: path)
        try Data("group".utf8).write(to: path.appending(path: "group.txt"))
        model.selection = .group("feature")
        try await waitForDetail(model)
        let head = try #require(model.detail.summary?.headOID)
        #expect(model.detail.summary?.hasRemotes == false)
        #expect(model.detail.summary?.baseError == nil)
        #expect(model.detail.commits?.isEmpty == true && model.detail.commitsError == nil)

        _ = try await fixture.service.git.run(["remote", "add", "origin", fixture.remoteURL], at: fixture.root)
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.summary?.hasRemotes == true && model.detail.summary?.baseError != nil)
        #expect(model.detail.commits == nil && model.detail.commitsError != nil)

        _ = try await fixture.service.git.run(["update-ref", "refs/remotes/origin/main", base], at: fixture.root)
        _ = try await fixture.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: fixture.root)
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.summary?.base == "origin/main")
        #expect(model.detail.commits?.map(\.subject) == ["group change"])

        _ = try await fixture.service.git.run(["remote", "remove", "origin"], at: fixture.root)
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.summary?.hasRemotes == false && model.detail.summary?.baseError == nil)
        #expect(model.detail.summary?.base == nil)
        #expect(model.detail.commits?.isEmpty == true && model.detail.commitsError == nil && !model.detail.canLoadMore)
        #expect(model.detail.summary?.head == "feature" && model.detail.summary?.headOID == head)
        #expect(model.detail.changes?.map(\.path) == ["group.txt"])
    }

    @Test(arguments: [Resource.repository("repo"), Resource.group("feature")])
    func paginationSurvivesSelectionButNotNewHeadsOrWorkspaces(_ resource: Resource) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        if resource.kind == "group" {
            try await fixture.commitWorkspace()
            let base = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
            _ = try await fixture.service.git.run(["remote", "add", "origin", fixture.remoteURL], at: fixture.root)
            _ = try await fixture.service.git.run(["update-ref", "refs/remotes/origin/main", base], at: fixture.root)
            _ = try await fixture.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: fixture.root)
            #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
            model.workspace = try await fixture.service.load(fixture.root)
        }
        let path = try PathSafety.child(resource.path, of: fixture.root, allowMissing: false)
        for index in 0..<31 {
            _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "change \(index)"], at: path)
        }
        model.selection = resource
        try await waitForDetail(model)
        #expect(model.detail.summary?.base == "origin/main")
        #expect(model.detail.commits?.count == 30 && model.detail.canLoadMore)
        model.loadMore()
        try await waitForDetail(model)
        #expect(model.detail.commits?.count == 31 && !model.detail.canLoadMore)
        model.selection = nil
        model.selection = resource
        #expect(model.detail.commits?.count == 31 && !model.detail.canLoadMore)
        try await waitForDetail(model)
        #expect(model.detail.commits?.count == 31 && !model.detail.canLoadMore)

        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "new head"], at: path)
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.commits?.count == 30 && model.detail.canLoadMore)
        #expect(model.detail.commits?.first?.subject == "new head")

        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: next).status == "success")
        model.refreshDetail()
        try await model.switchTo(next)
        #expect(model.selection == nil && model.detail.summary == nil)
        model.selection = .repository("repo")
        #expect(model.detail.commits == nil || model.detail.commits?.isEmpty == true)
        try await waitForDetail(model)
        #expect(model.detail.commits?.isEmpty == true)
        #expect(model.detail.summary?.head == "main")
    }

    @Test func reloadPreloadsRepositoriesGroupsAndMembersWithoutSelectingThem() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        let record = try await fixture.service.load(fixture.root)
        try Data("main".utf8).write(to: record.repositoryURL("repo").appending(path: "main.txt"))
        try Data("group".utf8).write(to: record.groupURL("feature").appending(path: "group.txt"))
        try Data("member".utf8).write(to: record.memberURL("feature", "repo").appending(path: "member.txt"))

        await model.reload()
        await model.detailPreloadTask?.value
        #expect(model.selection == nil && model.detail.summary == nil && !model.detailLoading)
        model.selection = .repository("repo")
        #expect(model.detail.summary?.head == "main")
        #expect(model.detail.changes?.map(\.path) == ["main.txt"])
        #expect(model.detail.commits?.isEmpty == true)
        model.selection = .group("feature")
        #expect(model.detail.summary?.head == "feature")
        #expect(model.detail.changes?.map(\.path) == ["group.txt"])
        #expect(model.detail.commits?.isEmpty == true && model.detail.commitsError == nil)
        #expect(model.states[Resource.group("feature").id]?.dirty == true)
        model.selection = .member("feature", "repo")
        #expect(model.detail.summary?.head == "feature")
        #expect(model.detail.changes?.map(\.path) == ["member.txt"])
        #expect(model.detail.commits?.isEmpty == true)
        try await waitForDetail(model)
    }

    @Test func selectionAndWorkspaceSwitchCancelPreloading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }

        model.refreshDetail()
        let initialPreload = try #require(model.detailPreloadTask)
        model.selection = .repository("repo")
        #expect(initialPreload.isCancelled)
        #expect(model.detailPreloadTask == nil && model.detailLoading)
        await initialPreload.value
        try await waitForDetail(model)
        #expect(model.detail.summary?.head == "main")

        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: next).status == "success")
        try Data("next".utf8).write(to: next.appending(path: "repositories/repo/next.txt"))
        try await model.switchTo(next)
        await model.detailPreloadTask?.value
        #expect(model.selection == nil)
        model.selection = .repository("repo")
        #expect(model.detail.changes?.map(\.path) == ["next.txt"])
        try await waitForDetail(model)

        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let switching = AppModel(defaults: model.defaults, service: fixture.service)
        switching.workspace = try await fixture.service.load(fixture.root)
        switching.refreshDetail()
        let stalePreload = try #require(switching.detailPreloadTask)
        try await switching.switchTo(next)
        #expect(stalePreload.isCancelled)
        await stalePreload.value
        await switching.detailPreloadTask?.value
        switching.selection = .repository("repo")
        #expect(switching.detail.changes?.map(\.path) == ["next.txt"])
        try await waitForDetail(switching)
    }

    private func makeModel(_ fixture: Fixture) async throws -> AppModel {
        let skill = try #require(Bundle.main.url(forResource: "SKILL", withExtension: "md"))
        #expect(await fixture.service.openWorkspace(fixture.root, skill: skill).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        return model
    }

    private func waitForDetail(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.detailLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!model.detailLoading, "Repository detail did not finish loading.")
    }

    private func waitForProbe(_ path: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(path), "Background inspection did not reach the blocked repository.")
    }
}

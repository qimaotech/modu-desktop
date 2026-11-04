import Foundation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct DetailCacheTests {
    @Test(arguments: [false, true])
    func appSubmoduleFilteringPreservesCLIAndSafetyChecks(_ changesHead: Bool) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = try #require(model.workspace.record)
        let resource = Resource.repository("repo"), path = record.repositoryURL("repo")
        let submodule = path.appending(path: "submodule")
        _ = try await fixture.service.git.run(["submodule", "add", fixture.remoteURL, "submodule"], at: path)
        _ = try await fixture.service.git.run(["commit", "-m", "add submodule"], at: path)
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        if changesHead {
            _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "submodule change"], at: submodule)
            _ = try await fixture.service.git.run(["add", "--", "submodule"], at: path)
        } else {
            try Data("changed".utf8).write(to: submodule.appending(path: "README"))
            _ = try await fixture.service.git.run(["add", "README"], at: submodule)
            try Data("untracked".utf8).write(to: submodule.appending(path: "new.txt"))
        }

        do {
            model.workspace.setVisibleResources([resource], in: record.root)
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.state(for: resource)?.dirty == false)
            model.workspace.selection = resource
            try await waitForDetail(model)
            #expect(model.workspace.detail.changes?.isEmpty == true && model.workspace.state(for: resource)?.dirty == false)
            #expect(model.workspace.detail.summary?.headOID == head)
            #expect(model.workspace.detail.commits?.map(\.subject) == ["add submodule"])

            let inspection = await fixture.service.inspect(fixture.root)
            let inspected = try #require(inspection.items.first { $0.resource == resource })
            #expect(inspected.status == .success && inspected.data?["working-tree"] == "dirty")
            let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
            var runner = fixture.service.git.runner
            runner.environment["MONO_DECK_TEST_SUPPORT_DIRECTORY"] = fixture.service.store.support.path
            let output = try await runner.run(executable.path, ["repo", "list", "--json", "--workspace", fixture.root.path], at: fixture.directory)
            let listed = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
            #expect(output.status == 0 && listed.items.first { $0.resource == resource }?.data?["working-tree"] == "dirty")
            let preview = try await fixture.service.previewDelete(.repository("repo"), at: fixture.root)
            #expect(preview.first { $0.resource == resource }?.dirty == true)
            let update = await fixture.service.updateRepositories(at: fixture.root)
            let skipped = try #require(update.items.first { $0.resource == resource })
            #expect(skipped.status == .skipped && skipped.reasonCode == "working-tree-dirty" && skipped.effects.isEmpty)

            var modules = try Data(contentsOf: path.appending(path: ".gitmodules"))
            modules.append(Data("\n# parent configuration change\n".utf8))
            try modules.write(to: path.appending(path: ".gitmodules"))
            try Data("visible".utf8).write(to: path.appending(path: "visible.txt"))
            model.workspace.refreshDetail()
            try await waitForDetail(model)
            #expect(Set(model.workspace.detail.changes?.map(\.path) ?? []) == [".gitmodules", "visible.txt"])
            #expect(model.workspace.state(for: resource)?.dirty == true)
            model.workspace.selection = nil
            model.workspace.details.invalidate(resources: [resource])
            model.workspace.startDetailPreload()
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.state(for: resource)?.dirty == true)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test(arguments: [Resource.group("a"), Resource.member("a", "repo")])
    func deletionKeepsUnaffectedSelectionVisibleAndRefreshesItsGitState(_ selected: Resource) async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let base = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))
        let workspaceRemote = fixture.directory.appending(path: "workspace.git")
        _ = try await fixture.service.git.run(["clone", "--bare", fixture.root.path, workspaceRemote.path], at: fixture.directory)
        for arguments in [["remote", "add", "origin", workspaceRemote.absoluteString], ["update-ref", "refs/remotes/origin/main", base], ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]] {
            _ = try await fixture.service.git.run(arguments, at: fixture.root)
        }
        for name in ["a", "b"] {
            try await fixture.prepareGroup(name, repositories: ["repo"])
        }
        let record = try fixture.service.store.load(fixture.root)
        let path = try PathSafety.child(selected.path, of: fixture.root, allowMissing: false)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "selected change"], at: path)
        try Data("pending".utf8).write(to: path.appending(path: "pending.txt"))
        let probe = fixture.directory.appending(path: "deletion-detail-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MONO_DECK_DELETION_DETAIL_PROBE"] = probe.path
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
        if [ -e "$MONO_DECK_DELETION_DETAIL_PROBE/completed" ]; then
            : > "$MONO_DECK_DELETION_DETAIL_PROBE/started"
            trap 'exit 143' TERM INT
            while [ ! -e "$MONO_DECK_DELETION_DETAIL_PROBE/release" ]; do sleep 0.02; done
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
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let record = try #require(initial.workspace.record)
        let probe = fixture.directory.appending(path: "creation-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        var runner = fixture.service.git.runner
        runner.environment["MONO_DECK_CREATION_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let model = AppModel(defaults: initial.defaults, service: service)
        model.workspace.record = record
        model.workspace.selection = .repository("repo")
        try await waitForDetail(model)
        await model.workspace.detailPreloadTask?.value
        model.workspace.setVisibleResources([.repository("repo")], in: record.root)

        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        if [ -e "$MONO_DECK_CREATION_PROBE/completed" ]; then
            : > "$MONO_DECK_CREATION_PROBE/started"
            trap 'exit 143' TERM INT
            while [ ! -e "$MONO_DECK_CREATION_PROBE/release" ]; do sleep 0.02; done
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

    @Test func cachedDetailsAppearImmediatelyAndRefreshExpiredLocalChanges() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        var now = ContinuousClock.now
        let model = try await makeModel(fixture, now: { now })
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
        now = now.advanced(by: .seconds(10))
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
        #expect(model.workspace.detail.summary?.baseOID != nil && model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.detail.commits?.isEmpty == true && model.workspace.detail.commitsError == nil)
        #expect(model.workspace.details.pendingFailure?.error.code == "base-unavailable" && model.workspace.details.pendingFailure?.keepsPreviousResult == true)
        #expect(model.workspace.detail.changes?.map(\.path) == ["new.txt"])

        try FileManager.default.removeItem(at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary == nil && model.workspace.detail.summaryError != nil)
        #expect(model.workspace.detail.changes == nil && model.workspace.detail.changesError != nil)
        #expect(model.workspace.detail.commits == nil && model.workspace.detail.commitsError != nil)
        #expect(model.workspace.state(for: repository)?.available == false)
        #expect(model.workspace.state(for: repository)?.dirty == nil)
    }

    @Test(arguments: [Resource.repository("repo"), Resource.member("feature", "repo")])
    func selectionReadsLocalBaseWithoutFetchingAndRefreshesCachedCommits(_ resource: Resource) async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.prepareGroup("feature", repositories: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let trace = fixture.directory.appending(path: "selection-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        var now = ContinuousClock.now
        let model = AppModel(defaults: initial.defaults, service: WorkspaceService(store: fixture.service.store, git: Git(runner: runner)), now: { now })
        model.workspace.record = record
        let path = record.rootURL.appending(path: resource.path)
        let base = try #require(await fixture.service.git.oid("refs/remotes/origin/main", at: path))
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "first change"], at: path)
        let first = try #require(await fixture.service.git.oid("HEAD", at: path))
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "second change"], at: path)
        let head = try #require(await fixture.service.git.oid("HEAD", at: path))
        try Data("pending".utf8).write(to: path.appending(path: "pending.txt"))
        model.workspace.selection = resource
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.map(\.id) == [head, first])
        #expect(model.workspace.detail.behindCommits?.count == 0)
        model.workspace.selection = nil
        await model.workspace.detailPreloadTask?.value

        let source = fixture.directory.appending(path: "source")
        _ = try await fixture.service.git.run(["fetch", path.path, first], at: source)
        _ = try await fixture.service.git.run(["checkout", "-B", "main", first], at: source)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "remote change"], at: source)
        let remote = try #require(await fixture.service.git.oid("HEAD", at: source))
        _ = try await fixture.service.git.run(["push", fixture.remoteURL, "\(remote):refs/heads/main"], at: source)
        #expect(try await fixture.service.git.oid("refs/remotes/origin/main", at: path) == base)
        let lease = try fixture.service.store.tryLock(fixture.root); defer { lease.unlock() }
        model.workspace.selection = resource
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.baseOID == base)
        #expect(model.workspace.detail.commits?.map(\.id) == [head, first])
        #expect(model.workspace.detail.behindCommits?.isEmpty == true)

        _ = try await fixture.service.git.run(["fetch", "origin"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.baseOID == remote)
        #expect(model.workspace.detail.commits?.map(\.id) == [head])
        #expect(model.workspace.detail.behindCommits?.count == 1)
        #expect(model.workspace.detail.behindCommits?.map(\.id) == [remote])
        #expect(model.workspace.detail.changes?.map(\.path) == ["pending.txt"])
        #expect(try await fixture.service.git.oid("HEAD", at: path) == head)

        _ = try await fixture.service.git.run(["push", "--force", fixture.remoteURL, "\(base):refs/heads/main"], at: source)
        _ = try await fixture.service.git.run(["fetch", "origin"], at: path)
        model.workspace.selection = nil
        now = now.advanced(by: .seconds(10))
        model.workspace.selection = resource
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.baseOID == base)
        #expect(model.workspace.detail.commits?.map(\.id) == [head, first])
        #expect(model.workspace.detail.commitsError == nil)
        #expect(model.workspace.detail.behindCommits?.count == 0)
        model.workspace.selection = nil
        await model.workspace.detailPreloadTask?.value
        let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(!commands.contains { $0.contains("built-in: git fetch ") })
    }

    @Test func behindCommitsLoadAllAndDiscardStaleComparisons() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let source = fixture.directory.appending(path: "source")
        let base = try #require(await fixture.service.git.oid("HEAD", at: source))
        for index in 0..<31 {
            _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "remote change \(index)"], at: source)
        }
        _ = try await fixture.service.git.run(["push", fixture.remoteURL, "HEAD:refs/heads/main"], at: source)
        let path = try #require(model.workspace.record?.repositoryURL("repo"))
        _ = try await fixture.service.git.run(["fetch", "origin"], at: path)
        model.workspace.selection = .repository("repo")
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.isEmpty == true)
        #expect(model.workspace.detail.behindCommits?.count == 31)
        model.workspace.selection = nil
        model.workspace.selection = .repository("repo")
        try await waitForDetail(model)
        #expect(model.workspace.detail.behindCommits?.count == 31)

        _ = try await fixture.service.git.run(["config", "remote.origin.uploadpack", "/usr/bin/false"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.baseOID != nil && model.workspace.detail.behindCommits?.count == 31)

        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.baseOID != nil && model.workspace.detail.behindCommits?.count == 31)
        #expect(model.workspace.details.pendingFailure?.error.code == "base-unavailable" && model.workspace.details.pendingFailure?.keepsPreviousResult == true)
        _ = try await fixture.service.git.run(["config", "--unset", "remote.origin.uploadpack"], at: path)
        _ = try await fixture.service.git.run(["push", "--force", fixture.remoteURL, "\(base):refs/heads/main"], at: source)
        _ = try await fixture.service.git.run(["fetch", "origin"], at: path)
        _ = try await fixture.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.behindCommits?.count == 0 && model.workspace.detail.behindCommits?.isEmpty == true)
    }

    @Test func reloadPreloadsSidebarSnapshotsWithoutPublishingPartialDetails() async throws {
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let initial = try await makeModel(fixture)
        defer { initial.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try await fixture.prepareGroup("feature", repositories: ["repo"])
        let trace = fixture.directory.appending(path: "reload-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let model = AppModel(defaults: initial.defaults, service: WorkspaceService(store: fixture.service.store, git: Git(runner: runner)))
        model.workspace.record = try fixture.service.store.load(fixture.root)
        let record = try #require(model.workspace.record)
        try Data("main".utf8).write(to: record.repositoryURL("repo").appending(path: "main.txt"))
        try Data("group".utf8).write(to: record.groupURL("feature").appending(path: "group.txt"))
        try Data("member".utf8).write(to: record.memberURL("feature", "repo").appending(path: "member.txt"))

        let visibleResources = fixture.service.resources(record)
        model.workspace.setVisibleResources(Set(visibleResources), in: record.root)
        await model.workspace.maintainWorkspace()
        let preloadDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !visibleResources.allSatisfy({ model.workspace.state(for: $0)?.dirty == true }), ContinuousClock.now < preloadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.workspace.selection == nil && model.workspace.detail.summary == nil && !model.workspace.detailLoading)
        #expect(visibleResources.allSatisfy { model.workspace.state(for: $0)?.dirty == true })
        await model.workspace.detailPreloadTask?.value
        await model.workspace.details.snapshotPreloadTask?.value
        for (resource, file, head) in [
            (Resource.repository("repo"), "main.txt", "main"),
            (.group("feature"), "group.txt", "feature"),
            (.member("feature", "repo"), "member.txt", "feature")
        ] {
            model.workspace.selection = resource
            #expect(model.workspace.detail.summary?.head == head)
            #expect(model.workspace.detail.changes?.map(\.path) == [file])
            try await waitForDetail(model)
        }
        await model.workspace.detailPreloadTask?.value
        let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(!commands.contains { $0.contains("built-in: git fetch ") })
        await model.workspace.stopReads()
    }

    @Test func groupDetailsRefreshWhenRemotesAreAddedAndRemoved() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
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
        #expect(model.workspace.detail.summary?.hasRemotes == false && model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.details.pendingFailure?.error.code == "base-unavailable" && model.workspace.details.pendingFailure?.keepsPreviousResult == true)
        #expect(model.workspace.detail.changes?.map(\.path) == ["group.txt"])

        _ = try await fixture.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.base == "origin/main")
        #expect(model.workspace.detail.commits?.map(\.subject) == ["group change"])

        _ = try await fixture.service.git.run(["remote", "remove", "origin"], at: fixture.root)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.hasRemotes == false && model.workspace.detail.summary?.baseError == nil)
        #expect(model.workspace.detail.summary?.base == nil)
        #expect(model.workspace.detail.commits?.isEmpty == true && model.workspace.detail.commitsError == nil)
        #expect(model.workspace.detail.summary?.head == "feature" && model.workspace.detail.summary?.headOID == head)
        #expect(model.workspace.detail.changes?.map(\.path) == ["group.txt"])
    }

    @Test func commitReadFailureAlertsOnlyForTheCurrentSelection() async throws {
        let fixture = try await Fixture(template: .singleRepository)
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
        model.presentDetailFailureIfPossible()
        #expect(model.presentation.messageTitle == model.text.string(.uiGitDetailsRefreshFailed))
        #expect(model.presentation.message?.contains("invalid-date-format") == true)
        #expect(model.presentation.messageHost == .main)

        model.dismissMessage()
        model.workspace.refreshDetail()
        let cancelled = try #require(model.workspace.details.detailTask)
        model.workspace.selection = nil
        await cancelled.value
        await model.workspace.detailPreloadTask?.value
        #expect(cancelled.isCancelled && model.presentation.message == nil)
    }

    @Test func recoveryDiscardsDelayedFailureAndLaterFailureReportsPreservedResults() async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let path = try #require(model.workspace.record?.repositoryURL("repo"))
        model.workspace.selection = .repository("repo")
        do {
            try await waitForDetail(model)
            let head = model.workspace.detail.summary?.headOID
            model.presentation.presentMessage("Existing message", title: "Existing title")
            _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
            model.workspace.refreshDetail()
            try await waitForDetail(model)
            #expect(model.workspace.details.pendingFailure?.keepsPreviousResult == true)
            model.presentDetailFailureIfPossible()
            #expect(model.presentation.message == "Existing message")
            #expect(model.workspace.detail.summary?.headOID == head)

            _ = try await fixture.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: path)
            model.workspace.refreshDetail()
            try await waitForDetail(model)
            model.dismissMessage()
            model.presentDetailFailureIfPossible()
            #expect(model.workspace.details.pendingFailure == nil && model.presentation.message == nil)

            _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
            model.workspace.refreshDetail()
            try await waitForDetail(model)
            model.presentDetailFailureIfPossible()
            #expect(model.presentation.message?.contains(model.text.string(.uiShowingPreviousResults)) == true)
            #expect(model.presentation.message?.hasPrefix("repo: ") == true)
            #expect(model.workspace.detail.summary?.headOID == head)
            await model.workspace.stopReads()
        } catch {
            await model.workspace.stopReads()
            throw error
        }
    }

    @Test func allAheadCommitsAreCachedAcrossSelectionButNotNewHeadsOrWorkspaces() async throws {
        let resource = Resource.repository("repo")
        let fixture = try await Fixture(template: .singleRepository)
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
        #expect(model.workspace.detail.commits?.map(\.subject) == (0..<31).reversed().map { "change \($0)" })
        let detailView = RepositoryDetailView(workspace: model.workspace, preferences: model.preferences, tools: [], preferredToolIDs: [:], openTool: { _ in })
        #expect(detailView.showsCommits)
        _ = try await fixture.service.git.run(["config", "log.date", "invalid-date-format"], at: path)
        model.workspace.selection = nil
        model.workspace.selection = resource
        #expect(model.workspace.detail.commits?.count == 31)
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.count == 31 && model.workspace.detail.commitsError == nil)
        #expect(model.presentation.message == nil)

        _ = try await fixture.service.git.run(["config", "--unset", "log.date"], at: path)
        _ = try await fixture.service.git.run(["commit", "--allow-empty", "-m", "new head"], at: path)
        model.workspace.refreshDetail()
        try await waitForDetail(model)
        #expect(model.workspace.detail.commits?.count == 32)
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
        let fixture = try await Fixture(template: .singleRepository)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }

        let record = try #require(model.workspace.record)
        model.workspace.setVisibleResources([.repository("repo")], in: record.root)
        model.workspace.refreshDetail()
        let initialPreload = try #require(model.workspace.detailPreloadTask)
        model.workspace.selection = .repository("repo")
        #expect(initialPreload.isCancelled)
        #expect(model.workspace.detailPreloadTask == nil && model.workspace.detailLoading)
        await initialPreload.value
        try await waitForDetail(model)
        #expect(model.workspace.detail.summary?.head == "main")
        model.workspace.details.collapsedPaths = ["Sources"]

        let next = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: next).status == .success)
        try Data("next".utf8).write(to: next.appending(path: "repositories/repo/next.txt"))
        try await model.switchTo(next)
        let nextRecord = try #require(model.workspace.record)
        model.workspace.setVisibleResources([.repository("repo")], in: nextRecord.root)
        await model.workspace.detailPreloadTask?.value
        #expect(model.workspace.selection == nil)
        model.workspace.selection = .repository("repo")
        #expect(model.workspace.detail.changes == nil && model.workspace.detail.summary == nil)
        try await waitForDetail(model)
        #expect(model.workspace.detail.changes?.map(\.path) == ["next.txt"])
        #expect(model.workspace.details.collapsedPaths.isEmpty)
        model.workspace.details.collapsedPaths = ["Tests"]

        try await model.switchTo(fixture.root)
        #expect(model.workspace.selection == .repository("repo") && model.workspace.details.collapsedPaths == ["Sources"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.changes?.isEmpty == true)
        try await model.switchTo(next)
        #expect(model.workspace.selection == .repository("repo") && model.workspace.details.collapsedPaths == ["Tests"])
        try await waitForDetail(model)
        #expect(model.workspace.detail.changes?.map(\.path) == ["next.txt"])

        let switching = AppModel(defaults: model.defaults, service: fixture.service)
        switching.workspace.record = try fixture.service.store.load(fixture.root)
        switching.workspace.selection = nil
        let switchingRecord = try #require(switching.workspace.record)
        switching.workspace.setVisibleResources([.repository("repo")], in: switchingRecord.root)
        switching.workspace.refreshDetail()
        let preloadDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while switching.workspace.detailPreloadTask == nil, ContinuousClock.now < preloadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stalePreload = try #require(switching.workspace.detailPreloadTask)
        try await switching.switchTo(next)
        #expect(stalePreload.isCancelled)
        await stalePreload.value
        #expect(switching.workspace.selection == .repository("repo"))
        try await waitForDetail(switching)
        #expect(switching.workspace.detail.changes?.map(\.path) == ["next.txt"])
    }

    private func makeModel(_ fixture: Fixture,
                           now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) async throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service, now: now)
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

import Foundation
import Testing
@testable import ModuCore

struct ResourceSnapshotTests {
    @Test(arguments: [(false, InspectionContent.withSummary), (true, .workingTreeOnly)])
    func concurrentInspectionPublishesBeforeSlowResourcesAndPreservesOrder(_ cancelsAfterPublish: Bool, _ content: InspectionContent) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let path = try await submoduleRepository(f)
        try Data("ignored child edit".utf8).write(to: path.appending(path: "submodule/README"))
        try Data("parent edit".utf8).write(to: path.appending(path: "parent.txt"))
        var record = try f.service.store.load(f.root)
        for name in ["second", "third"] {
            let repository = Repository(url: "https://modu-test.invalid/\(name).git")
            try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL(name))
            _ = try await f.service.git.run(["config", "remote.origin.url", repository.url], at: record.repositoryURL(name))
            record.repositories.append(repository)
        }
        try f.service.store.save(record)
        let probe = f.directory.appending(path: "inspection-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let hook = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        name=$(basename "$PWD")
        : > "$MODU_INSPECTION_PROBE/$name"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_INSPECTION_PROBE/release" ] && [ ! -e "$MODU_INSPECTION_PROBE/release-$name" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for name in ["repo", "second", "third"] {
            for arguments in [["config", "core.fsmonitor", hook.path], ["config", "core.fsmonitorHookVersion", "2"]] {
                _ = try await f.service.git.run(arguments, at: record.repositoryURL(name))
            }
        }
        var runner = f.service.git.runner
        runner.environment["MODU_INSPECTION_PROBE"] = probe.path
        runner.environment["GIT_TRACE"] = probe.appending(path: "trace").path
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let saved = record
        let inspection = Task {
            await service.inspect(saved, content: content, visibility: .application, concurrency: 2) { snapshot in
                #expect(snapshot.changes?.map(\.path) == ["parent.txt"])
                if case .workingTreeOnly = content { #expect(snapshot.summary == nil && snapshot.summaryError == nil) }
                else { #expect(snapshot.summary != nil && snapshot.summaryError == nil) }
                try? Data().write(to: probe.appending(path: "published-\(snapshot.resource.repo ?? "workspace")"))
                if cancelsAfterPublish, snapshot.resource == .repository("second") { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            try await waitForProbe(probe.appending(path: "repo"))
            try await waitForProbe(probe.appending(path: "second"))
            #expect(!PathSafety.exists(probe.appending(path: "third")))
            try Data().write(to: probe.appending(path: "release-second"))
            try await waitForProbe(probe.appending(path: "published-second"))
            if !cancelsAfterPublish { try await waitForProbe(probe.appending(path: "third")) }
            #expect(!PathSafety.exists(probe.appending(path: "published-repo")))
            if !cancelsAfterPublish { try Data().write(to: probe.appending(path: "release")) }
            let result = await inspection.value
            if cancelsAfterPublish { try Data().write(to: probe.appending(path: "release")) }
            #expect(result.status == (cancelsAfterPublish ? .cancelled : .success))
            #expect(result.items.map(\.resource) == [.workspace(), .repository("repo"), .repository("second"), .repository("third")])
            if cancelsAfterPublish {
                #expect(inspection.isCancelled)
                #expect(result.items.map(\.status) == [.success, .cancelled, .success, .cancelled])
            }
            let trace = try String(contentsOf: probe.appending(path: "trace"), encoding: .utf8)
            #expect(!trace.contains("built-in: git log ") && !trace.contains("built-in: git fetch "))
            #expect(!trace.contains("ls-files --stage"))
            if case .workingTreeOnly = content {
                #expect(!trace.contains("built-in: git remote\n") && !trace.contains("refs/remotes/origin/HEAD"))
            }
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            inspection.cancel(); _ = await inspection.value
            throw error
        }
    }

    private func waitForProbe(_ path: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(path))
    }

    @Test(arguments: [Resource.repository("repo"), Resource.member("feature", "repo")])
    func workingStateMatchesExistingChangesAndIncludesHead(_ resource: Resource) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == .success)
        let record = try f.service.store.load(f.root)
        let path = record.rootURL.appending(path: resource.path)
        _ = try await f.service.git.run(["mv", "README", "renamed file\nname"], at: path)
        try Data("edit".utf8).write(to: path.appending(path: "renamed file\nname"))
        try Data("new".utf8).write(to: path.appending(path: "untracked\tfile"))
        let context = try await f.service.prepareResourceRead(resource, in: record)
        let state = try await f.service.workingState(context)
        let changes = try await f.service.git.changes(at: path)
        #expect(state.changes == changes)
        #expect(state.headOID == (try await f.service.git.oid("HEAD", at: path)))
        #expect(state.branch == (resource.group ?? "main"))
        _ = try await f.service.git.run(["checkout", "--detach"], at: path)
        #expect(try await f.service.workingState(context).branch == nil)
        _ = try await f.service.git.run(["config", "remote.origin.url", "https://modu-test.invalid/replaced.git"], at: path)
        #expect(!context.isValid(in: record))
        await #expect(throws: ModuError.self) { try await f.service.workingState(context) }
    }

    @Test func workingStateParsesConflictsUnknownHeadersAndUnbornHead() throws {
        let oid = String(repeating: "a", count: 40)
        let bytes = Data("# branch.oid \(oid)\0# branch.head main\0# future value\0u UU S... 160000 160000 160000 160000 \(oid) \(oid) \(oid) conflict file\0".utf8)
        let state = try Git.parseWorkingState(bytes, visibility: .application)
        #expect(state.headOID == oid && state.branch == "main")
        #expect(state.changes.count == 1 && state.changes[0].conflict && state.changes[0].path == "conflict file")
        #expect(try Git.parseWorkingState(Data("# branch.oid (initial)\0# branch.head main\0".utf8)).headOID == nil)
        for invalid in ["bad\0", "1 M\0", "2 R. N... 100644 100644 100644 x y R100 new\0"] {
            #expect(throws: ModuError.self) { try Git.parseWorkingState(Data(invalid.utf8)) }
        }
    }

    @Test func workingStateKeepsSubmoduleChangesCompatibleWithPorcelainV1() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let path = try await submoduleRepository(f)
        let child = path.appending(path: "submodule")
        try Data("staged".utf8).write(to: child.appending(path: "README"))
        _ = try await f.service.git.run(["add", "README"], at: child)
        try Data("unstaged".utf8).write(to: child.appending(path: "README"))
        try Data("untracked".utf8).write(to: path.appending(path: "submodule/new.txt"))
        let state = try await f.service.git.workingState(at: path)
        #expect(state.changes == (try await f.service.git.changes(at: path)))
        #expect(state.changes.first?.workingTree == "M")
        #expect(try await f.service.git.workingState(at: path, visibility: .application).changes.isEmpty)

        let modules = path.appending(path: ".gitmodules")
        var contents = try Data(contentsOf: modules); contents.append(Data("\n# parent configuration\n".utf8))
        try contents.write(to: modules)
        try Data("parent".utf8).write(to: path.appending(path: "parent.txt"))
        _ = try await f.service.git.run(["commit", "-am", "submodule change"], at: child)
        _ = try await f.service.git.run(["add", "submodule"], at: path)
        let visible = try await f.service.git.workingState(at: path, visibility: .application)
        #expect(visible.changes.map(\.path) == [".gitmodules", "parent.txt"])
        #expect(visible.headOID == state.headOID && visible.branch == state.branch)
        #expect(try await f.service.git.workingState(at: path).changes.map(\.path) == [".gitmodules", "parent.txt", "submodule"])
        #expect(try await f.service.git.changeCount(at: path) == 3)
    }

    @Test func applicationChangesHideRenamedGitlinks() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let path = try await submoduleRepository(f)
        let changedPath = "renamed module"
        _ = try await f.service.git.run(["mv", "submodule", changedPath], at: path)
        let complete = try await f.service.git.workingState(at: path)
        #expect(complete.changes.contains { $0.path == changedPath })
        let visible = try await f.service.git.workingState(at: path, visibility: .application)
        #expect(visible.changes.map(\.path) == [".gitmodules"])
        #expect(try await f.service.git.submodulePaths(at: path) == [changedPath])
    }

    @Test(arguments: [false, true])
    func applicationChangesPreserveSubmoduleTypeConversions(_ toSubmodule: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let path = try await submoduleRepository(f)
        let converted: String
        if toSubmodule {
            converted = "ordinary.txt"
            try Data("ordinary file".utf8).write(to: path.appending(path: converted))
            _ = try await f.service.git.run(["add", converted], at: path)
            _ = try await f.service.git.run(["commit", "-m", "add ordinary file"], at: path)
            _ = try await f.service.git.run(["rm", converted], at: path)
            _ = try await f.service.git.run(["submodule", "add", f.remoteURL, converted], at: path)
        } else {
            converted = "submodule"
            _ = try await f.service.git.run(["rm", "-f", converted], at: path)
            try Data("ordinary file".utf8).write(to: path.appending(path: converted))
            _ = try await f.service.git.run(["add", converted], at: path)
        }
        let visible = try await f.service.git.workingState(at: path, visibility: .application)
        let change = try #require(visible.changes.first { $0.path == converted })
        #expect(change.index == "T" && !change.conflict)
        #expect(visible.changes.contains { $0.path == ".gitmodules" })
        #expect(try await f.service.git.submodulePaths(at: path) == (toSubmodule ? ["ordinary.txt", "submodule"] : []))
    }

    @Test func applicationChangesPreserveUnstagedSubmoduleTypeConversions() throws {
        let oid = String(repeating: "a", count: 40)
        let bytes = Data("1 .T S... 160000 160000 100644 \(oid) \(oid) submodule\0".utf8)
        let visible = try Git.parseWorkingState(bytes, visibility: .application)
        let change = try #require(visible.changes.first)
        #expect(visible.changes.count == 1 && change.path == "submodule")
        #expect(change.index == " " && change.workingTree == "T" && !change.conflict)
    }

    private func submoduleRepository(_ fixture: Fixture) async throws -> URL {
        try #require(await fixture.service.openWorkspace(fixture.root).status == .success)
        try #require(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        let path = try fixture.service.store.load(fixture.root).repositoryURL("repo")
        _ = try await fixture.service.git.run(["submodule", "add", fixture.remoteURL, "submodule"], at: path)
        _ = try await fixture.service.git.run(["commit", "-m", "add submodule"], at: path)
        return path
    }

    @Test func defaultQueriesKeepChangesAndMissingBaseLocal() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root), resource = Resource.repository("repo")
        let path = record.repositoryURL("repo")
        _ = try await fixture.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: path)
        try Data("keep changes".utf8).write(to: path.appending(path: "new.txt"))
        let trace = fixture.directory.appending(path: "local-query-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))

        let context = try await service.prepareResourceRead(resource, in: record)
        let snapshot = try await service.localSnapshot(context, content: .withSummary)
        #expect(snapshot.changes?.map(\.path) == ["new.txt"] && snapshot.changesError == nil)
        #expect(snapshot.summary?.baseOID == nil && snapshot.summary?.baseError != nil && snapshot.summaryError == nil)
        let result = await service.inspect(record)
        let item = try #require(result.items.first { $0.resource == resource })
        #expect(item.status == .success && item.data?["working-tree"] == "dirty")
        #expect(item.data?["head"] == "main" && item.data?["base-error"] != nil)
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(!commands.contains("built-in: git fetch ") && !commands.contains("built-in: git log "))
    }

    @Test(arguments: ["before-start", "between-resources", "after-completion"])
    func inspectionCancellationPreservesCompletedItems(_ timing: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        for group in ["first", "second"] { try await fixture.prepareEmptyGroup(group) }
        let record = try fixture.service.store.load(fixture.root)
        let inspection = Task {
            if timing == "before-start" { withUnsafeCurrentTask { $0?.cancel() } }
            return await fixture.service.inspect(record) { snapshot in
                let target = timing == "after-completion" ? "second" : "first"
                if snapshot.resource == .group(target) { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await inspection.value
        #expect(inspection.isCancelled)
        #expect(result.items.map(\.resource) == [.workspace(), .group("first"), .group("second")])
        let expected: [OperationStatus] = timing == "before-start" ? [.cancelled, .cancelled, .cancelled]
            : timing == "between-resources" ? [.success, .success, .cancelled] : [.success, .success, .success]
        #expect(result.items.map(\.status) == expected)
        #expect(result.status == (timing == "after-completion" ? .success : .cancelled))
        #expect(result.reasonCode == (timing == "after-completion" ? nil : "cancelled"))
        #expect(result.exitCode == (timing == "after-completion" ? 0 : 130))
    }

    @Test func inspectionCancellationKeepsEarlierFailures() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        for group in ["broken", "first", "second"] { try await fixture.prepareEmptyGroup(group) }
        let record = try fixture.service.store.load(fixture.root)
        try Data("gitdir: missing-git-directory\n".utf8).write(to: record.groupURL("broken").appending(path: ".git"))
        let inspection = Task {
            await fixture.service.inspect(record) { snapshot in
                if snapshot.resource == .group("first") { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await inspection.value
        #expect(result.items.map(\.status) == [.success, .failed, .success, .cancelled])
        #expect(result.status == .partialSuccess && result.reasonCode == nil && result.exitCode == 1)
    }
}

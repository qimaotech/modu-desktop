import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct WorkspaceLoadingTests {
    @Test(arguments: [false, true])
    func reloadReinitializesRecreatedWorkspaceAndAllowsYAMLImport(_ implicit: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        #expect(await fixture.service.createGroup("old", repositories: ["repo"], at: fixture.root).status == "success")
        await model.reload()
        await model.detailPreloadTask?.value
        model.selection = .member("old", "repo")
        await model.reload()

        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        let notes = fixture.root.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: notes)
        if implicit { await model.activate() }
        else { model.completionMessage = "Completed"; await model.reload() }

        let record = try #require(model.workspace)
        #expect(record.repositories.isEmpty && record.groups.isEmpty)
        #expect(model.selection == nil && model.blocked == nil && model.result == nil)
        #expect(model.completionMessage == nil)
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(try fixture.service.store.load(fixture.root) == record)
        for path in [".git", "repositories", "worktrees", ".agents/skills/modu-workflow/SKILL.md"] {
            #expect(PathSafety.exists(fixture.root.appending(path: path)))
        }
        #expect(try await fixture.service.git.run(["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.root).text.components(separatedBy: "\n") == [".agents/skills/modu-workflow/SKILL.md", ".gitignore"])
        #expect(try Data(contentsOf: notes) == Data("keep me".utf8))
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        await model.reload()
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)

        let yaml = """
        version: 1
        repositories: [{url: \(fixture.remoteURL)}]
        groups:
          feature:
            created-at: "2026-10-10T00:00:00Z"
            repositories: [repo]
        """
        let imported = await fixture.service.importWorkspaceYAML(yaml, at: fixture.root)
        #expect(imported.status == "success", "\(imported)")
        await model.reload()
        #expect(model.workspace?.groups["feature"]?.repositories == ["repo"])
        #expect(model.blocked == nil && model.result == nil)
    }

    @Test func explicitAndImplicitReloadsShareInitializationWithoutExtraCommits() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        await model.activate()
        #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(PathSafety.exists(fixture.root.appending(path: ".gitignore")))
        let head = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))

        var record = try #require(model.workspace)
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let refreshing = Task { await model.activate() }
        try await waitForReadLock(fixture)
        await model.reload()
        await refreshing.value
        #expect(model.workspace?.groups.isEmpty == true)
        #expect(model.blocked == nil && model.result == nil && !model.workspaceWaiting)
        #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)
    }

    @Test func postOperationReloadInitializesAndKeepsTheCreatedGroupSelected() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        await model.reload()
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        model.sheet = .create
        model.run({ service, root, progress in
            let outcome = await service.createGroup("feature", repositories: ["repo"], at: root, progress: progress)
            guard outcome.status == "success" else { return outcome }
            do {
                try FileManager.default.removeItem(at: root.appending(path: ".agents"))
            } catch { return .init(command: outcome.command, workspace: root.path, status: "failed", error: .wrap(error)) }
            return outcome
        }, select: .group("feature"))
        await (try #require(model.operation)).value
        #expect(model.selection == .group("feature") && model.expandedGroups.contains("feature"))
        #expect(model.completionMessage == model.t("Completed", "已完成"))
        #expect(model.sheet == nil && model.result == nil && model.blocked == nil)
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
        #expect(PathSafety.exists(fixture.root.appending(path: "repositories")))
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)
    }

    @Test(arguments: ["missing", "invalid"], [false, true])
    func reloadDoesNotInitializeWithMissingOrInvalidRecord(_ kind: String, _ implicit: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let file = fixture.service.store.recordURL(fixture.root)
        if kind == "missing" { try FileManager.default.removeItem(at: file) }
        else { try Data("broken".utf8).write(to: file) }
        try FileManager.default.removeItem(at: fixture.root.appending(path: ".git"))

        if implicit { await model.activate() } else { await model.reload() }
        #expect(model.workspace == nil && model.blocked != nil && model.result == nil)
        #expect(!model.busy && !model.openingWorkspace)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.root.appending(path: ".agents")))
        if kind == "missing" { #expect(!PathSafety.exists(file)) }
        else { #expect(try Data(contentsOf: file) == Data("broken".utf8)) }
    }

    @Test(arguments: [false, true])
    func reloadInitializationFailureReportsRetainedEffectsAndCanRetry(_ implicit: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        _ = try await fixture.service.git.run(["config", "commit.gpgSign", "true"], at: fixture.root)
        _ = try await fixture.service.git.run(["config", "gpg.program", "/usr/bin/false"], at: fixture.root)
        if implicit { await model.activate() } else { await model.reload() }
        #expect(model.workspace == nil && model.blocked != nil && !model.busy)
        #expect(model.result?.items.first?.reasonCode == "workspace-commit-failed")
        #expect(model.result?.items.first?.effects.contains { $0.action == "install-skill" } == true)
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)

        _ = try await fixture.service.git.run(["config", "commit.gpgSign", "false"], at: fixture.root)
        model.dismissResult()
        if implicit { await model.activate() } else { await model.reload() }
        #expect(model.workspace != nil && model.blocked == nil && model.result == nil)
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) != head)
        #expect(try await fixture.service.git.changes(at: fixture.root).isEmpty)
    }

    @Test func startupAndRefreshValidateEachGroupOnlyOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        let record = try await fixture.service.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let trace = fixture.directory.appending(path: "startup-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: service, toolService: tools, installer: try makeInstaller(fixture))
        func validationCount() throws -> Int {
            try String(contentsOf: trace, encoding: .utf8).components(separatedBy: "\n")
                .filter { $0.contains("built-in: git check-ref-format refs/heads/feature") }.count
        }

        #expect(await model.start() == false)
        await model.detailPreloadTask?.value
        #expect(model.workspace == record && model.blocked == nil)
        #expect(model.tools.map(\.id) == ["codex"])
        #expect(try validationCount() == 1)
        let statuses = try String(contentsOf: trace, encoding: .utf8).components(separatedBy: "\n")
            .filter { $0.contains("built-in: git status --porcelain=v1") }
        #expect(statuses.count == service.resources(record).count)
        #expect(service.resources(record).allSatisfy { model.states[$0.id]?.available == true && model.states[$0.id]?.dirty == false })
        #expect(await model.start() == false)
        #expect(try validationCount() == 1)

        try Data("changed".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
        await model.activate()
        await model.detailPreloadTask?.value
        #expect(model.states[Resource.repository("repo").id]?.dirty == true)
        #expect(try validationCount() == 2)

        try FileManager.default.removeItem(at: record.memberURL("feature", "repo"))
        await model.reload()
        await model.detailPreloadTask?.value
        #expect(model.workspace?.groups["feature"]?.repositories == [])
        #expect(try service.store.load(fixture.root).groups["feature"]?.repositories == [])
        #expect(try validationCount() == 3)
    }

    @Test func startupPublishesWorkspaceAndToolsBeforeSlowResourceChecks() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        var record = try await fixture.service.load(fixture.root)
        let other = Repository(url: "https://modu-test.invalid/other.git")
        try FileManager.default.copyItem(at: record.repositoryURL("repo"), to: record.repositoryURL(other.id))
        _ = try await fixture.service.git.run(["config", "remote.origin.url", other.url], at: record.repositoryURL(other.id))
        record.repositories.append(other)
        try fixture.service.store.save(record)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")

        let probe = fixture.directory.appending(path: "startup-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_STARTUP_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_STARTUP_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: record.repositoryURL(other.id))
        }
        var runner = fixture.service.git.runner
        runner.environment["MODU_STARTUP_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? probe.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: service, toolService: tools, installer: try makeInstaller(fixture))
        var completed = false
        let startup = Task { let needsSetup = await model.start(); completed = true; return needsSetup }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(completed && !model.busy && !model.openingWorkspace)
            #expect(model.workspace == record && model.blocked == nil)
            #expect(model.tools.map(\.id) == ["codex"])
            try Data("changed".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
            model.selection = .repository("repo")
            let detailDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.detailLoading, ContinuousClock.now < detailDeadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.detailLoading && model.detail.changes?.map(\.path) == ["new.txt"])
            #expect(model.states[Resource.repository("repo").id]?.dirty == true)
            try Data().write(to: probe.appending(path: "release"))
            #expect(await startup.value == false)
            await model.detailPreloadTask?.value
            #expect(model.states[Resource.repository(other.id).id]?.available == true)
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            _ = await startup.value
            await model.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: ["available", "missing", "not-executable", "broken", "missing-path"])
    func startupChecksCLIBeforeOpeningTheSavedWorkspace(_ kind: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let saved = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(saved)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        defaults.set(saved.root, forKey: "workspace")
        defaults.set(false, forKey: "sidebar.\(saved.root).repositoriesExpanded")
        let installer = try makeInstaller(fixture, resolved: kind != "missing-path")
        switch kind {
        case "missing": try FileManager.default.removeItem(at: installer.executable)
        case "not-executable": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installer.executable.path)
        case "broken": try Data("#!/bin/sh\nexit 1\n".utf8).write(to: installer.executable)
        default: break
        }
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)

        #expect(await model.start() == (kind != "available"))
        #expect(model.blocked == nil && model.result == nil && !model.busy)
        #expect(defaults.string(forKey: "workspace") == saved.root)
        if kind == "available" {
            #expect(model.workspace == saved)
            #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)
            try FileManager.default.removeItem(at: installer.executable)
            let reopened = AppModel(defaults: defaults, service: fixture.service, installer: installer)
            #expect(await reopened.start())
            #expect(reopened.workspace == nil && reopened.blocked == nil && reopened.result == nil)
        } else {
            #expect(model.workspace == nil && model.operation == nil)
            #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
            #expect(defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)
            #expect(!PathSafety.exists(fixture.directory.appending(path: ".local")))
        }
    }

    @Test(arguments: ["repository", "group", "member"])
    func reloadRemovesDeletedDirectoriesAndTheirReferences(_ kind: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        for group in ["feature", "kept"] {
            #expect(await fixture.service.createGroup(group, repositories: ["repo"], at: fixture.root).status == "success")
        }
        await model.reload()
        await model.detailPreloadTask?.value
        var expected = try #require(model.workspace)
        let resource: Resource
        switch kind {
        case "repository":
            resource = .repository("repo")
            expected.repositories = []
            for group in expected.groups.keys { expected.groups[group]?.repositories = [] }
        case "group":
            resource = .group("feature")
            expected.groups.removeValue(forKey: "feature")
        default:
            resource = .member("feature", "repo")
            expected.groups["feature"]?.repositories = []
        }
        model.expandedGroups = ["feature", "kept"]
        model.selection = resource
        try FileManager.default.removeItem(at: fixture.root.appending(path: resource.path))
        await model.reload()
        await model.detailPreloadTask?.value

        #expect(model.workspace == expected)
        #expect(try fixture.service.store.load(fixture.root) == expected)
        #expect(model.selection == nil && model.detail.summary == nil)
        #expect(model.states[resource.id] == nil && model.blocked == nil)
        #expect(model.expandedGroups == Set(expected.groups.keys))
        #expect(PathSafety.exists(expected.groupURL("kept")))
        #expect(PathSafety.exists(expected.memberURL("kept", "repo")))
        #expect(try await fixture.service.git.oid("refs/heads/feature", at: fixture.root) != nil)
        #expect(try await fixture.service.git.registrations(at: fixture.root).count == 3)
        if kind != "repository" {
            #expect(try await fixture.service.git.oid("refs/heads/feature", at: expected.repositoryURL("repo")) != nil)
            #expect(try await fixture.service.git.registrations(at: expected.repositoryURL("repo")).count == 3)
        }
        let inspection = await fixture.service.inspect(fixture.root)
        #expect(inspection.status == "success")
        #expect(inspection.items.allSatisfy { $0.resource != resource })
    }

    @Test(arguments: ["open", "inspect", "cli"])
    func workspaceEntryPointsPersistMissingResourceCleanup(_ entry: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let empty = try await fixture.service.load(fixture.root)
        var record = empty
        record.repositories = [.init(url: fixture.remoteURL)]
        record.groups["feature"] = WorktreeGroup(repositories: ["repo"])
        try fixture.service.store.save(record)
        switch entry {
        case "open":
            let opened = await fixture.service.openWorkspaceWithRecord(fixture.root)
            #expect(opened.result.status == "success" && opened.record == empty)
        case "inspect": #expect(await fixture.service.inspect(fixture.root).status == "success")
        default:
            let executable = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
            var runner = fixture.service.git.runner
            runner.environment["MODU_TEST_SUPPORT_DIRECTORY"] = fixture.service.store.support.path
            let output = try await runner.run(executable.path, ["repo", "list", "--json", "--workspace", fixture.root.path])
            #expect(output.status == 0)
            #expect(try JSONDecoder().decode(OperationResult.self, from: output.stdout).items.isEmpty)
        }
        #expect(try fixture.service.store.load(fixture.root) == empty)
    }

    @Test(arguments: ["git", "file", "symlink", "permissions"])
    func unavailableDirectoriesKeepTheirConfiguration(_ kind: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        var record = try await fixture.service.load(fixture.root)
        record.repositories = [.init(url: fixture.remoteURL)]
        try fixture.service.store.save(record)
        let path = record.repositoryURL("repo")
        switch kind {
        case "git": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        case "file": try Data("keep".utf8).write(to: path)
        case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.directory.appending(path: "missing"))
        default: try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.deletingLastPathComponent().path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.deletingLastPathComponent().path) }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        #expect(try await fixture.service.load(fixture.root) == record)
        let inspection = await fixture.service.inspect(fixture.root)
        #expect(inspection.items.first { $0.resource == .repository("repo") }?.status == "failed")
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func failedCleanupAndMissingWorkspaceDoNotOverwriteConfiguration() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        var record = try #require(model.workspace)
        record.repositories = [.init(url: fixture.remoteURL)]
        try fixture.service.store.save(record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let failingStore = WorkspaceStore(support: fixture.service.store.support) { _, _ in throw ModuError("injected", "save failed") }
        let failing = AppModel(defaults: model.defaults, service: WorkspaceService(store: failingStore, git: fixture.service.git))
        await failing.reload()
        #expect(failing.workspace == nil && failing.blocked != nil)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)

        try FileManager.default.removeItem(at: fixture.root)
        await model.reload()
        #expect(model.workspace == nil && model.blocked != nil)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func openingWorkspacesUsesSavedRecordsAndPreservesHistory() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL, name: "Custom"), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        for group in ["feature", "closed"] {
            #expect(await fixture.service.createGroup(group, repositories: ["repo"], at: fixture.root).status == "success")
        }
        await model.reload()
        model.toggleGroup("feature")
        model.defaults.set(false, forKey: model.sidebarPreferenceKey("repositoriesExpanded"))
        model.defaults.set(false, forKey: model.sidebarPreferenceKey("groupsExpanded"))
        model.defaults.set("zh", forKey: "language")
        model.defaults.set("codex", forKey: "tool.Agent")
        let saved = try #require(model.workspace)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))

        let reopened = AppModel(defaults: model.defaults, service: fixture.service, installer: try makeInstaller(fixture))
        #expect(await reopened.start() == false)
        #expect(reopened.blocked == nil && !reopened.busy)
        #expect(reopened.expandedGroups == ["feature"])
        #expect(reopened.defaults.object(forKey: reopened.sidebarPreferenceKey("repositoriesExpanded")) as? Bool == false)
        #expect(reopened.defaults.object(forKey: reopened.sidebarPreferenceKey("groupsExpanded")) as? Bool == false)
        #expect(reopened.workspace?.repositories.first?.url == fixture.remoteURL)
        #expect(reopened.workspace == saved)
        #expect(reopened.workspace?.repositories.first?.name == "Custom")
        #expect(Set(reopened.workspace?.groups.keys ?? [:].keys) == ["feature", "closed"])

        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        reopened.changeWorkspace(nextRoot)
        await reopened.operation?.value
        #expect(reopened.workspace?.rootURL == PathSafety.canonical(nextRoot) && reopened.result == nil)
        #expect(reopened.expandedGroups.isEmpty)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try fixture.service.store.locate(explicit: fixture.root.path, cwd: fixture.root) == PathSafety.canonical(fixture.root))
        #expect(reopened.defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)

        reopened.changeWorkspace(fixture.root)
        await reopened.operation?.value
        #expect(reopened.workspace?.rootURL == PathSafety.canonical(fixture.root) && reopened.result == nil)
        #expect(reopened.workspace?.groups["feature"]?.repositories == ["repo"])
        #expect(reopened.workspace?.groups["closed"]?.repositories == ["repo"])
        #expect(reopened.expandedGroups == ["feature"] && reopened.selection == nil)
        #expect(reopened.workspace == saved)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(PathSafety.exists(fixture.service.store.recordURL(nextRoot)))
        #expect(reopened.defaults.string(forKey: "language") == "zh")
        #expect(reopened.defaults.string(forKey: "tool.Agent") == "codex")
        #expect(try fixture.service.store.locate(explicit: nil, cwd: fixture.root.appending(path: "worktrees/feature/repo")) == PathSafety.canonical(fixture.root))
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
        await reopened.reload()
        #expect(reopened.expandedGroups == ["feature"])
    }

    @Test func lockedHistoryDoesNotPreventSwitchingAndIsKept() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let history = fixture.directory.appending(path: "history")
        try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(history).path))
        let lease = try fixture.service.store.lock(history)
        defer { lease.unlock() }
        let historyRecord = try Data(contentsOf: fixture.service.store.recordURL(history))
        let next = fixture.directory.appending(path: "next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace?.rootURL == PathSafety.canonical(next) && model.result == nil)
        #expect(model.defaults.string(forKey: "workspace") == PathSafety.canonical(next).path)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(history)) == historyRecord)
    }

    @Test func changingWorkspaceCreatesOrLoadsWithoutCLIAndPublishesOnlyWhenReady() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace)
        let next = fixture.directory.appending(path: "new-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try Data("keep me".utf8).write(to: next.appending(path: "notes.txt"))
        #expect(!PathSafety.exists(model.installer.executable))

        model.changeWorkspace(next)
        #expect(model.busy && model.openingWorkspace)
        #expect(model.workspace == original)
        #expect(model.defaults.string(forKey: "workspace") == original.root)
        let opening = try #require(model.operation)
        model.changeWorkspace(fixture.root)
        await opening.value
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(model.workspace?.rootURL == PathSafety.canonical(next))
        #expect(model.defaults.string(forKey: "workspace") == PathSafety.canonical(next).path)
        #expect(model.selection == nil && model.result == nil && model.workspaceNotice == nil)
        #expect(PathSafety.exists(next.appending(path: ".git")))
        #expect(PathSafety.exists(next.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
        #expect(try String(contentsOf: next.appending(path: "notes.txt"), encoding: .utf8) == "keep me")

        let alias = fixture.directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: next)
        model.changeWorkspace(alias)
        #expect(!model.busy && model.operation == nil)
        model.changeWorkspace(fixture.root)
        await model.operation?.value
        #expect(model.workspace == original && model.result == nil)
    }

    @Test func invalidLockedAndCancelledChangesKeepTheCurrentWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        await model.reload()
        await model.detailPreloadTask?.value
        model.selection = .repository("repo")
        let oldHead = try #require(model.detail.summary?.headOID)
        let original = try #require(model.workspace)
        model.expandedGroups = ["expanded"]
        let next = fixture.directory.appending(path: "locked")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == "success")
        let lease = try fixture.service.store.lock(next)
        let nested = fixture.root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        for target in [next, nested, fixture.directory.appending(path: "missing")] {
            model.changeWorkspace(target)
            await model.operation?.value
            #expect(model.result != nil && model.resultHost == .settings)
            #expect(model.workspace == original && model.selection == .repository("repo"))
            #expect(model.defaults.string(forKey: "workspace") == original.root)
            #expect(model.detail.summary?.headOID == oldHead && model.expandedGroups == ["expanded"])
            #expect(!model.busy && !model.openingWorkspace)
            model.dismissResult()
        }
        lease.unlock()
        model.changeWorkspace(next)
        model.cancel()
        await model.operation?.value
        #expect(model.workspace == original && model.selection == .repository("repo"))
        #expect(model.defaults.string(forKey: "workspace") == original.root)
        #expect(!model.busy && !model.openingWorkspace)
        #expect(model.result == nil || model.result?.status == "cancelled")
    }

    @Test func failedInitializationAndFinalLoadKeepOldReferenceAndReportEffects() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace)
        let next = fixture.directory.appending(path: "invalid-ignore")
        try FileManager.default.createDirectory(at: next.appending(path: ".gitignore"), withIntermediateDirectories: true)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace == original && model.defaults.string(forKey: "workspace") == original.root)
        #expect(model.result?.status == "failed")
        #expect(model.result?.items.flatMap(\.effects).contains { $0.action == "git-init" && $0.state == "applied" } == true)
        #expect(PathSafety.exists(next.appending(path: ".git")))
        model.dismissResult()

        let invalid = fixture.directory.appending(path: "corrupt-record")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data("broken".utf8).write(to: fixture.service.store.recordURL(invalid))
        do { try await model.switchTo(invalid); Issue.record("Expected invalid workspace to be rejected") }
        catch { #expect((error as? ModuError)?.code == "invalid-configuration") }
        #expect(model.workspace == original && model.defaults.string(forKey: "workspace") == original.root)
    }

    @Test func skillConflictDoesNotBlockSwitchOrOverwriteUserFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let next = fixture.directory.appending(path: "skill-conflict")
        let skill = next.appending(path: ".agents/skills/modu-workflow")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: skill)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace?.rootURL == PathSafety.canonical(next))
        #expect(model.workspaceNotice != nil && model.result == nil && !model.busy)
        #expect(try String(contentsOf: skill, encoding: .utf8) == "user skill")
        model.workspaceNotice = nil
        #expect(model.workspaceNotice == nil)
    }

    @Test func overlappingReloadsKeepTheLoadedWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var record = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        record.groups["feature"] = WorktreeGroup()
        try FileManager.default.createDirectory(at: record.groupURL("feature"), withIntermediateDirectories: true)
        try fixture.service.store.save(record)
        let suite = "ModuLoadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)

        let first = Task { await model.reload() }
        try await waitForReadLock(fixture)
        await model.reload()
        await first.value

        #expect(model.workspace == record)
        #expect(model.blocked == nil)
        #expect(!model.workspaceWaiting)
    }

    @Test func switchingWorkspacesWhileLoadingKeepsTheNewWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var original = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        original.groups["feature"] = WorktreeGroup()
        try FileManager.default.createDirectory(at: original.groupURL("feature"), withIntermediateDirectories: true)
        try fixture.service.store.save(original)
        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(nextRoot).status == "success")
        let next = try await fixture.service.load(nextRoot)
        let suite = "ModuLoadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(original.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)

        let first = Task { await model.reload() }
        try await waitForReadLock(fixture)
        try await model.switchTo(nextRoot)
        await first.value

        #expect(model.workspace == next)
        #expect(model.blocked == nil)
        #expect(!model.workspaceWaiting)
    }

    @Test func lockContentionCanRetryAndDoesNotBecomeAMissingWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let record = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(record)
        let suite = "ModuLoadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        await model.reload()
        #expect(!model.hasSavedWorkspace)
        #expect(model.blocked == nil && !model.workspaceWaiting)

        defaults.set(record.root, forKey: "workspace")
        let lease = try fixture.service.store.lock(fixture.root)
        await model.reload()
        #expect(model.hasSavedWorkspace && model.workspaceWaiting)
        #expect(model.workspace == nil && model.blocked == nil)
        lease.unlock()

        await model.reload()
        #expect(model.workspace == record)
        #expect(!model.workspaceWaiting && model.blocked == nil)
        let nextLease = try fixture.service.store.lock(fixture.root)
        await model.reload()
        #expect(model.workspace == record)
        #expect(model.blocked == nil)
        nextLease.unlock()

        try FileManager.default.removeItem(at: fixture.service.store.recordURL(fixture.root))
        await model.reload()
        #expect(model.workspace == nil && model.blocked != nil)
        #expect(!model.workspaceWaiting)
    }

    private func makeModel(_ fixture: Fixture) async throws -> AppModel {
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        defaults.set(model.workspace?.root, forKey: "workspace")
        return model
    }

    private func makeInstaller(_ fixture: Fixture, resolved: Bool = true) throws -> InstallationService {
        let shell = fixture.directory.appending(path: "login-shell")
        try Data("#!/bin/sh\nprintf '%s' \"$MODU_FAKE_RESOLVED\"\n".utf8).write(to: shell)
        let executable = fixture.service.store.support.appending(path: "versions/0.1.0/modu-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '0.1.0\\n'\n".utf8).write(to: executable)
        for file in [shell, executable] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        var environment = fixture.service.git.runner.environment
        environment["MODU_FAKE_RESOLVED"] = resolved ? executable.path : ""
        return InstallationService(support: fixture.service.store.support, runner: .init(environment: environment), home: fixture.directory, shell: shell.path)
    }

    private func waitForReadLock(_ fixture: Fixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            do { let lease = try fixture.service.store.lock(fixture.root); lease.unlock() }
            catch let error as ModuError where error.code == "workspace-busy" { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ModuError("test-timeout", "Workspace reload did not acquire its read lock.")
    }
}

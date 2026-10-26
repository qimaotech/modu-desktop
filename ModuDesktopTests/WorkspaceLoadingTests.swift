import Foundation
import AppKit
import Testing
import SwiftUI
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct WorkspaceLoadingTests {
    @Test func reloadReinitializesRecreatedWorkspaceWithoutLosingUserFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        #expect(await fixture.service.createGroup("old", repositories: ["repo"], at: fixture.root).status == .success)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.selection = .member("old", "repo")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.workspace.detailLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!model.workspace.detailLoading)
        await model.workspace.detailPreloadTask?.value

        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        let notes = fixture.root.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: notes)
        model.presentation.completionMessage = "Completed"
        await model.workspace.reload()

        let record = try #require(model.workspace.record)
        #expect(record.repositories.isEmpty && record.groups.isEmpty)
        #expect(model.workspace.selection == nil && model.workspace.blocked == nil && model.presentation.result == nil)
        #expect(model.presentation.completionMessage == nil)
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(try fixture.service.store.load(fixture.root) == record)
        for path in [".git", "repositories", "worktrees", ".agents/skills/modu-workflow/SKILL.md", ".agents/skills/modu-workflow/agents/openai.yaml"] {
            #expect(PathSafety.exists(fixture.root.appending(path: path)))
        }
        #expect(try await fixture.service.git.run(["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.root).text.components(separatedBy: "\n") == [".agents/skills/modu-workflow/SKILL.md", ".agents/skills/modu-workflow/agents/openai.yaml", ".gitignore"])
        #expect(try Data(contentsOf: notes) == Data("keep me".utf8))
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        await model.workspace.reload()
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)

    }

    @Test func explicitAndImplicitReloadsShareInitializationWithoutExtraCommits() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        await model.activate()
        #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(PathSafety.exists(fixture.root.appending(path: ".gitignore")))
        let head = try #require(await fixture.service.git.oid("HEAD", at: fixture.root))

        var record = try #require(model.workspace.record)
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let refreshing = Task { await model.activate() }
        try await waitForReadLock(fixture)
        await model.workspace.reload()
        await refreshing.value
        #expect(model.workspace.record?.groups.isEmpty == true)
        #expect(model.workspace.blocked == nil && model.presentation.result == nil && !model.workspace.waiting)
        #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)
    }

    @Test(arguments: [false, true])
    func activationKeepsSettingsImportFailurePresented(_ dismissDuringReload: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let file = fixture.root.appending(path: "repositories/.user-data")
        try Data("keep me".utf8).write(to: file)
        model.presentation.resultHost = .settings
        model.management.importWorkspace("version: 1\nrepositories: []\ngroups: {}", filename: "workspace.yaml")
        await (try #require(model.operation)).value
        #expect(model.presentation.result?.reasonCode == "workspace-not-empty" && model.presentation.resultHost == .settings)
        let presentation = SettingsView(model: model).operationSheetPresentation
        #expect(presentation.wrappedValue)

        var record = try #require(model.workspace.record)
        record.groups["missing"] = WorktreeGroup()
        try fixture.service.store.save(record)
        let refresh = Task { await model.activate() }
        try await waitForReadLock(fixture)
        #expect(model.busy && model.openingWorkspace)
        #expect(presentation.wrappedValue)
        #expect(model.presentation.result?.reasonCode == "workspace-not-empty" && model.presentation.resultHost == .settings)
        if dismissDuringReload {
            presentation.wrappedValue = false
            #expect(!presentation.wrappedValue && model.presentation.result == nil)
        }
        await refresh.value

        #expect(!model.busy && !model.openingWorkspace)
        #expect(presentation.wrappedValue == !dismissDuringReload)
        #expect(model.workspace.record?.groups.isEmpty == true)
        #expect(try fixture.service.store.load(fixture.root).groups.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
        if !dismissDuringReload {
            #expect(model.presentation.result?.reasonCode == "workspace-not-empty" && model.presentation.resultHost == .settings)
            presentation.wrappedValue = false
        }
        #expect(model.presentation.result == nil && model.presentation.resultHost == .main)
        await model.workspace.detailPreloadTask?.value
    }

    @Test(arguments: ["missing", "invalid"], [false, true])
    func reloadDoesNotInitializeWithMissingOrInvalidRecord(_ kind: String, _ implicit: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let file = fixture.service.store.recordURL(fixture.root)
        if kind == "missing" { try FileManager.default.removeItem(at: file) }
        else { try Data("broken".utf8).write(to: file) }
        try FileManager.default.removeItem(at: fixture.root.appending(path: ".git"))

        if implicit { await model.activate() } else { await model.workspace.reload() }
        #expect(model.workspace.record == nil && model.workspace.blocked != nil && model.presentation.result == nil)
        #expect(!model.busy && !model.openingWorkspace)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.root.appending(path: ".agents")))
        if kind == "missing" { #expect(!PathSafety.exists(file)) }
        else { #expect(try Data(contentsOf: file) == Data("broken".utf8)) }
    }

    @Test(arguments: [false, true])
    func reloadInitializationFailureReportsRetainedEffectsAndCanRetry(_ implicit: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let head = try await fixture.service.git.oid("HEAD", at: fixture.root)
        _ = try await fixture.service.git.run(["config", "commit.gpgSign", "true"], at: fixture.root)
        _ = try await fixture.service.git.run(["config", "gpg.program", "/usr/bin/false"], at: fixture.root)
        if implicit { await model.activate() } else { await model.workspace.reload() }
        #expect(model.workspace.record == nil && model.workspace.blocked != nil && !model.busy)
        #expect(model.presentation.result?.items.first?.reasonCode == "workspace-commit-failed")
        #expect(model.presentation.result?.items.first?.effects.contains { $0.action == "install-skill" } == true)
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head)

        _ = try await fixture.service.git.run(["config", "commit.gpgSign", "false"], at: fixture.root)
        model.presentation.dismissResult()
        if implicit { await model.activate() } else { await model.workspace.reload() }
        #expect(model.workspace.record != nil && model.workspace.blocked == nil && model.presentation.result == nil)
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) != head)
        #expect(try await fixture.service.git.changes(at: fixture.root).isEmpty)
    }

    @Test func startupPublishesWorkspaceAndToolsBeforeSlowResourceChecks() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        var record = try fixture.service.store.load(fixture.root)
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
            #expect(model.workspace.record == record && model.workspace.blocked == nil)
            #expect(model.tools.map(\.id) == ["codex"])
            try Data("changed".utf8).write(to: record.repositoryURL("repo").appending(path: "new.txt"))
            model.workspace.selection = .repository("repo")
            let detailDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.workspace.detailLoading, ContinuousClock.now < detailDeadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.workspace.detailLoading && model.workspace.detail.changes?.map(\.path) == ["new.txt"])
            #expect(model.workspace.states[Resource.repository("repo").id]?.dirty == true)
            try Data().write(to: probe.appending(path: "release"))
            #expect(await startup.value == false)
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.states[Resource.repository(other.id).id]?.available == true)
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            _ = await startup.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: ["available", "missing", "not-executable", "broken", "missing-entry", "conflicting-entry"])
    func startupChecksCLIBeforeOpeningTheSavedWorkspace(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let saved = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(saved)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        defaults.set(saved.root, forKey: "workspace")
        defaults.set(false, forKey: "sidebar.\(saved.root).repositoriesExpanded")
        let installer = try makeInstaller(fixture)
        switch kind {
        case "missing": try FileManager.default.removeItem(at: installer.executable)
        case "not-executable": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installer.executable.path)
        case "broken": try Data("#!/bin/sh\nexit 1\n".utf8).write(to: installer.executable)
        case "missing-entry": try FileManager.default.removeItem(at: fixture.directory.appending(path: ".local/bin/modu-cli"))
        case "conflicting-entry":
            let link = fixture.directory.appending(path: ".local/bin/modu-cli")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory.appending(path: "login-shell"))
        default: break
        }
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)
        var readyCount = 0

        #expect(await model.start(onReady: { readyCount += 1 }) == (kind != "available"))
        #expect(readyCount == (kind == "available" ? 1 : 0))
        #expect(model.workspace.blocked == nil && model.presentation.result == nil && !model.busy)
        #expect(defaults.string(forKey: "workspace") == saved.root)
        if kind == "available" {
            #expect(model.workspace.record == saved)
            #expect(PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)
            try FileManager.default.removeItem(at: installer.executable)
            let reopened = AppModel(defaults: defaults, service: fixture.service, installer: installer)
            #expect(await reopened.start())
            #expect(reopened.workspace.record == nil && reopened.workspace.blocked == nil && reopened.presentation.result == nil)
        } else {
            #expect(model.workspace.record == nil && model.operation == nil)
            #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
            #expect(defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)
            #expect(!PathSafety.exists(fixture.root.appending(path: "repositories")))
        }
    }

    @Test(arguments: ["cancelled", "quitting"])
    func interruptedSetupKeepsWorkspaceAndTools(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let original = try fixture.service.store.load(fixture.root)
        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        let opened = await fixture.service.openWorkspaceWithRecord(nextRoot)
        let next = try #require(opened.record)
        let tools = ExternalTools(applicationURL: { id in
            if kind == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return id == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil
        }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools)
        model.workspace.record = original
        defaults.set(original.root, forKey: "workspace")
        let previousTools = ExternalTool.builtIn.filter { $0.id == "terminal" }
        model.tools = previousTools
        model.presentation.quitPending = kind == "quitting"

        do {
            try await Task { try await model.completeSetup(nextRoot, loaded: next) }.value
            Issue.record("Expected interrupted setup to stop before publishing the workspace.")
        } catch { #expect(error is CancellationError) }
        #expect(model.workspace.record == original && model.tools == previousTools)
        #expect(defaults.string(forKey: "workspace") == original.root)
    }

    @Test(arguments: ["available", "missing-path", "conflict", "cancelled"])
    func startupPublishesWorkspaceBeforeSlowCLIPathCheck(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let record = try fixture.service.store.load(fixture.root)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let baseInstaller = try makeInstaller(fixture, resolved: kind != "missing-path")
        let probe = fixture.directory.appending(path: "cli-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let shell = fixture.directory.appending(path: "login-shell")
        try Data("""
        #!/bin/sh
        : > "$MODU_CLI_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_CLI_PROBE/release" ]; do sleep 0.02; done
        exec /bin/sh -c "$2"
        """.utf8).write(to: shell)
        var environment = baseInstaller.runner.environment
        environment["MODU_CLI_PROBE"] = probe.path
        if kind == "conflict" {
            let directory = fixture.directory.appending(path: "conflicting-bin")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: directory.appending(path: "modu-cli"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            environment["PATH"] = directory.path + ":/usr/bin:/bin"
        }
        let installer = InstallationService(support: baseInstaller.support, executable: baseInstaller.executable, runner: .init(environment: environment), home: fixture.directory, shell: shell.path)
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools, installer: installer)
        var completed = false
        var readyCount = 0
        let startup = Task {
            let needsSetup = await model.start(onReady: {
                readyCount += 1
                #expect(model.workspace.record == record && !model.busy && model.tools.map(\.id) == ["codex"])
            })
            completed = true
            return needsSetup
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while (!PathSafety.exists(probe.appending(path: "started")) || readyCount == 0 || model.workspace.record == nil || model.busy || model.tools.isEmpty), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(!completed && !model.busy && !model.openingWorkspace)
            #expect(readyCount == 1)
            #expect(model.workspace.record == record && model.workspace.blocked == nil)
            #expect(model.tools.map(\.id) == ["codex"])
            if kind == "cancelled" { startup.cancel() }
            else { try Data().write(to: probe.appending(path: "release")) }
            #expect(await startup.value == (kind == "missing-path" || kind == "conflict"))
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.record == record && model.presentation.result == nil)
            #expect(defaults.string(forKey: "workspace") == record.root)
            #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        } catch {
            startup.cancel()
            try? Data().write(to: probe.appending(path: "release"))
            _ = await startup.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func startupDoesNotReinitializeWorkspaceWhenRecordIsMissing(_ initialized: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        if initialized { #expect(await fixture.service.openWorkspace(fixture.root).status == .success) }
        else { try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)) }
        let record = fixture.service.store.recordURL(fixture.root)
        try FileManager.default.removeItem(at: record)
        let notes = fixture.root.appending(path: "notes.txt")
        try Data("keep me\n".utf8).write(to: notes)
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let head = initialized ? try await fixture.service.git.oid("HEAD", at: fixture.root) : nil
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service, installer: try makeInstaller(fixture))

        #expect(await model.start() == false)
        #expect(model.workspace.record == nil && model.workspace.blocked != nil && !model.busy)
        #expect(model.presentation.result?.items.first?.reasonCode == "configuration-missing")
        #expect(model.presentation.result?.items.allSatisfy { $0.effects.isEmpty } == true)
        #expect(defaults.string(forKey: "workspace") == fixture.root.path)
        #expect(!PathSafety.exists(record))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == entries)
        #expect(try Data(contentsOf: notes) == Data("keep me\n".utf8))
        if initialized { #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == head) }
        else { #expect(!PathSafety.exists(fixture.root.appending(path: ".git"))) }
    }

    @Test(arguments: ["invalid-record", "missing-root", "busy", "no-saved-workspace"])
    func startupSignalsReadyForWorkspaceErrorsAndSetup(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        if kind != "no-saved-workspace" {
            defaults.set(fixture.root.path, forKey: "workspace")
            try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(fixture.root).path))
        }
        if kind == "invalid-record" { try Data("invalid".utf8).write(to: fixture.service.store.recordURL(fixture.root)) }
        if kind == "missing-root" { try FileManager.default.removeItem(at: fixture.root) }
        let lease = kind == "busy" ? try fixture.service.store.lock(fixture.root) : nil
        defer { lease?.unlock() }
        let tools = ExternalTools(applicationURL: { $0 == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools, installer: try makeInstaller(fixture))
        var readyCount = 0
        let needsSetup = await model.start(onReady: {
            readyCount += 1
            #expect(model.workspace.record == nil && !model.busy && model.tools.map(\.id) == ["codex"])
            #expect((model.workspace.blocked != nil) == (kind != "no-saved-workspace"))
        })
        let expectedReadyCount = kind == "no-saved-workspace" ? 0 : 1
        #expect(needsSetup == (kind == "no-saved-workspace"))
        #expect(readyCount == expectedReadyCount)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(await model.start(onReady: { readyCount += 1 }) == false)
        #expect(readyCount == expectedReadyCount)
    }

    @Test func quittingDuringHiddenInitializationStillPresentsRetainedEffects() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let probe = fixture.directory.appending(path: "quit-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let monitor = probe.appending(path: "fsmonitor")
        try Data("""
        #!/bin/sh
        : > "$MODU_QUIT_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MODU_QUIT_PROBE/release" ]; do sleep 0.02; done
        printf 'test-token\\000/\\000'
        """.utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        for arguments in [["config", "core.fsmonitor", monitor.path], ["config", "core.fsmonitorHookVersion", "2"]] {
            _ = try await fixture.service.git.run(arguments, at: fixture.root)
        }
        let ignore = fixture.root.appending(path: ".gitignore")
        var ignoreData = try Data(contentsOf: ignore)
        ignoreData.append(Data("\n".utf8))
        try ignoreData.write(to: ignore)
        var runner = fixture.service.git.runner
        runner.environment["MODU_QUIT_PROBE"] = probe.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner))
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let tools = ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: service, toolService: tools, installer: try makeInstaller(fixture))
        let delegate = AppDelegate()
        var readyCount = 0
        delegate.start(model: model, onReady: {
            readyCount += 1
            #expect(model.presentation.quitPending && model.presentation.result != nil && model.presentation.resultHost == .main)
        }, onFinished: { _ in })
        let startup = try #require(delegate.startupTask)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(readyCount == 0 && model.busy)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            try Data().write(to: probe.appending(path: "release"))
            await startup.value
            #expect(readyCount == 1 && model.presentation.quitPending && !model.busy)
            #expect(model.presentation.result?.items.contains { !$0.effects.isEmpty } == true)
        } catch {
            try? Data().write(to: probe.appending(path: "release"))
            await startup.value
            throw error
        }
    }

    @Test func reloadRemovesDeletedDirectoriesAndTheirReferences() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        for group in ["feature", "kept"] {
            #expect(await fixture.service.createGroup(group, repositories: ["repo"], at: fixture.root).status == .success)
        }
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.expandedGroups = ["feature", "kept"]
        for resource in [Resource.member("feature", "repo"), .group("feature"), .repository("repo")] {
            var expected = try #require(model.workspace.record)
            switch resource.kind {
            case .repository:
                expected.repositories = []
                for group in expected.groups.keys { expected.groups[group]?.repositories = [] }
            case .group: expected.groups.removeValue(forKey: "feature")
            default: expected.groups["feature"]?.repositories = []
            }
            model.workspace.selection = resource
            try FileManager.default.removeItem(at: fixture.root.appending(path: resource.path))
            await model.workspace.reload()
            await model.workspace.detailPreloadTask?.value
            #expect(model.workspace.record == expected)
            #expect(try fixture.service.store.load(fixture.root) == expected)
            #expect(model.workspace.selection == nil && model.workspace.detail.summary == nil)
            #expect(model.workspace.states[resource.id] == nil && model.workspace.blocked == nil)
            #expect(model.workspace.expandedGroups == Set(expected.groups.keys))
            #expect(PathSafety.exists(expected.groupURL("kept")) && PathSafety.exists(expected.memberURL("kept", "repo")))
            #expect(try await fixture.service.git.oid("refs/heads/feature", at: fixture.root) != nil)
            #expect(try await fixture.service.git.registrations(at: fixture.root).count == 3)
            if resource.kind != .repository {
                #expect(try await fixture.service.git.oid("refs/heads/feature", at: expected.repositoryURL("repo")) != nil)
                #expect(try await fixture.service.git.registrations(at: expected.repositoryURL("repo")).count == 3)
            }
        }
        let inspection = await fixture.service.inspect(fixture.root)
        #expect(inspection.status == .success && inspection.items.allSatisfy { $0.resource.repo == nil })
    }

    @Test func workspaceEntryPointsPersistMissingResourceCleanup() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let empty = try fixture.service.store.load(fixture.root)
        var record = empty
        record.repositories = [.init(url: fixture.remoteURL)]
        record.groups["feature"] = WorktreeGroup(repositories: ["repo"])
        for entry in ["open", "inspect", "cli"] {
            try fixture.service.store.save(record)
            switch entry {
            case "open":
                let opened = await fixture.service.openWorkspaceWithRecord(fixture.root)
                #expect(opened.result.status == .success && opened.record == empty)
            case "inspect": #expect(await fixture.service.inspect(fixture.root).status == .success)
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
    }

    @Test(arguments: ["git", "file", "symlink", "permissions"])
    func unavailableDirectoriesKeepTheirConfiguration(_ kind: String) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        var record = try fixture.service.store.load(fixture.root)
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
        #expect(inspection.items.first { $0.resource == .repository("repo") }?.status == .failed)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func failedCleanupAndMissingWorkspaceDoNotOverwriteConfiguration() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        var record = try #require(model.workspace.record)
        record.repositories = [.init(url: fixture.remoteURL)]
        try fixture.service.store.save(record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))
        let failingStore = WorkspaceStore(support: fixture.service.store.support) { _, _ in throw ModuError("injected", "save failed") }
        let failing = AppModel(defaults: model.defaults, service: WorkspaceService(store: failingStore, git: fixture.service.git))
        await failing.workspace.reload()
        #expect(failing.workspace.record == nil && failing.workspace.blocked != nil)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)

        try FileManager.default.removeItem(at: fixture.root)
        await model.workspace.reload()
        #expect(model.workspace.record == nil && model.workspace.blocked != nil)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
    }

    @Test func openingWorkspacesUsesSavedRecordsAndPreservesHistory() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL, name: "Custom"), at: fixture.root).status == .success)
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == .success)
        try await fixture.prepareEmptyGroup("closed")
        model.workspace.record = try fixture.service.store.load(fixture.root)
        model.workspace.toggleGroup("feature")
        model.defaults.set(false, forKey: model.workspace.sidebarPreferenceKey("repositoriesExpanded"))
        model.defaults.set(false, forKey: model.workspace.sidebarPreferenceKey("groupsExpanded"))
        model.defaults.set("zh", forKey: "language")
        model.defaults.set("codex", forKey: "tool.Agent")
        let saved = try #require(model.workspace.record)
        let original = try Data(contentsOf: fixture.service.store.recordURL(fixture.root))

        let reopened = AppModel(defaults: model.defaults, service: fixture.service, installer: try makeInstaller(fixture))
        #expect(await reopened.start() == false)
        #expect(reopened.workspace.blocked == nil && !reopened.busy)
        #expect(reopened.workspace.expandedGroups == ["feature"])
        #expect(reopened.defaults.object(forKey: reopened.workspace.sidebarPreferenceKey("repositoriesExpanded")) as? Bool == false)
        #expect(reopened.defaults.object(forKey: reopened.workspace.sidebarPreferenceKey("groupsExpanded")) as? Bool == false)
        #expect(reopened.workspace.record?.repositories.first?.url == fixture.remoteURL)
        #expect(reopened.workspace.record == saved)
        #expect(reopened.workspace.record?.repositories.first?.name == "Custom")
        #expect(Set(reopened.workspace.record?.groups.keys ?? [:].keys) == ["feature", "closed"])

        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        reopened.changeWorkspace(nextRoot)
        await reopened.operation?.value
        #expect(reopened.workspace.record?.rootURL.path == PathSafety.canonical(nextRoot).path && reopened.presentation.result == nil)
        #expect(reopened.workspace.expandedGroups.isEmpty)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try fixture.service.store.locate(explicit: fixture.root.path, cwd: fixture.root).path == PathSafety.canonical(fixture.root).path)
        #expect(reopened.defaults.object(forKey: "sidebar.\(saved.root).repositoriesExpanded") as? Bool == false)

        reopened.changeWorkspace(fixture.root)
        await reopened.operation?.value
        #expect(reopened.workspace.record?.rootURL.path == PathSafety.canonical(fixture.root).path && reopened.presentation.result == nil)
        #expect(reopened.workspace.record?.groups["feature"]?.repositories == ["repo"])
        #expect(reopened.workspace.record?.groups["closed"]?.repositories == [])
        #expect(reopened.workspace.expandedGroups == ["feature"] && reopened.workspace.selection == nil)
        #expect(reopened.workspace.record == saved)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(PathSafety.exists(fixture.service.store.recordURL(nextRoot)))
        #expect(reopened.defaults.string(forKey: "language") == "zh")
        #expect(reopened.defaults.string(forKey: "tool.Agent") == "codex")
        #expect(try fixture.service.store.locate(explicit: nil, cwd: fixture.root.appending(path: "worktrees/feature/repo")).path == PathSafety.canonical(fixture.root).path)
        #expect(PathSafety.exists(fixture.root.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
    }

    @Test func lockedHistoryDoesNotPreventSwitchingAndIsKept() async throws {
        let fixture = try await Fixture(createRemote: false)
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
        #expect(model.workspace.record?.rootURL.path == PathSafety.canonical(next).path && model.presentation.result == nil)
        #expect(model.defaults.string(forKey: "workspace") == PathSafety.canonical(next).path)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(fixture.root)) == original)
        #expect(try Data(contentsOf: fixture.service.store.recordURL(history)) == historyRecord)
    }

    @Test(arguments: [true, false])
    func changingWorkspaceCreatesOrLoadsWithoutCLIAndPublishesOnlyWhenReady(_ cancellable: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        let next = fixture.directory.appending(path: "new-workspace")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try Data("keep me".utf8).write(to: next.appending(path: "notes.txt"))
        #expect(!PathSafety.exists(model.installer.commandLink))

        #expect(model.changeWorkspace(next, cancellable: cancellable))
        #expect(model.busy && model.openingWorkspace)
        #expect(model.operations.canCancel == cancellable)
        #expect(model.workspace.record == original)
        #expect(model.defaults.string(forKey: "workspace") == original.root)
        let opening = try #require(model.operation)
        if !cancellable {
            model.cancel(); model.requestReload()
            let delegate = AppDelegate()
            delegate.model = model
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            #expect(!model.cancelling && !opening.isCancelled && !model.presentation.quitPending)
        }
        model.changeWorkspace(fixture.root)
        await opening.value
        #expect(!model.busy && !model.openingWorkspace && model.operation == nil)
        #expect(model.workspace.record?.rootURL.path == PathSafety.canonical(next).path)
        #expect(model.defaults.string(forKey: "workspace") == PathSafety.canonical(next).path)
        #expect(model.workspace.selection == nil && model.presentation.result == nil && model.workspace.notice == nil)
        #expect(PathSafety.exists(next.appending(path: ".git")))
        #expect(PathSafety.exists(next.appending(path: ".agents/skills/modu-workflow/SKILL.md")))
        #expect(try String(contentsOf: next.appending(path: "notes.txt"), encoding: .utf8) == "keep me")

        let alias = fixture.directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: next)
        #expect(!model.changeWorkspace(alias, cancellable: false))
        #expect(!model.busy && model.operation == nil)
        model.changeWorkspace(fixture.root)
        #expect(model.operations.canCancel)
        await model.operation?.value
        #expect(model.workspace.record == original && model.presentation.result == nil)
    }

    @Test func invalidLockedAndCancelledChangesKeepTheCurrentWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        await model.workspace.reload()
        await model.workspace.detailPreloadTask?.value
        model.workspace.selection = .repository("repo")
        let oldHead = try #require(model.workspace.detail.summary?.headOID)
        let original = try #require(model.workspace.record)
        model.workspace.expandedGroups = ["expanded"]
        let next = fixture.directory.appending(path: "locked")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(next).status == .success)
        let lease = try fixture.service.store.lock(next)
        let nested = fixture.root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        for target in [next, nested, fixture.directory.appending(path: "missing")] {
            model.changeWorkspace(target)
            await model.operation?.value
            #expect(model.presentation.result != nil && model.presentation.resultHost == .settings)
            #expect(model.workspace.record == original && model.workspace.selection == .repository("repo"))
            #expect(model.defaults.string(forKey: "workspace") == original.root)
            #expect(model.workspace.detail.summary?.headOID == oldHead && model.workspace.expandedGroups == ["expanded"])
            #expect(!model.busy && !model.openingWorkspace)
            model.presentation.dismissResult()
        }
        lease.unlock()
        model.changeWorkspace(next)
        model.cancel()
        await model.operation?.value
        #expect(model.workspace.record == original && model.workspace.selection == .repository("repo"))
        #expect(model.defaults.string(forKey: "workspace") == original.root)
        #expect(!model.busy && !model.openingWorkspace)
        #expect(model.presentation.result == nil || model.presentation.result?.status == .cancelled)
    }

    @Test func failedInitializationAndFinalLoadKeepOldReferenceAndReportEffects() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let original = try #require(model.workspace.record)
        let next = fixture.directory.appending(path: "invalid-ignore")
        try FileManager.default.createDirectory(at: next.appending(path: ".gitignore"), withIntermediateDirectories: true)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace.record == original && model.defaults.string(forKey: "workspace") == original.root)
        #expect(model.presentation.result?.status == .failed)
        #expect(model.presentation.result?.items.flatMap(\.effects).contains { $0.action == "git-init" && $0.state == "applied" } == true)
        #expect(PathSafety.exists(next.appending(path: ".git")))
        model.presentation.dismissResult()

        let invalid = fixture.directory.appending(path: "corrupt-record")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data("broken".utf8).write(to: fixture.service.store.recordURL(invalid))
        do { try await model.switchTo(invalid); Issue.record("Expected invalid workspace to be rejected") }
        catch { #expect((error as? ModuError)?.code == "invalid-configuration") }
        #expect(model.workspace.record == original && model.defaults.string(forKey: "workspace") == original.root)
    }

    @Test func skillConflictDoesNotBlockSwitchOrOverwriteUserFile() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let model = try await makeModel(fixture)
        defer { model.defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let next = fixture.directory.appending(path: "skill-conflict")
        let skill = next.appending(path: ".agents/skills/modu-workflow")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: skill)
        model.changeWorkspace(next)
        await model.operation?.value
        #expect(model.workspace.record?.rootURL.path == PathSafety.canonical(next).path)
        #expect(model.workspace.notice != nil && model.presentation.result == nil && !model.busy)
        #expect(try String(contentsOf: skill, encoding: .utf8) == "user skill")
        model.workspace.notice = nil
        #expect(model.workspace.notice == nil)
    }

    @Test func switchingWorkspacesWhileLoadingKeepsTheNewWorkspace() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        var original = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        original.groups["feature"] = WorktreeGroup()
        try FileManager.default.createDirectory(at: original.groupURL("feature"), withIntermediateDirectories: true)
        try fixture.service.store.save(original)
        let nextRoot = fixture.directory.appending(path: "next-workspace")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        #expect(await fixture.service.openWorkspace(nextRoot).status == .success)
        let next = try await fixture.service.load(nextRoot)
        let suite = "ModuLoadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(original.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)

        let first = Task { await model.workspace.reload() }
        try await waitForReadLock(fixture)
        try await model.switchTo(nextRoot)
        await first.value

        #expect(model.workspace.record == next)
        #expect(model.workspace.blocked == nil)
        #expect(!model.workspace.waiting)
    }

    @Test func lockContentionCanRetryAndDoesNotBecomeAMissingWorkspace() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let record = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(record)
        let suite = "ModuLoadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        await model.workspace.reload()
        #expect(!model.hasSavedWorkspace)
        #expect(model.workspace.blocked == nil && !model.workspace.waiting)

        defaults.set(record.root, forKey: "workspace")
        let lease = try fixture.service.store.lock(fixture.root)
        await model.workspace.reload()
        #expect(model.hasSavedWorkspace && model.workspace.waiting)
        #expect(model.workspace.record == nil && model.workspace.blocked == nil)
        lease.unlock()

        await model.workspace.reload()
        #expect(model.workspace.record == record)
        #expect(!model.workspace.waiting && model.workspace.blocked == nil)
        let nextLease = try fixture.service.store.lock(fixture.root)
        await model.workspace.reload()
        #expect(model.workspace.record == record)
        #expect(model.workspace.blocked == nil)
        nextLease.unlock()

        try FileManager.default.removeItem(at: fixture.service.store.recordURL(fixture.root))
        await model.workspace.reload()
        #expect(model.workspace.record == nil && model.workspace.blocked != nil)
        #expect(!model.workspace.waiting)
    }

    private func makeModel(_ fixture: Fixture) async throws -> AppModel {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = try fixture.service.store.load(fixture.root)
        defaults.set(model.workspace.record?.root, forKey: "workspace")
        return model
    }

    private func makeInstaller(_ fixture: Fixture, resolved: Bool = true) throws -> InstallationService {
        let shell = fixture.directory.appending(path: "login-shell")
        try Data("#!/bin/sh\nexec /bin/sh -c \"$2\"\n".utf8).write(to: shell)
        let executable = fixture.directory.appending(path: "Modu.app/Contents/Resources/modu-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '\(ModuVersion.current)\\n'\n".utf8).write(to: executable)
        for file in [shell, executable] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let link = fixture.directory.appending(path: ".local/bin/modu-cli")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !PathSafety.exists(link) { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable) }
        var environment = fixture.service.git.runner.environment
        environment["PATH"] = (resolved ? link.deletingLastPathComponent().path + ":" : "") + "/usr/bin:/bin"
        return InstallationService(support: fixture.service.store.support, executable: executable, runner: .init(environment: environment), home: fixture.directory, shell: shell.path)
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

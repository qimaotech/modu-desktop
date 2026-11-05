import Foundation
import Testing
@testable import MonoDeckCore
@testable import MonoDeck

@MainActor struct SetupModelTests {
    @Test func selectionDoesNotAccessWorkspaceUntilContinue() async throws {
        let fixture = try await Fixture(template: .emptyWorkspace); defer { fixture.remove() }
        let suite = fixture.directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trace = fixture.directory.appending(path: "setup-git-trace")
        var git = fixture.service.git
        git.runner.environment["GIT_TRACE"] = trace.path
        let model = AppModel(defaults: defaults, service: WorkspaceService(store: fixture.service.store, git: git), installer: try fixture.makeCLIInstaller())
        let setup = SetupModel(model: model)
        await setup.check()
        let recordURL = fixture.service.store.recordURL(fixture.root)
        let original = try Data(contentsOf: recordURL)
        var gate = try ReloadValidationGate(fixture.root)
        setup.selectWorkspace(fixture.root)
        #expect(setup.selectedWorkspace == fixture.root.standardizedFileURL && setup.error == nil && !setup.working)
        #expect(!PathSafety.exists(trace) && model.operation == nil)
        #expect(try Data(contentsOf: recordURL) == original)
        var ready = false
        setup.continueSetup { ready = true }
        let opening = try #require(model.operation)
        do {
            try await gate.waitUntilStarted()
            #expect(!ready && setup.working && setup.settingUp && model.busy)
            #expect(!setup.canSelectWorkspace && !setup.canContinueSetup)
            setup.selectWorkspace(fixture.directory.appending(path: "another-workspace"))
            #expect(setup.selectedWorkspace == fixture.root.standardizedFileURL)
            try gate.resume()
            await opening.value
            #expect(ready && !setup.working && !setup.settingUp && setup.error == nil)
            #expect(PathSafety.exists(trace))
            await model.workspace.detailPreloadTask?.value
        } catch {
            opening.cancel()
            try gate.resume()
            await opening.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func continueUsesCurrentResourcesOrExistingRegistration(_ recordAppeared: Bool) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        try await fixture.prepareGroup("feature", repositoryIDs: ["repo"])
        let suite = fixture.directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())
        let setup = SetupModel(model: model)
        await setup.check()
        let file = fixture.service.store.recordURL(fixture.root)
        try FileManager.default.removeItem(at: file)
        setup.selectWorkspace(fixture.root)
        #expect(setup.selectedWorkspace == fixture.root.standardizedFileURL && setup.error == nil && !setup.working)
        #expect(!PathSafety.exists(file))
        if recordAppeared {
            try fixture.service.store.save(WorkspaceRecord(root: PathSafety.canonical(fixture.root).path))
        } else {
            _ = try await fixture.service.git.run(["worktree", "add", "-b", "late", fixture.root.appending(path: "worktrees/late").path], at: fixture.root)
        }
        var ready = false
        setup.continueSetup { ready = true }
        await (try #require(model.operation)).value
        #expect(ready && !setup.working && setup.error == nil)
        let record = try #require(model.workspace.record)
        #expect(Set(record.groups.keys) == (recordAppeared ? [] : ["feature", "late"]))
        #expect(record.repositories.map(\.id) == (recordAppeared ? [] : ["repo"]))
        #expect(try fixture.service.store.load(fixture.root) == record)
        await model.workspace.detailPreloadTask?.value
    }

    @Test(arguments: ["missing-directory", "corrupt-record"])
    func continueReportsInvalidSelectionWithoutOverwritingData(_ kind: String) async throws {
        let fixture = try await Fixture(template: .singleRepository); defer { fixture.remove() }
        let suite = fixture.directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())
        let setup = SetupModel(model: model)
        await setup.check()
        let root = kind == "missing-directory" ? fixture.directory.appending(path: "missing") : fixture.root
        let file = fixture.service.store.recordURL(root)
        if kind == "corrupt-record" { try Data("invalid record".utf8).write(to: file) }
        let original = PathSafety.exists(file) ? try Data(contentsOf: file) : nil
        setup.selectWorkspace(root)
        #expect(setup.error == nil && !setup.working && model.operation == nil)
        var ready = false
        setup.continueSetup { ready = true }
        await (try #require(model.operation)).value
        #expect(!ready && !setup.working && !setup.settingUp && setup.error != nil)
        #expect(setup.selectedWorkspace == root.standardizedFileURL && model.workspace.record == nil)
        #expect((PathSafety.exists(file) ? try Data(contentsOf: file) : nil) == original)
        if kind == "missing-directory" { #expect(!PathSafety.exists(root)) }
        setup.selectWorkspace(fixture.root)
        #expect(setup.error == nil && setup.errorDetails == nil && !setup.skillConflict)
    }

    @Test func setupPreservesConflictingSkillAndCanCompleteOnRetry() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let suite = fixture.directory.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ExternalTools(applicationURL: { id in
            id == "com.openai.codex" ? fixture.directory.appending(path: "Codex.app") : nil
        }, openURL: { _, _ in })
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools, installer: try fixture.makeCLIInstaller())
        let setup = SetupModel(model: model)
        await setup.check()
        let skill = fixture.root.appending(path: ".agents/skills/mono-deck-workflow")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: skill)
        setup.selectWorkspace(fixture.root)
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
        #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
        var ready = false
        let onReady: @MainActor () -> Void = {
            ready = true
        }
        setup.continueSetup(onReady: onReady)
        let operation = try #require(model.operation)
        #expect(model.busy && model.operations.kind == .setup && setup.settingUp)
        await operation.value
        #expect(!model.busy && model.operation == nil && !setup.working && !setup.settingUp)
        #expect(!ready && model.workspace.record == nil && setup.skillConflict && setup.error != nil)
        #expect(try String(contentsOf: skill, encoding: .utf8) == "user skill")
        setup.continueSetup(onReady: onReady)
        await (try #require(model.operation)).value
        #expect(ready && model.workspace.record?.root == fixture.root.path && model.hasSavedWorkspace)
        #expect(model.tools.map(\.id) == ["codex"])
        #expect(model.presentation.resultHost == .main && model.presentation.result == nil && !model.busy)
        await model.workspace.detailPreloadTask?.value
    }

    @Test(arguments: [false, true])
    func selectionSurvivesCLIChecksAndRetries(_ available: Bool) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let baseInstaller = try fixture.makeCLIInstaller(resolved: available)
        let probe = fixture.directory.appending(path: "cli-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let shell = fixture.directory.appending(path: "login-shell")
        try Data("""
        #!/bin/sh
        : > "$MONO_DECK_CLI_PROBE/started"
        trap 'exit 143' TERM INT
        while [ ! -e "$MONO_DECK_CLI_PROBE/release" ]; do sleep 0.02; done
        exec /bin/sh -c "$2"
        """.utf8).write(to: shell)
        var environment = baseInstaller.runner.environment
        environment["MONO_DECK_CLI_PROBE"] = probe.path
        let installer = InstallationService(support: baseInstaller.support, executable: baseInstaller.executable, runner: .init(environment: environment), home: fixture.directory, shell: shell.path)
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)
        let setup = SetupModel(model: model)
        setup.selectWorkspace(fixture.root)
        setup.continueSetup { Issue.record("Expected CLI readiness before opening the workspace.") }
        #expect(setup.canSelectWorkspace && !setup.canContinueSetup && model.operation == nil)
        let checking = Task { await setup.check() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(probe.appending(path: "started")), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(PathSafety.exists(probe.appending(path: "started")))
            #expect(setup.selectedWorkspace == fixture.root.standardizedFileURL && setup.canSelectWorkspace)
            let next = fixture.directory.appending(path: "next-workspace")
            setup.selectWorkspace(next)
            setup.continueSetup { Issue.record("Expected the CLI check to finish before opening the workspace.") }
            #expect(setup.selectedWorkspace == next && !setup.canContinueSetup && model.operation == nil)
            try Data().write(to: probe.appending(path: "release"))
            await checking.value
            #expect(setup.selectedWorkspace == next && setup.cliReady == available && setup.canSelectWorkspace)
            #expect(setup.canContinueSetup == available)
            await setup.check()
            setup.windowClosed()
            await setup.check()
            #expect(setup.selectedWorkspace == next && setup.cliReady == available)
            if !available {
                setup.continueSetup { Issue.record("Expected an unavailable CLI to block setup.") }
                #expect(model.operation == nil && !setup.settingUp)
            }
            #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
            #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
        } catch {
            checking.cancel()
            try? Data().write(to: probe.appending(path: "release"))
            await checking.value
            throw error
        }
    }

    @Test func selectionResetsOnlyWhenWorkspaceContextChanges() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service, installer: try fixture.makeCLIInstaller())
        let setup = SetupModel(model: model)
        let candidate = fixture.directory.appending(path: "candidate")
        setup.selectWorkspace(candidate)
        await setup.check()
        setup.windowClosed()
        await setup.check()
        #expect(setup.selectedWorkspace == candidate && setup.canContinueSetup)
        let next = fixture.directory.appending(path: "next-workspace")
        defaults.set(next.path, forKey: "workspace")
        #expect(!setup.canContinueSetup)
        await setup.check()
        #expect(setup.selectedWorkspace == next && setup.isPreparedForCurrentWorkspace)
        defaults.removeObject(forKey: "workspace")
        await setup.check()
        #expect(setup.selectedWorkspace == nil && !setup.canContinueSetup)
        #expect(!PathSafety.exists(fixture.service.store.recordURL(fixture.root)))
    }

    @Test(arguments: ["check", "install"])
    func cliFailuresAndWorkspaceErrorsRemainIndependent(_ operation: String) async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let installer = try fixture.makeCLIInstaller()
        let model = AppModel(defaults: defaults, service: fixture.service, installer: installer)
        let setup = SetupModel(model: model)
        await setup.check()
        let missing = fixture.directory.appending(path: "missing-workspace")
        setup.selectWorkspace(missing)
        setup.continueSetup { Issue.record("Expected the missing workspace to fail setup.") }
        await (try #require(model.operation)).value
        let workspaceError = try #require(setup.error)
        let workspaceDetails = setup.errorDetails
        try FileManager.default.removeItem(at: installer.commandLink)
        if operation == "check" {
            setup.windowClosed()
            await setup.check()
        } else {
            try Data("user command".utf8).write(to: installer.commandLink)
            setup.install()
            #expect(!setup.canSelectWorkspace && !setup.canContinueSetup)
            setup.selectWorkspace(fixture.root)
            #expect(setup.selectedWorkspace == missing)
            await (try #require(model.operation)).value
            #expect(try String(contentsOf: installer.commandLink, encoding: .utf8) == "user command")
        }
        #expect(!setup.cliReady && !setup.cliMessage.isEmpty && setup.cliUserMessage != nil)
        #expect(setup.error == workspaceError && setup.errorDetails == workspaceDetails)
        if operation == "check" {
            _ = try fixture.makeCLIInstaller()
            setup.windowClosed()
            await setup.check()
            #expect(setup.cliReady && setup.error == workspaceError && setup.errorDetails == workspaceDetails)
        }
        let cliMessage = setup.cliMessage
        let cliUserMessage = setup.cliUserMessage
        setup.selectWorkspace(fixture.root)
        #expect(setup.error == nil && setup.errorDetails == nil && !setup.skillConflict)
        #expect(setup.cliMessage == cliMessage && setup.cliUserMessage == cliUserMessage)
        if operation == "install" {
            try FileManager.default.removeItem(at: installer.commandLink)
            setup.install()
            await (try #require(model.operation)).value
            #expect(setup.cliReady && setup.canContinueSetup && setup.error == nil)
            #expect(setup.selectedWorkspace == fixture.root.standardizedFileURL)
        }
        #expect(!PathSafety.exists(fixture.root.appending(path: ".git")))
    }
}

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
        let model = AppModel(defaults: defaults, service: WorkspaceService(store: fixture.service.store, git: git))
        let setup = SetupModel(model: model)
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
        let model = AppModel(defaults: defaults, service: fixture.service)
        let setup = SetupModel(model: model)
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
        let model = AppModel(defaults: defaults, service: fixture.service)
        let setup = SetupModel(model: model)
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
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: tools)
        let setup = SetupModel(model: model)
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
}

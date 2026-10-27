import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct SetupModelTests {
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
        let skill = fixture.root.appending(path: ".agents/skills/modu-workflow")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: skill)
        await setup.checkCandidate(fixture.root)
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

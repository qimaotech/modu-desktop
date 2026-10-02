#if DEBUG
import Foundation
import ModuCore

final class MockWorkspace {
    enum Scenario: String { case linkedWorktreeSelected = "linked-worktree-selected" }

    let fixture: MockWorkspaceFixture
    var directory: URL { fixture.directory }
    let defaults: UserDefaults
    let initialSelection = Resource.member("feature-store-pickup", "order-service")
    private let suite: String

    init(scenario: Scenario, workspace: URL) throws {
        let fixture = try MockWorkspaceFixture(workspace: workspace)
        self.fixture = fixture
        suite = "ModuMock.\(fixture.identifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ModuError("mock-unavailable", "Could not create mock preferences.")
        }
        self.defaults = defaults
        defaults.set(fixture.root.path, forKey: "workspace")
        defaults.set("en", forKey: "language")
        for tool in ExternalTool.builtIn where ["codex", "fork", "vscode", "terminal"].contains(tool.id) { defaults.set(tool.id, forKey: "tool.\(tool.category)") }
    }

    func makeModel(toolService: ExternalTools? = nil) -> AppModel {
        let model = AppModel(defaults: defaults, service: fixture.service, toolService: toolService,
                             installer: InstallationService(support: fixture.service.store.support, runner: fixture.service.git.runner,
                                                            home: directory.appending(path: "home"), shell: "/bin/sh", shellArguments: ["-c"],
                                                            directoryBoundary: directory))
        model.mockWorkspace = self
        return model
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        fixture.remove()
    }
}
#endif

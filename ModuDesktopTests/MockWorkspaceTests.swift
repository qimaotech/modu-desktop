#if DEBUG
import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct MockWorkspaceTests {
    @Test func mockLaunchLoadsPreparedRepositoriesWithoutCLI() async throws {
        let fixture = try await MockWorkspacePreparation.prepare()
        defer { fixture.remove() }
        let model = try AppModel.makeForLaunch(arguments: ["Modu", "--mock", "linked-worktree-selected", "--mock-workspace", fixture.root.path])
        let mock = try #require(model.mockWorkspace)
        defer { mock.remove() }
        var readySelection: Resource?
        let needsSetup = await model.start { readySelection = model.selection }
        await model.detailPreloadTask?.value
        let record = try #require(model.workspace)
        #expect(!needsSetup && model.started && model.hasSavedWorkspace && model.blocked == nil)
        #expect(readySelection == mock.initialSelection && model.selection == mock.initialSelection)
        #expect(record.rootURL.lastPathComponent == "example-workspace")
        #expect(record.repositories.count == 7 && model.sortedGroups == ["feature-store-pickup", "fix-overselling"])
        #expect(model.expandedGroups == Set(model.sortedGroups))
        #expect(model.detail.summary?.base == "origin/main" && model.detail.summary?.head == "feature-store-pickup")
        #expect(model.detail.changes == Self.orderChanges)
        #expect(model.detail.commits?.map(\.subject) == Self.commitSubjects)
        #expect(try model.service.store.load(record.rootURL) == record)
        #expect(try await model.service.git.registrations(at: record.rootURL).count == 3)
        let resources = model.service.resources(record)
        #expect(resources.allSatisfy { record.rootURL.appending(path: $0.path).path.hasPrefix(mock.directory.path + "/") })
        for path in [record.rootURL, record.repositoryURL("order-service"), record.memberURL("feature-store-pickup", "order-service")] {
            #expect(try await model.service.git.run(["config", "--local", "--get", "include.path"], at: path).text == mock.directory.appending(path: "gitconfig").path)
        }
        #expect(resources.count == 17)
        #expect(resources.allSatisfy { model.states[$0.id]?.available == true })
        #expect(model.states.values.filter { $0.dirty == true }.count == 2)
        #expect(model.language == "en" && !model.detailLoading && model.operation == nil)
        #expect(!(await model.installer.checkCLIInstallation()).available)
        #expect(try await model.service.git.run(["config", "--get", "protocol.allow"], at: record.rootURL).text == "never")
        let remote = try #require(record.repositories.first)
        #expect(try await model.service.git.run(["ls-remote", "--symref", "--", remote.url, "HEAD"], at: record.rootURL).text.contains("refs/heads/main"))
    }

    @Test func repositoryChangesStayInsideMockEnvironment() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        let service = mock.fixture.service
        let original = try service.store.load(mock.fixture.root)
        let removed = await service.remove(.repository("catalog-service"), at: original.rootURL, execute: true)
        #expect(removed.status == "success")
        #expect(!PathSafety.exists(original.repositoryURL("catalog-service")))
        let trashed = try FileManager.default.contentsOfDirectory(at: mock.directory.appending(path: "trash"), includingPropertiesForKeys: nil)
        #expect(trashed.count == 1 && PathSafety.exists(trashed[0].appending(path: ".git")))

        let added = await service.addRepository(.init(url: "https://example.invalid/catalog-service.git"), at: original.rootURL)
        #expect(added.status == "success")
        let restored = try service.store.load(original.rootURL)
        #expect(restored.repositories.sorted { $0.id < $1.id } == original.repositories.sorted { $0.id < $1.id })
        #expect(restored.root == original.root && restored.groups == original.groups)
        #expect(try await service.git.run(["config", "--local", "--get", "include.path"], at: original.repositoryURL("catalog-service")).text == mock.directory.appending(path: "gitconfig").path)
        let bytes = try Data(contentsOf: service.store.recordURL(original.rootURL))
        let rejected = await service.addRepository(.init(url: "https://unmapped.invalid/extra.git"), at: original.rootURL)
        #expect(rejected.status == "failed" && rejected.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(original.repositoryURL("extra")))
        #expect(try Data(contentsOf: service.store.recordURL(original.rootURL)) == bytes)
        #expect(service.git.runner.environment["GIT_ALLOW_PROTOCOL"] == "file")
    }

    @Test func setupCLIAndPreferencesStayInTheTemporaryEnvironment() async throws {
        let savedWorkspace = UserDefaults.standard.string(forKey: "workspace")
        let savedLanguage = UserDefaults.standard.string(forKey: "language")
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        let source = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        #expect(try await model.installer.installCLI(from: source).available)
        #expect(await model.installer.checkCLI().available)
        #expect(model.installer.executable.path.hasPrefix(mock.directory.path + "/"))
        let link = mock.directory.appending(path: "home/.local/bin/modu-cli")
        #expect(PathSafety.canonical(link) == model.installer.executable)
        model.language = "zh"
        #expect(mock.defaults.string(forKey: "language") == "zh")
        #expect(UserDefaults.standard.string(forKey: "workspace") == savedWorkspace)
        #expect(UserDefaults.standard.string(forKey: "language") == savedLanguage)
        mock.remove()
        #expect(!PathSafety.exists(mock.directory) && mock.defaults.string(forKey: "workspace") == nil)
    }

    @Test func directoryBoundaryRejectsOtherSessionsSymlinksAndReloads() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        let other = try await Fixture()
        defer { other.remove() }
        let original = WorkspaceRecord(root: PathSafety.canonical(other.root).path)
        try other.service.store.save(original)
        let originalFile = other.service.store.recordURL(original.rootURL)
        let originalBytes = try Data(contentsOf: originalFile)
        let remote = other.directory.appending(path: "repo.git")
        let remoteHead = try Data(contentsOf: remote.appending(path: "HEAD"))
        try FileManager.default.createDirectory(at: other.directory.appending(path: "home"), withIntermediateDirectories: false)
        let model = mock.makeModel()
        let record = try model.service.store.load(mock.fixture.root)
        model.workspace = record
        let alias = mock.directory.appending(path: "outside")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other.root)
        for target in [other.root, alias] {
            do { _ = try await model.service.candidate(target); Issue.record("Outside candidate should be rejected.") }
            catch { #expect((error as? ModuError)?.code == "unsafe-path") }
            let opened = await model.service.openWorkspaceWithRecord(target, installer: model.installer)
            #expect(opened.result.items.first?.reasonCode == "unsafe-path")
            do { try await model.switchTo(target, loaded: original); Issue.record("Outside switch should be rejected.") }
            catch { #expect((error as? ModuError)?.code == "unsafe-path") }
            let deletion = await model.service.remove(.repository("catalog-service"), at: target, execute: true)
            #expect(deletion.reasonCode == "unsafe-path")
        }
        let similar = mock.directory.appendingPathExtension("outside")
        try FileManager.default.createDirectory(at: similar, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: similar) }
        for destination in [other.directory.appending(path: "export.yaml"), alias.appending(path: "export.yaml"), similar.appending(path: "export.yaml")] {
            do { try await model.service.exportYAML(at: record.rootURL, to: destination); Issue.record("Outside export should be rejected.") }
            catch { #expect((error as? ModuError)?.code == "unsafe-path") }
            #expect(!PathSafety.exists(destination))
        }
        let export = mock.directory.appending(path: "workspace.yaml")
        try await model.service.exportYAML(at: record.rootURL, to: export)
        let inwardLink = other.directory.appending(path: "inward.yaml")
        try FileManager.default.createSymbolicLink(at: inwardLink, withDestinationURL: export)
        do { try await model.service.exportYAML(at: record.rootURL, to: inwardLink); Issue.record("Outside symlink should be kept.") }
        catch { #expect((error as? ModuError)?.code == "unsafe-path") }
        #expect(try FileManager.default.attributesOfItem(atPath: inwardLink.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        let source = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        let cliDirectory = mock.directory.appending(path: "home/.local")
        try FileManager.default.createSymbolicLink(at: cliDirectory, withDestinationURL: other.directory.appending(path: "home"))
        do { _ = try await model.installer.installCLI(from: source); Issue.record("Outside CLI install should be rejected.") }
        catch { #expect((error as? ModuError)?.code == "unsafe-path") }
        #expect(!PathSafety.exists(other.directory.appending(path: "home/bin/modu-cli")))
        #expect(throws: ModuError.self) { try model.service.store.save(original) }
        let remoteLink = mock.directory.appending(path: "remotes/outside.git")
        try FileManager.default.createSymbolicLink(at: remoteLink, withDestinationURL: remote)
        let added = await model.service.addRepository(.init(url: "https://example.invalid/outside.git"), at: record.rootURL)
        #expect(added.status == "failed" && added.items.first?.reasonCode == "unsafe-path")
        #expect(model.workspace == record)
        #expect(!PathSafety.exists(record.repositoryURL("outside")))
        model.defaults.set(other.root.path, forKey: "workspace")
        await model.reload()
        #expect(model.workspace == nil && model.blocked != nil)
        #expect(try Data(contentsOf: originalFile) == originalBytes)
        #expect(try other.service.store.load(original.rootURL) == original)
        #expect(try Data(contentsOf: remote.appending(path: "HEAD")) == remoteHead)
    }

    @Test func failedPreparedWorkspaceLoadDoesNotRegenerateData() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        try FileManager.default.removeItem(at: mock.fixture.service.store.recordURL(mock.fixture.root))
        let model = mock.makeModel()
        var ready = false
        #expect(!(await model.start { ready = true }))
        #expect(ready && model.hasSavedWorkspace && model.blocked != nil)
        #expect(model.workspace == nil && model.selection == nil)
        #expect(!PathSafety.exists(mock.directory))
    }

    @Test(arguments: [["Modu", "--mock"], ["Modu", "--mock", "unknown"], ["Modu", "--mock", "linked-worktree-selected"],
                      ["Modu", "--mock", "linked-worktree-selected", "--mock", "linked-worktree-selected"], ["Modu", "--mock-workspace", "/tmp"]])
    func invalidScenariosAreRejectedBeforeNormalStartup(_ arguments: [String]) {
        #expect(throws: ModuError.self) { try AppModel.makeForLaunch(arguments: arguments) }
    }

    @Test func launchWithoutMockKeepsNormalModel() throws {
        let model = try AppModel.makeForLaunch(arguments: ["Modu"])
        #expect(model.mockWorkspace == nil)
        #expect(model.service.store.directoryBoundary == nil)
        #expect(model.workspace == nil && model.selection == nil && !model.started)
    }

    private func makeMock() async throws -> MockWorkspace {
        let fixture = try await MockWorkspacePreparation.prepare()
        do { return try MockWorkspace(scenario: .linkedWorktreeSelected, workspace: fixture.root) }
        catch { fixture.remove(); throw error }
    }

    private static let commitSubjects = ["test(order): cover pickup fulfillment rules", "feat(order): validate pickup eligibility", "feat(order): add pickup fulfillment type"]
    private static let orderChanges = [
        FileChange(path: "internal/order/application/create_pickup_order.go", index: "A", workingTree: " "),
        FileChange(path: "internal/order/domain/order.go", index: " ", workingTree: "M"),
        FileChange(path: "internal/order/domain/pickup.go", index: "A", workingTree: " "),
        FileChange(path: "internal/order/infrastructure/persistence/legacy_pickup_repository.go", index: " ", workingTree: "D"),
        FileChange(path: "internal/order/interfaces/http/pickup_handler.go", originalPath: "internal/order/interfaces/http/order_handler.go", index: "R", workingTree: " ")
    ]
}
#endif

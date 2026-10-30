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
        let needsSetup = await model.start { readySelection = model.workspace.selection }
        await model.workspace.detailPreloadTask?.value
        let record = try #require(model.workspace.record)
        #expect(!needsSetup && model.started && model.workspace.blocked == nil)
        #expect(readySelection == mock.initialSelection && model.workspace.selection == mock.initialSelection)
        #expect(model.workspace.detail.changes?.isEmpty == false && model.workspace.detail.commits?.isEmpty == false)
        #expect(model.workspace.detail.commits?.count == 3)
        let behind = try #require(model.workspace.detail.behindCommits)
        #expect(behind.count == 36)
        #expect(behind.prefix(3).allSatisfy { $0.subject.count > 100 })
        let resources = model.service.resources(record)
        #expect(resources.allSatisfy { record.rootURL.appending(path: $0.path).path.hasPrefix(mock.directory.path + "/") })
        for path in [record.rootURL, record.repositoryURL("order-service"), record.memberURL("feature-store-pickup", "order-service")] {
            #expect(try await model.service.git.run(["config", "--local", "--get", "include.path"], at: path).text == mock.directory.appending(path: "gitconfig").path)
        }
        #expect(resources.allSatisfy { model.workspace.states[$0.id]?.available == true })
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
        #expect(removed.status == .success)
        #expect(!PathSafety.exists(original.repositoryURL("catalog-service")))
        let trashed = try FileManager.default.contentsOfDirectory(at: mock.directory.appending(path: "trash"), includingPropertiesForKeys: nil)
        #expect(trashed.count == 1 && PathSafety.exists(trashed[0].appending(path: ".git")))

        let added = await service.addRepository(.init(url: "https://example.invalid/catalog-service.git"), at: original.rootURL)
        #expect(added.status == .success)
        #expect(PathSafety.exists(original.repositoryURL("catalog-service")))
        #expect(try await service.git.run(["config", "--local", "--get", "include.path"], at: original.repositoryURL("catalog-service")).text == mock.directory.appending(path: "gitconfig").path)
        let bytes = try Data(contentsOf: service.store.recordURL(original.rootURL))
        let rejected = await service.addRepository(.init(url: "https://unmapped.invalid/extra.git"), at: original.rootURL)
        #expect(rejected.status == .failed && rejected.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(original.repositoryURL("extra")))
        #expect(try Data(contentsOf: service.store.recordURL(original.rootURL)) == bytes)
        #expect(service.git.runner.environment["GIT_ALLOW_PROTOCOL"] == "file")
    }

    @Test func setupCLIAndPreferencesStayInTheTemporaryEnvironment() async throws {
        let savedWorkspace = UserDefaults.standard.string(forKey: "workspace")
        let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        let source = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        let sourceBytes = try Data(contentsOf: source)
        #expect(try await model.installer.installCLI().available)
        #expect(await model.installer.checkCLI().available)
        #expect(try Data(contentsOf: source) == sourceBytes)
        let link = mock.directory.appending(path: "home/.local/bin/modu-cli")
        #expect(PathSafety.canonical(link) == PathSafety.canonical(model.installer.executable))
        model.appLanguage = .simplifiedChinese
        #expect(mock.defaults.string(forKey: "appLanguage") == "zh_CN")
        let reopened = try MockWorkspace(scenario: .linkedWorktreeSelected, workspace: mock.fixture.root)
        #expect(reopened.defaults.string(forKey: "appLanguage") == "zh_CN")
        model.workspace.record = try await mock.fixture.load()
        model.workspace.selection = .repository("catalog-service")
        model.workspace.expandedGroups = []
        await model.workspace.details.detailTask?.value
        await model.workspace.detailPreloadTask?.value
        let restored = reopened.makeModel()
        #expect(restored.preferences.activeLocale == .simplifiedChinese)
        #expect(!(await restored.start()))
        #expect(restored.workspace.selection == .repository("catalog-service") && restored.workspace.expandedGroups.isEmpty)
        restored.workspace.selection = nil
        await restored.workspace.detailPreloadTask?.value
        let welcome = try MockWorkspace(scenario: .linkedWorktreeSelected, workspace: mock.fixture.root).makeModel()
        #expect(!(await welcome.start()))
        #expect(welcome.workspace.selection == nil && welcome.workspace.expandedGroups.isEmpty)
        await welcome.workspace.detailPreloadTask?.value
        #expect(UserDefaults.standard.string(forKey: "workspace") == savedWorkspace)
        #expect(UserDefaults.standard.string(forKey: "appLanguage") == savedLanguage)
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
        model.workspace.record = record
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
        let cliDirectory = mock.directory.appending(path: "home/.local")
        try FileManager.default.createSymbolicLink(at: cliDirectory, withDestinationURL: other.directory.appending(path: "home"))
        do { _ = try await model.installer.installCLI(); Issue.record("Outside CLI install should be rejected.") }
        catch { #expect((error as? ModuError)?.code == "unsafe-path") }
        #expect(!PathSafety.exists(other.directory.appending(path: "home/bin/modu-cli")))
        #expect(throws: ModuError.self) { try model.service.store.save(original) }
        let remoteLink = mock.directory.appending(path: "remotes/outside.git")
        try FileManager.default.createSymbolicLink(at: remoteLink, withDestinationURL: remote)
        let added = await model.service.addRepository(.init(url: "https://example.invalid/outside.git"), at: record.rootURL)
        #expect(added.status == .failed && added.items.first?.reasonCode == "unsafe-path")
        #expect(model.workspace.record == record)
        #expect(!PathSafety.exists(record.repositoryURL("outside")))
        model.defaults.set(other.root.path, forKey: "workspace")
        await model.workspace.reload()
        #expect(model.workspace.record == nil && model.workspace.blocked != nil)
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
        #expect(ready && model.hasSavedWorkspace && model.workspace.blocked != nil)
        #expect(model.workspace.record == nil && model.workspace.selection == nil)
        #expect(!PathSafety.exists(mock.directory))
    }

    private func makeMock() async throws -> MockWorkspace {
        let fixture = try await MockWorkspacePreparation.prepare()
        do { return try MockWorkspace(scenario: .linkedWorktreeSelected, workspace: fixture.root) }
        catch { fixture.remove(); throw error }
    }
}
#endif

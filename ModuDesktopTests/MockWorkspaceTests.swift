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
        #expect(record.groups.values.allSatisfy { $0.createdAt == "2026-08-30T00:00:00Z" })
        #expect(model.detail.summary?.base == "origin/main" && model.detail.summary?.head == "feature-store-pickup")
        #expect(model.detail.changes == Self.orderChanges)
        #expect(model.detail.commits?.map(\.subject) == Self.commitSubjects)
        #expect(model.detail.commits?.allSatisfy { $0.author == "Jamie Lee" && $0.id.count == 40 } == true)
        let dates = ["2026-08-30T08:18:00Z", "2026-08-30T06:42:00Z", "2026-08-30T03:07:00Z"]
        #expect(model.detail.commits?.map { ISO8601DateFormatter().date(from: $0.date) } == dates.map { ISO8601DateFormatter().date(from: $0) })
        #expect(try model.service.store.load(record.rootURL) == record)
        #expect(try await model.service.git.registrations(at: record.rootURL).count == 3)
        for resource in model.service.resources(record) {
            let path = try await model.service.checked(resource, in: record)
            #expect(path.path.hasPrefix(mock.directory.path + "/"))
            #expect(try await model.service.git.run(["config", "--local", "--get", "include.path"], at: path).text == mock.directory.appending(path: "gitconfig").path)
            let summary = try await model.service.git.summary(at: path)
            #expect(summary.head == (resource.group ?? "main"))
            #expect(summary.hasRemotes == (resource.kind != "group"))
        }
        let member = record.memberURL("feature-store-pickup", "order-service")
        #expect(try String(contentsOf: member.appending(path: "internal/order/application/create_pickup_order.go"), encoding: .utf8).contains("CreatePickupOrder"))
        #expect(!PathSafety.exists(member.appending(path: "internal/order/infrastructure/persistence/legacy_pickup_repository.go")))
        #expect(!PathSafety.exists(member.appending(path: "internal/order/interfaces/http/order_handler.go")))
        #expect(PathSafety.exists(member.appending(path: "internal/order/interfaces/http/pickup_handler.go")))
        #expect(model.service.resources(record).count == 17)
        #expect(model.service.resources(record).allSatisfy { model.states[$0.id]?.available == true })
        #expect(model.states.values.filter { $0.dirty == true }.count == 2)
        #expect(model.language == "en" && !model.detailLoading && model.operation == nil)
        #expect(!(await model.installer.checkCLIInstallation()).available)
        #expect(try await model.service.git.run(["config", "--get", "protocol.allow"], at: record.rootURL).text == "never")
        let remote = try #require(record.repositories.first)
        #expect(try await model.service.git.run(["ls-remote", "--symref", "--", remote.url, "HEAD"], at: record.rootURL).text.contains("refs/heads/main"))
    }

    @Test func refreshActivationAndSidebarReadChangesFromDisk() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        _ = await model.start()
        await model.detailPreloadTask?.value
        let record = try #require(model.workspace)
        let member = record.memberURL("feature-store-pickup", "order-service")
        try Data("Written outside Modu.\n".utf8).write(to: member.appending(path: "notes.txt"))
        model.refreshDetail()
        try await waitForDetail(model)
        #expect(model.detail.changes?.first { $0.path == "notes.txt" }?.workingTree == "?")
        #expect(model.detail.changes?.count == 6)
        _ = try await model.service.git.run(["add", "--", "notes.txt"], at: member)
        _ = try await model.service.git.run(["commit", "-m", "docs: add local notes", "--", "notes.txt"], at: member)
        await model.reload()
        #expect(model.detail.changes == Self.orderChanges)
        #expect(model.detail.commits?.first?.subject == "docs: add local notes")
        _ = try await model.service.git.run(["switch", "-c", "pickup-preview"], at: member)
        await model.activate()
        #expect(model.selection == mock.initialSelection && model.detail.summary?.head == "pickup-preview")
        model.selectSidebarRow(.member("feature-store-pickup", "storefront-web"))
        try await waitForDetail(model)
        #expect(model.detail.changes?.map(\.path) == ["src/pickup.ts"])
        let readme = record.memberURL("feature-store-pickup", "storefront-web").appending(path: "README.md")
        try Data("# Updated storefront\n".utf8).write(to: readme)
        await model.activate()
        #expect(model.detail.changes?.map(\.path) == ["README.md", "src/pickup.ts"])
        model.toggleGroup("feature-store-pickup")
        try await waitForDetail(model)
        #expect(model.selection == .group("feature-store-pickup") && model.detail.summary?.hasRemotes == false)
        #expect(model.detail.changes?.isEmpty == true)
        await model.reload()
        #expect(!model.expandedGroups.contains("feature-store-pickup"))
        model.toggleGroup("feature-store-pickup")
        model.selectSidebarRow(mock.initialSelection)
        try await waitForDetail(model)
        #expect(model.detail.summary?.head == "pickup-preview" && model.detail.commits?.count == 4)
        model.selection = nil
        await model.reload()
        #expect(model.selection == nil && model.detail.summary == nil)
        await model.detailPreloadTask?.value
    }

    @Test func externalToolsReceiveRealTemporaryDirectories() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        var launches: [URL] = []
        let tools = ExternalTools(git: mock.fixture.service.git, applicationURL: { id in
            ["com.microsoft.VSCode", "com.DanPristupov.Fork", "com.openai.codex"].contains(id) ? mock.directory.appending(path: "Tool.app") : nil
        }, openURL: { url, _ in launches.append(url) })
        let model = mock.makeModel(toolService: tools)
        _ = await model.start()
        await model.detailPreloadTask?.value
        let record = try #require(model.workspace)
        #expect(model.tools.map(\.id) == ["codex", "fork", "vscode"])
        model.openTool(try #require(model.tools.first { $0.id == "vscode" }))
        try await waitUntil { launches.count == 1 }
        model.selectSidebarRow(.group("feature-store-pickup"))
        model.openTool(try #require(model.tools.first { $0.id == "fork" }))
        try await waitUntil { launches.count == 2 }
        model.openTool(try #require(model.tools.first { $0.id == "codex" }), workspaceRoot: true)
        try await waitUntil { launches.count == 3 }
        #expect(launches == [record.memberURL("feature-store-pickup", "order-service"), record.groupURL("feature-store-pickup"), record.rootURL])
        #expect(model.message == nil && model.defaults.string(forKey: "tool.Editor") == "vscode")
        model.openTool(try #require(ExternalTool.builtIn.first { $0.id == "cursor" }))
        try await waitUntil { model.message != nil }
        #expect(launches.count == 3 && model.preferredToolIDs["Editor"] == "vscode")
        await model.detailPreloadTask?.value
        try await waitForDetail(model)
    }

    @Test func managementUsesRealRepositoriesAndLocalTrash() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        _ = await model.start()
        await model.detailPreloadTask?.value
        let original = try #require(model.workspace)
        try await remove(.repository("catalog-service"), using: model)
        #expect(!PathSafety.exists(original.repositoryURL("catalog-service")))
        let trashed = try FileManager.default.contentsOfDirectory(at: mock.directory.appending(path: "trash"), includingPropertiesForKeys: nil)
        #expect(trashed.count == 1 && PathSafety.exists(trashed[0].appending(path: ".git")))

        model.add("https://example.invalid/catalog-service.git", name: "")
        try await finishOperation(model)
        #expect(model.selection == .repository("catalog-service"))
        #expect(model.workspace?.repositories.count == 7)
        #expect(try await model.service.git.run(["config", "--local", "--get", "include.path"], at: original.repositoryURL("catalog-service")).text == mock.directory.appending(path: "gitconfig").path)
        model.create("mock-management", members: ["catalog-service", "inventory-service"])
        try await finishOperation(model)
        #expect(model.selection == .group("mock-management"))
        #expect(model.workspace?.groups["mock-management"]?.repositories == ["catalog-service", "inventory-service"])

        model.sheet = .edit
        model.edit("mock-management", members: ["inventory-service", "payment-service"])
        await model.editPreviewTask?.value
        try #require(model.canConfirmDelete)
        #expect(model.deletion.map(\.resource) == [.member("mock-management", "catalog-service")])
        model.confirmDelete()
        try await finishOperation(model)
        #expect(model.workspace?.groups["mock-management"]?.repositories == ["inventory-service", "payment-service"])
        try await remove(.member(group: "mock-management", repo: "payment-service"), using: model)
        #expect(model.workspace?.groups["mock-management"]?.repositories == ["inventory-service"])
        try await remove(.group("mock-management"), using: model)
        #expect(model.workspace?.groups["mock-management"] == nil)
        #expect(!PathSafety.exists(original.groupURL("mock-management")))

        let source = mock.directory.appending(path: "sources/catalog-service")
        try Data("# Updated catalog\n".utf8).write(to: source.appending(path: "README.md"))
        for arguments in [["add", "README.md"], ["commit", "-m", "docs: update catalog"],
                          ["push", mock.directory.appending(path: "remotes/catalog-service.git").path, "HEAD:refs/heads/main"]] {
            _ = try await model.service.git.run(arguments, at: source)
        }
        model.update()
        try await finishOperation(model)
        let updatedOID = try await model.service.git.oid("HEAD", at: source)
        #expect(try await model.service.git.oid("HEAD", at: original.repositoryURL("catalog-service")) == updatedOID)
        #expect(try await model.service.git.changes(at: original.memberURL("feature-store-pickup", "order-service")) == Self.orderChanges)
        #expect(try model.service.store.load(original.rootURL) == model.workspace)
    }

    @Test func yamlImportAndExportUseTheSameWorkspaceFlows() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        _ = await model.start()
        await model.detailPreloadTask?.value
        let original = try #require(model.workspace)
        let export = mock.directory.appending(path: "workspace.yaml")
        try await model.service.exportYAML(at: original.rootURL, to: export)
        let yaml = try String(contentsOf: export, encoding: .utf8)
        model.importWorkspace(yaml, filename: export.lastPathComponent)
        try await finishOperation(model)
        #expect(model.result?.reasonCode == "workspace-not-empty")
        #expect(model.workspace == original)
        model.dismissResult()

        let target = mock.directory.appending(path: "import-workspace")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        model.changeWorkspace(target)
        try await finishOperation(model)
        #expect(model.workspace?.root == target.path && model.workspace?.repositories.isEmpty == true)
        model.importWorkspace(yaml, filename: export.lastPathComponent)
        try await finishOperation(model)
        let imported = try #require(model.workspace)
        #expect(imported.repositories == original.repositories && imported.groups == original.groups)
        for resource in model.service.resources(imported) {
            let path = try await model.service.checked(resource, in: imported)
            #expect(path.path.hasPrefix(target.path + "/"))
        }
        try await remove(.repository("catalog-service"), using: model)
        model.sheet = .add
        model.importRepositories("repositories: [https://example.invalid/catalog-service.git]", filename: "repositories.yaml")
        try await finishOperation(model)
        #expect(model.workspace?.repositories.map(\.url).sorted() == original.repositories.map(\.url).sorted())
        #expect(model.selection == .repository("catalog-service"))
        model.changeWorkspace(original.rootURL)
        try await finishOperation(model)
        #expect(model.workspace == original)
        #expect(try await model.service.git.changes(at: original.memberURL("feature-store-pickup", "order-service")) == Self.orderChanges)
    }

    @Test func setupCLIAndPreferencesStayInTheTemporaryEnvironment() async throws {
        let savedWorkspace = UserDefaults.standard.string(forKey: "workspace")
        let savedLanguage = UserDefaults.standard.string(forKey: "language")
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        _ = await model.start()
        await model.detailPreloadTask?.value
        let source = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        #expect(try await model.installer.installCLI(from: source).available)
        #expect(await model.installer.checkCLI().available)
        #expect(model.installer.executable.path.hasPrefix(mock.directory.path + "/"))
        let link = mock.directory.appending(path: "home/.local/bin/modu-cli")
        #expect(PathSafety.canonical(link) == model.installer.executable)
        let target = mock.directory.appending(path: "setup-workspace")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(try await model.service.candidate(target).path == target.path)
        let opened = await model.service.openWorkspaceWithRecord(target, installer: model.installer)
        #expect(opened.result.status == "success")
        let openedRecord = try #require(opened.record)
        try await model.completeSetup(target, loaded: openedRecord)
        await model.detailPreloadTask?.value
        #expect(model.workspace?.root == target.path)
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
        let other = try await makeMock()
        defer { other.remove() }
        let original = try await other.fixture.load()
        let originalBytes = try Data(contentsOf: other.fixture.service.store.recordURL(original.rootURL))
        let model = mock.makeModel()
        _ = await model.start()
        await model.detailPreloadTask?.value
        let record = try #require(model.workspace)
        let alias = mock.directory.appending(path: "outside")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other.fixture.root)
        for target in [other.fixture.root, alias] {
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
        try FileManager.default.createSymbolicLink(at: remoteLink, withDestinationURL: other.directory.appending(path: "remotes/catalog-service.git"))
        model.sheet = .add
        model.add("https://example.invalid/outside.git", name: "")
        try await finishOperation(model)
        #expect(model.formError != nil && model.workspace == record)
        #expect(!PathSafety.exists(record.repositoryURL("outside")))
        model.sheet = nil
        model.changeWorkspace(other.fixture.root)
        try await finishOperation(model)
        #expect(model.workspace == record && model.result?.items.first?.reasonCode == "unsafe-path")
        model.dismissResult()
        model.defaults.set(other.fixture.root.path, forKey: "workspace")
        await model.reload()
        #expect(model.workspace == nil && model.blocked != nil)
        #expect(try Data(contentsOf: other.fixture.service.store.recordURL(original.rootURL)) == originalBytes)
        #expect(try await other.fixture.load() == original)
    }

    @Test func addingUnmappedRemotesFailsWithoutNetworkAccess() async throws {
        let mock = try await makeMock()
        defer { mock.remove() }
        let model = mock.makeModel()
        _ = await model.start()
        await model.detailPreloadTask?.value
        let record = try #require(model.workspace)
        model.sheet = .add
        model.add("https://unmapped.invalid/extra.git", name: "")
        try await finishOperation(model)
        #expect(model.formError != nil && model.workspace == record)
        #expect(!PathSafety.exists(record.repositoryURL("extra")))
        #expect(model.service.git.runner.environment["GIT_ALLOW_PROTOCOL"] == "file")
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

    private func remove(_ request: DeleteRequest, using model: AppModel) async throws {
        model.prepareDelete(request)
        await model.deletePreviewTask?.value
        try #require(model.canConfirmDelete)
        model.confirmDelete()
        try await finishOperation(model)
    }

    private func finishOperation(_ model: AppModel) async throws {
        await (try #require(model.operation)).value
        await model.detailPreloadTask?.value
        #expect(!model.busy)
    }

    private func waitForDetail(_ model: AppModel) async throws {
        try await waitUntil { !model.detailLoading }
        #expect(model.detail.summaryError == nil && model.detail.changesError == nil && model.detail.commitsError == nil)
    }

    private func makeMock() async throws -> MockWorkspace {
        let fixture = try await MockWorkspacePreparation.prepare()
        do { return try MockWorkspace(scenario: .linkedWorktreeSelected, workspace: fixture.root) }
        catch { fixture.remove(); throw error }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
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

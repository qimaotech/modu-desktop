import Foundation
import Testing
import AppKit
import SwiftUI
import Observation
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct PresentationTests {
    @Test(arguments: ["en", "zh"])
    func repositoryAdditionErrorsUseShortCopyAndPreserveDetails(_ language: String) throws {
        let suite = "ModuRepositoryErrors.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        let raw = "Git ls-remote failed (128). ERROR: Repository not found.\nfatal: Could not read from remote repository.\nPlease make sure you have the correct access rights and the repository exists."
        let item = ItemResult(.repository("missing"), status: "failed", error: ModuError("git-failed", raw))
        let result = OperationResult(command: "repo.add", workspace: "/workspace", status: "failed", items: [item])
        #expect(model.resultTitle(result) == model.t("Can’t add repository", "无法添加仓库"))
        let summary = model.t("Repository not found or access denied. Check the URL and your access permissions.", "仓库不存在或无权访问，请检查地址和访问权限。")
        #expect(model.resultMessage(item, overallMessage: nil, command: "repo.add") == summary)
        #expect(model.resultMessage(item, overallMessage: nil, command: "repo.import-yaml") == summary)
        #expect(item.message == raw && item.reasonCode == "git-failed")
        #expect(model.resultMessage(item, overallMessage: nil, command: "repo.update") == raw)
        #expect(model.repositoryAdditionMessage(reasonCode: "authentication-failed", message: raw) == model.t("Couldn’t authenticate with the repository. Check your Git credentials or SSH access.", "仓库认证失败，请检查 Git 凭据或 SSH 访问权限。"))
        let timeout = "Git ls-remote: Command exceeded its 60-second time limit."
        #expect(model.repositoryAdditionMessage(reasonCode: "network-timeout", message: timeout) == timeout)
        var added = ItemResult(.repository("repo"), status: "failed", error: ModuError("ignore-unavailable", ".gitignore must be a readable, writable regular file."))
        added.data = ["disposition": "added"]
        #expect(model.resultTitle(.init(command: "repo.add", workspace: "/workspace", status: "failed", items: [added])) == model.t("Repository added with an issue", "仓库已添加，但有一项问题"))
        #expect(model.resultMessage(added, overallMessage: nil, command: "repo.add") == model.t("The repository was added, but .gitignore couldn’t be updated. Check the file’s permissions and type.", "仓库已添加，但无法更新 .gitignore，请检查文件权限和类型。"))
    }

    @Test func repositoryAdditionFailureKeepsFormAndClearsDetailsWithTheError() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: f.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: f.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: f.service)
        model.workspace = try await f.service.load(f.root)
        model.sheet = .add
        let raw = "Git ls-remote failed (128). ERROR: Repository not found."
        model.run { _, root, _ in
            .init(command: "repo.add", workspace: root.path, status: "failed", items: [ItemResult(.repository("missing"), status: "failed", error: ModuError("git-failed", raw))])
        }
        await (try #require(model.operation)).value
        #expect(model.sheet == .add && model.result == nil && !model.busy)
        #expect(ContentView(model: model).mainSheetPresentation.wrappedValue)
        #expect(model.formError == model.t("Repository not found or access denied. Check the URL and your access permissions.", "仓库不存在或无权访问，请检查地址和访问权限。"))
        #expect(model.formErrorDetails == raw)
        model.formError = nil
        #expect(model.formErrorDetails == nil)
    }

    @Test(arguments: ["repository", "group", "member", "edit"])
    func cancellingDeletionPreservesContentAndCleansUpAfterDismissal(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        let record = try await fixture.service.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = record
        model.selection = .group("feature")
        await model.reload()
        await model.detailPreloadTask?.value
        if kind == "edit" {
            model.sheet = .edit
            model.edit("feature", members: [])
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.sheet == .edit, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        } else {
            let request: DeleteRequest = kind == "repository" ? .repository("repo") : kind == "group" ? .group("feature") : .member(group: "feature", repo: "repo")
            model.prepareDelete(request)
            await model.deletePreviewTask?.value
        }
        try #require(model.canConfirmDelete)
        let resources = model.deletion.map(\.resource)
        let view = ManagementView(model: model, sheet: .delete)
        let size = NSHostingView(rootView: view).fittingSize
        if kind == "edit" {
            model.sheet = .edit
            #expect(model.pendingEdit?.0 == "feature" && model.pendingEdit?.1 == [])
            #expect(model.deletion.map(\.resource) == resources)
            model.sheet = .delete
        }
        let binding = ContentView(model: model).mainSheetPresentation
        binding.wrappedValue = false
        #expect(model.sheet == nil && !binding.wrappedValue && !model.canConfirmDelete)
        #expect(!model.busy && model.operation == nil && model.managementProgress == nil)
        #expect(model.deletion.map(\.resource) == resources && model.deletionResources == resources)
        if kind == "edit" {
            #expect(model.pendingEdit?.0 == "feature" && model.pendingEdit?.1 == [])
        } else { #expect(model.deleteRequest != nil && model.pendingEdit == nil) }
        #expect(NSHostingView(rootView: view).fittingSize == size)
        model.finishManagementDismissal()
        #expect(model.deleteRequest == nil && model.pendingEdit == nil && model.deletion.isEmpty && model.deletionResources.isEmpty)
        #expect(model.deletionPresentation.resources == resources && model.deletionPresentation.targets.map(\.resource) == resources)
        #expect(model.deletionPresentation.editingGroup == (kind == "edit"))
        #expect(NSHostingView(rootView: view).fittingSize == size)
        model.confirmDelete()
        #expect(model.operation == nil && model.workspace == record)
        #expect(try fixture.service.store.load(fixture.root) == record)
        #expect(PathSafety.exists(record.repositoryURL("repo")) && PathSafety.exists(record.groupURL("feature")) && PathSafety.exists(record.memberURL("feature", "repo")))
        model.sheet = .edit
        #expect(model.deleteRequest == nil && model.pendingEdit == nil && model.deletion.isEmpty)
        #expect(model.deletionPresentation.resources.isEmpty && !model.deletionPresentation.editingGroup)
        model.sheet = nil
        model.prepareDelete(.member(group: "feature", repo: "repo"))
        #expect(model.deletion.isEmpty && model.pendingEdit == nil && model.deletionLoading)
        await model.deletePreviewTask?.value
        #expect(model.canConfirmDelete && model.deletionResources == [.member("feature", "repo")])
        model.finishManagementDismissal()
        #expect(model.canConfirmDelete && model.deleteRequest != nil && model.deletionResources == [.member("feature", "repo")])
        model.sheet = nil
    }

    @Test func repositoryDeletionKeepsProgressThroughDismissalAndReopensConfirmation() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        #expect(await fixture.service.createGroup("feature", repositories: ["repo"], at: fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.prepareDelete(.repository("repo"))
        await model.deletePreviewTask?.value
        try #require(model.canConfirmDelete)
        let view = ManagementView(model: model, sheet: .delete)
        let confirmationSize = NSHostingView(rootView: view).fittingSize
        model.confirmDelete()
        await (try #require(model.operation)).value
        await model.detailPreloadTask?.value
        #expect(!model.busy && model.sheet == nil && model.result == nil)
        #expect(model.workspace?.repositories.isEmpty == true && model.workspace?.groups["feature"]?.repositories == [])
        let presentation = try #require(model.managementProgress)
        #expect(presentation.progress?.target == "repositories/repo" && presentation.progress?.phase == "Deleted")
        let progressView = OperationProgressView(model: model, title: model.t("Deleting…", "正在删除…"), presentation: presentation)
            .fixedSize(horizontal: false, vertical: true)
        let progressSize = NSHostingView(rootView: progressView).fittingSize
        #expect(progressSize != confirmationSize)
        #expect(NSHostingView(rootView: view).fittingSize == progressSize)
        let binding = ContentView(model: model).mainSheetPresentation
        #expect(!binding.wrappedValue)
        binding.wrappedValue = false
        model.finishManagementDismissal()
        #expect(model.deleteRequest == nil && model.pendingEdit == nil && model.deletion.isEmpty)
        #expect(model.managementProgress != nil)
        #expect(NSHostingView(rootView: view).fittingSize == progressSize)
        model.prepareDelete(.group("feature"))
        #expect(model.sheet == .delete && model.managementProgress == nil && binding.wrappedValue)
        await model.deletePreviewTask?.value
        #expect(model.canConfirmDelete && model.deletionResources == [.group("feature")])
        #expect(NSHostingView(rootView: ManagementView(model: model, sheet: .delete)).fittingSize != progressSize)
        model.sheet = nil
    }

    @Test func worktreeCreationKeepsProgressThroughDismissalAndReopensAsForm() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        try await fixture.commitWorkspace()
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .create
        let view = ManagementView(model: model, sheet: .create)
        let formSize = NSHostingView(rootView: view).fittingSize
        model.create("feature", members: ["repo"])
        #expect(model.busy && model.managementProgress != nil)
        withObservationTracking {
            _ = model.busy
        } onChange: {
            MainActor.assumeIsolated {
                #expect(model.sheet == nil && model.result == nil && model.managementProgress != nil)
                #expect(!ContentView(model: model).mainSheetPresentation.wrappedValue)
            }
        }
        await (try #require(model.operation)).value
        #expect(!model.busy && model.progress == nil)
        #expect(model.selection == .group("feature") && model.expandedGroups.contains("feature"))
        let presentation = try #require(model.managementProgress)
        #expect(presentation.progress?.target == "worktrees/feature/repo")
        let progressView = OperationProgressView(model: model, title: model.t("Creating worktree group…", "正在创建工作树组…"), presentation: presentation)
            .fixedSize(horizontal: false, vertical: true)
        #expect(NSHostingView(rootView: view).fittingSize == NSHostingView(rootView: progressView).fittingSize)
        #expect(model.managementProgress != nil)
        model.sheet = .create
        #expect(model.managementProgress == nil)
        #expect(NSHostingView(rootView: view).fittingSize == formSize)
        model.sheet = nil
        model.detailPreloadTask?.cancel()
    }

    @Test func worktreeCreationFailureRestoresFormForRetry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        _ = try await fixture.service.git.run(["branch", "feature", "HEAD~1"], at: fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .create
        model.create("feature", members: ["repo"])
        await (try #require(model.operation)).value
        #expect(!model.busy && model.managementProgress == nil && model.formError != nil)
        #expect(model.sheet == .create && model.result == nil && ContentView(model: model).mainSheetPresentation.wrappedValue)
        _ = try await fixture.service.git.run(["branch", "-d", "feature"], at: fixture.root)
        model.create("feature", members: ["repo"])
        #expect(model.busy && model.managementProgress != nil && model.formError == nil)
        #expect(model.managementProgress != nil)
        await (try #require(model.operation)).value
        #expect(!model.busy && model.sheet == nil && model.result == nil)
        model.sheet = .create
        #expect(model.managementProgress == nil)
        #expect(model.sheet == .create)
        model.sheet = nil
        model.detailPreloadTask?.cancel()
    }

    @Test func worktreeCreationCancellationWithoutEffectsKeepsProgressDuringDismissal() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .create
        model.run { _, root, _ in .init(command: "worktree.create", workspace: root.path, status: "cancelled") }
        await (try #require(model.operation)).value
        #expect(!model.busy && model.sheet == nil && model.result == nil && model.managementProgress != nil)
        #expect(!ContentView(model: model).mainSheetPresentation.wrappedValue)
        #expect(model.managementProgress != nil)
        model.sheet = .create
        #expect(model.managementProgress == nil)
        model.sheet = nil
    }

    @Test(arguments: ["skipped", "success", "invalid"])
    func repositoryImportTransitionsDirectlyToItsCompletionState(_ outcome: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        if outcome == "skipped" {
            #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == "success")
        }
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .add
        let presentation = ContentView(model: model).mainSheetPresentation
        #expect(presentation.wrappedValue)
        model.importRepositories(outcome == "invalid" ? "{invalid YAML" : "url: \(fixture.remoteURL)", filename: "repositories.yaml")
        #expect(model.busy && presentation.wrappedValue)
        withObservationTracking {
            _ = model.busy
        } onChange: {
            MainActor.assumeIsolated {
                #expect(model.sheet == (outcome == "invalid" ? .add : nil))
                #expect(model.result?.status == (outcome == "skipped" ? "skipped" : nil))
                #expect(ContentView(model: model).mainSheetPresentation.wrappedValue == (outcome != "success"))
            }
        }
        await (try #require(model.operation)).value
        #expect(!model.busy && model.importFileName == nil)
        #expect((model.managementProgress != nil) == (outcome != "invalid"))
        #expect(model.managementProgress?.importFileName == (outcome == "invalid" ? nil : "repositories.yaml"))
        #expect((model.formError != nil) == (outcome == "invalid"))
        #expect(presentation.wrappedValue == (outcome != "success"))
        presentation.wrappedValue = false
        #expect(model.sheet == nil && model.result == nil && !presentation.wrappedValue)
        #expect((model.managementProgress != nil) == (outcome != "invalid"))
        model.sheet = .add
        #expect(model.managementProgress == nil)
        model.sheet = nil
    }

    @Test(arguments: ["partial-success", "cancelled"])
    func repositoryImportRetainedResultsStayInThePresentedSheet(_ status: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.sheet = .add
        let presentation = ContentView(model: model).mainSheetPresentation
        model.run { _, root, _ in
            var added = ItemResult(.repository("added"))
            added.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)]
            let remaining = status == "cancelled" ? ItemResult.notProcessed(.repository("remaining")) : ItemResult(.repository("remaining"), status: "failed")
            return OperationResult(command: "repo.import-yaml", workspace: root.path, status: status, items: [added, remaining])
        }
        #expect(model.busy && presentation.wrappedValue)
        withObservationTracking {
            _ = model.busy
        } onChange: {
            MainActor.assumeIsolated {
                #expect(model.sheet == nil && model.result?.status == status)
                #expect(ContentView(model: model).mainSheetPresentation.wrappedValue)
            }
        }
        await (try #require(model.operation)).value
        #expect(!model.busy && model.sheet == nil && model.result?.status == status)
        #expect(model.managementProgress != nil)
        #expect(presentation.wrappedValue)
        model.dismissResult()
        #expect(!presentation.wrappedValue)
        #expect(model.managementProgress != nil)
        model.sheet = .add
        #expect(model.managementProgress == nil)
        model.sheet = nil
    }

    @Test(arguments: ["en", "zh"])
    func dialogResultsSummarizeActualOutcomesAndUseTaskTitles(_ language: String) throws {
        let suite = "ModuDialogResults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        let added = ItemResult(.repository("added"))
        var skipped = ItemResult(.repository("existing"), status: "skipped")
        skipped.data = ["disposition": "already-exists"]
        let notProcessed = ItemResult.notProcessed(.repository("pending"))
        let failed = ItemResult(.repository("failed"), status: "failed")
        let cancelled = ItemResult(.repository("cancelled"), status: "cancelled")
        let result = OperationResult(command: "repo.import-yaml", workspace: "/workspace", status: "partial-success",
                                     items: [added, skipped, failed, cancelled, notProcessed])
        #expect(model.resultSummaryText(result) == model.t("Added 1 · Skipped 1 · Failed 1 · Cancelled 1 · Not processed 1", "已添加 1 · 已跳过 1 · 失败 1 · 已取消 1 · 未处理 1"))
        #expect(model.resultTitle(result) == model.t("Repository import · Partially completed", "导入仓库 · 部分完成"))
        #expect(model.resultStatus(notProcessed) == model.t("Not processed", "未处理"))
        #expect(model.resultStatus(skipped) == model.t("Skipped · Already exists", "已跳过 · 已存在"))
        #expect(model.resultTitle(.init(command: "repo.import-yaml", workspace: nil, status: "skipped", items: [skipped])) == model.t("No repositories were added", "没有新增仓库"))
        #expect(model.resultTitle(.init(command: "repo.update", workspace: nil, status: "skipped", items: [skipped])) == model.t("No repositories were updated", "没有仓库被更新"))
        #expect(model.resultTitle(.init(command: "workspace.open", workspace: nil, status: "failed")) == model.t("Can’t open workspace", "无法打开工作区"))
        #expect(model.resultSummaryText(.init(command: "repo.add", workspace: nil, items: [added])) == nil)
        #expect(model.resultSummaryText(.init(command: "repo.add", workspace: nil)) == nil)
        let workspaceResult = OperationResult(command: "workspace.import-yaml", workspace: nil, status: "partial-success", items: [added, failed])
        #expect(model.resultSummaryText(workspaceResult) == model.t("Completed 1 · Failed 1", "已完成 1 · 失败 1"))
    }

    @Test func dialogErrorsKeepTheirTitleAndTriggeringWindow() throws {
        let suite = "ModuDialogErrors.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.presentMessage("File can’t be read.", title: "Can’t read configuration file", host: .settings)
        #expect(model.message == "File can’t be read." && model.messageHost == .settings)
        #expect(model.messageTitle == "Can’t read configuration file")
        model.message = nil
        model.presentMessage("Launch failed.", title: "Can’t open Codex")
        #expect(model.message == "Launch failed." && model.messageHost == .main)
        #expect(model.messageTitle == "Can’t open Codex")
    }

    @Test func editPreviewFailureStaysInsideTheEditSheet() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let before = try await fixture.service.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = before; model.sheet = .edit
        model.edit("missing-group", members: [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.formError == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.formError == "Group is not configured.")
        #expect(model.sheet == .edit && model.result == nil && model.pendingEdit == nil && !model.busy)
        #expect(try await fixture.service.load(fixture.root) == before)
    }

    @Test func workspaceImportKeepsTheFilenameUntilItFinishes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)
        model.resultHost = .settings
        model.importWorkspace("{invalid YAML", filename: "workspace.yaml")
        #expect(model.busy && model.importFileName == "workspace.yaml" && model.resultHost == .settings)
        await (try #require(model.operation)).value
        #expect(model.importFileName == nil && !model.busy)
        #expect(model.result?.command == "workspace.import-yaml" && model.result?.status == "failed" && model.resultHost == .settings)
        let mainPresentation = ContentView(model: model).mainSheetPresentation
        #expect(!mainPresentation.wrappedValue)
        mainPresentation.wrappedValue = false
        #expect(model.result?.status == "failed" && model.resultHost == .settings)
    }

    @Test(arguments: [ManagementSheet.create, .edit], ["en", "zh"])
    func repositorySearchPreservesSortingSelectionAndSheetSize(_ sheet: ManagementSheet, _ language: String) throws {
        let suite = "ModuRepositorySearchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        var workspace = WorkspaceRecord(root: "/workspace")
        workspace.repositories = [
            Repository(url: "https://example.invalid/api10.git", name: "Service 10"),
            Repository(url: "https://example.invalid/frontend.git", name: "baize-frontend"),
            Repository(url: "https://example.invalid/api2.git", name: "Service 2"),
            Repository(url: "https://example.invalid/mobile.git", name: "移动前端"),
            Repository(url: "https://example.invalid/server.git")
        ]
        model.workspace = workspace
        let selection: Set<String> = ["frontend", "server"]
        let all = model.sortedRepositories.map(\.id)
        var sizes: [NSSize] = []
        for (query, expected) in [("", all), (" \n ", all), (" FRONT ", ["frontend"]),
                                  ("service", ["api2", "api10"]), ("前端", ["mobile"]),
                                  ("api10", []), ("unmatched", [])] {
            let view = ManagementView(model: model, sheet: sheet, selected: selection, repositorySearch: query)
            #expect(view.matchingRepositories.map(\.id) == expected)
            #expect(view.selectedMembers == ["frontend", "server"])
            #expect(view.selected == selection)
            #expect(model.workspace == workspace)
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            sizes.append(host.fittingSize)
        }
        #expect(sizes.allSatisfy { $0 == sizes[0] })
        #expect(sizes[0].width == DesignStyle.sheetWidth && sizes[0].height > 0)
    }

    @Test(arguments: ["en", "zh"])
    func setupContinueKeepsSizeAndAnnouncesProgress(_ language: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "modu-setup-button-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let model = AppModel(defaults: defaults)
        model.language = language
        var sizes: [NSSize] = []
        for settingUp in [false, true] {
            let setup = SetupView(model: model, settingUp: settingUp)
            #expect(setup.continueButtonTitle == (settingUp ? model.t("Setting up…", "正在设置…") : model.t("Continue", "继续")))
            let host = NSHostingView(rootView: setup.continueButtonLabel)
            host.layoutSubtreeIfNeeded()
            sizes.append(host.fittingSize)
        }
        #expect(sizes[0] == sizes[1])
        #expect(sizes[0].width > 0 && sizes[0].height > 0)
    }

    @Test(arguments: [true, false])
    func toolChoiceUpdatesObservedDefaultOnlyAfterSuccessfulLaunch(_ succeeds: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "modu-tool-choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "worktrees/feature")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "tool.Agent")
        defaults.set("vscode", forKey: "tool.Editor")
        var launches: [URL] = []
        let toolService = ExternalTools(applicationURL: { _ in root.appending(path: "Claude.app") }, openURL: { url, _ in
            launches.append(url)
            if !succeeds { throw ModuError("tool-launch-failed", "Could not open the desktop app.") }
        })
        let model = AppModel(defaults: defaults, toolService: toolService)
        var workspace = WorkspaceRecord(root: root.path)
        workspace.groups["feature"] = WorktreeGroup()
        model.workspace = workspace
        model.selection = .group("feature")
        model.tools = ExternalTool.builtIn
        let claude = try #require(model.tools.first { $0.id == "claude" })
        #expect(model.preferredToolIDs["Agent"] == "codex")
        withObservationTracking {
            _ = model.preferredToolIDs["Agent"]
        } onChange: {
            UserDefaults(suiteName: suite)?.set(true, forKey: "toolPreferenceChanged")
        }

        model.openTool(claude)
        #expect(model.preferredToolIDs["Agent"] == "codex")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.preferredToolIDs["Agent"] == "codex", model.message == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = succeeds ? "claude" : "codex"
        #expect(model.preferredToolIDs["Agent"] == expected)
        #expect(defaults.string(forKey: "tool.Agent") == expected)
        #expect(defaults.bool(forKey: "toolPreferenceChanged") == succeeds)
        #expect(model.preferredToolIDs["Editor"] == "vscode")
        #expect(model.selection == .group("feature"))
        #expect(launches.count == 1)
        #expect((model.message == nil) == succeeds)
        let reopened = AppModel(defaults: defaults, toolService: toolService)
        #expect(reopened.preferredToolIDs["Agent"] == expected)
    }

    @Test func resultsRemoveDuplicateCopyButKeepActualEffects() throws {
        let suite = "ModuPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = "en"
        var item = ItemResult(.repository("repo"))
        item.data = ["disposition": "updated"]
        item.message = "Updated"
        #expect(model.resultStatus(item) == "Updated")
        #expect(model.resultMessage(item, overallMessage: nil) == nil)
        item.status = "skipped"; item.data = ["disposition": "already-exists"]
        #expect(model.resultStatus(item) == "Skipped · Already exists")
        item.status = "failed"; item.data = nil; item.message = "Cleanup failed: branch is still in use."
        item.effects = [.init("update-refs", "/workspace/repositories/repo"),
                        .init("clone", "/workspace/repositories/repo", state: "reverted"),
                        .init("delete-branch", "feature/test", state: "unknown")]
        #expect(model.resultMessage(item, overallMessage: nil) == item.message)
        #expect(model.resultMessage(item, overallMessage: item.message) == nil)
        #expect(model.effectSummaries(item, workspace: "/workspace") == ["Applied: Update refs", "Cleaned up: Clone", "Unconfirmed: Delete branch: feature/test"])
        model.language = "zh"
        #expect(model.resultStatus(item) == "失败")
        #expect(model.effectSummaries(item, workspace: "/workspace") == ["已生效: 更新引用", "已清理: 克隆", "无法确认: 删除分支: feature/test"])
        item.effects = [.init("delete-branch", item.resource.path)]
        #expect(model.effectSummaries(item, workspace: "/workspace") == ["已生效: 删除分支: repositories/repo"])
    }

    @Test func deletionShowsMainResourceFirstWithoutChangingExecutionOrder() throws {
        let suite = "ModuDeletionPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let root = Resource.group("feature-hello")
        let baize = Resource.member("feature-hello", "baize-frontend")
        let pixiu = Resource.member("feature-hello", "pixiu-frontend")
        let repository = Resource.repository("baize-frontend")
        let other = Resource.member("another-group", "baize-frontend")
        for (original, displayed) in [
            ([], []), ([root], [root]), ([baize], [baize]),
            ([pixiu, baize, root], [root, pixiu, baize]),
            ([pixiu, root, baize], [root, pixiu, baize]),
            ([repository], [repository]),
            ([other, baize, repository], [repository, other, baize]),
            ([other, repository, baize], [repository, other, baize])
        ] {
            model.deletion = original.map { resource in
                DeletionTarget(resource: resource, path: "/workspace/\(resource.path)", branch: resource.kind == "repository" ? nil : "feature-hello", detached: false, registered: true, exists: true, risks: [])
            }
            let view = ManagementView(model: model, sheet: .delete)
            #expect(view.deletionDisplayResources == displayed)
            #expect(model.deletion.map(\.resource) == original)
        }
        var workspace = WorkspaceRecord(root: "/workspace")
        workspace.repositories = [Repository(url: "https://example.invalid/baize-frontend.git"), Repository(url: "https://example.invalid/pixiu-frontend.git")]
        workspace.groups["feature-hello"] = WorktreeGroup(repositories: ["pixiu-frontend", "baize-frontend"])
        workspace.groups["another-group"] = WorktreeGroup(repositories: ["baize-frontend"])
        model.workspace = workspace; model.deletion = []; model.deletionLoading = true
        let requests: [(DeleteRequest, [Resource], [Resource])] = [
            (.group("feature-hello"), [pixiu, baize, root], [root, pixiu, baize]),
            (.repository("baize-frontend"), [other, baize, repository], [repository, other, baize]),
            (.member(group: "feature-hello", repo: "baize-frontend"), [baize], [baize])
        ]
        for (request, original, displayed) in requests {
            model.deleteRequest = request
            #expect(model.deletionResources == original)
            #expect(ManagementView(model: model, sheet: .delete).deletionDisplayResources == displayed)
            #expect(model.deletion.isEmpty && !model.canConfirmDelete)
        }
        workspace.groups["feature-hello"]?.repositories = []
        model.workspace = workspace; model.deleteRequest = .group("feature-hello")
        #expect(model.deletionResources == [root])
    }

    @Test(arguments: ["en", "zh"], [0, 3, 9])
    func deletionLayoutStaysFixedAfterPreflight(_ language: String, _ memberCount: Int) throws {
        let suite = "ModuDeletionLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        let members = (0..<memberCount).map { "repository-with-a-very-long-name-\($0)" }
        var workspace = WorkspaceRecord(root: "/workspace")
        workspace.repositories = members.map { Repository(url: "https://example.invalid/\($0).git") }
        workspace.groups["feature"] = WorktreeGroup(repositories: members)
        model.workspace = workspace; model.deleteRequest = .group("feature"); model.sheet = .delete
        let resources = members.map { Resource.member("feature", $0) } + [.group("feature")]
        var rowSizes: [NSSize] = [], sheetSizes: [NSSize] = []
        for status in ["", "Clean", "Dirty", "Other"] {
            model.deletionLoading = status.isEmpty
            model.deletion = status.isEmpty ? [] : resources.map { resource in
                DeletionTarget(resource: resource, path: "/workspace/\(resource.path)",
                               branch: status == "Clean" ? "feature" : "feature/branch-with-a-very-long-name",
                               detached: false, registered: true, exists: status != "Other",
                               risks: status == "Clean" ? ["Working tree is clean."] : [])
            }
            #expect(model.canConfirmDelete == !status.isEmpty)
            let view = ManagementView(model: model, sheet: .delete)
            let row = NSHostingView(rootView: view.deletionRow(try #require(resources.first)).fixedSize())
            row.layoutSubtreeIfNeeded()
            rowSizes.append(row.fittingSize)
            let sheet = NSHostingView(rootView: view)
            sheet.layoutSubtreeIfNeeded()
            sheetSizes.append(sheet.fittingSize)
        }
        #expect(rowSizes.allSatisfy { $0 == rowSizes[0] })
        #expect(sheetSizes.allSatisfy { $0 == sheetSizes[0] })
        #expect(rowSizes[0].width > 0 && rowSizes[0].height == 28)
        #expect(sheetSizes[0].width == DesignStyle.sheetWidth && sheetSizes[0].height > 0)
    }

    @Test func settingsImportDismissesOnlySuccessOrCancellationWithoutEffects() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)

        for (status, effects, quitting, presentsResult) in [
            ("success", true, false, false), ("failed", false, false, true),
            ("partial-success", true, false, true), ("skipped", false, false, true),
            ("cancelled", false, false, false), ("cancelled", true, false, true),
            ("success", true, true, true)
        ] {
            model.quitPending = quitting; model.resultHost = .settings
            model.run { _, root, _ in
                var item = ItemResult(.repository("repo"), status: status)
                if effects { item.effects = [.init("update-ignore", root.appending(path: ".gitignore").path)] }
                return OperationResult(command: "workspace.import", workspace: root.path, status: status, items: [item])
            }
            #expect(model.busy && model.resultHost == .settings)
            let operation = try #require(model.operation)
            await operation.value
            #expect(!model.busy)
            #expect((model.result != nil) == presentsResult)
            #expect(model.resultHost == (presentsResult ? .settings : .main))
            #expect(model.completionMessage == nil)
            model.quitPending = false
            model.dismissResult()
        }
    }

    @Test func successfulRepositoryUpdateRestoresTitleWithoutCompletionFeedback() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace = try await fixture.service.load(fixture.root)

        for disposition in ["updated", "up-to-date"] {
            model.completionMessage = "Previous operation"
            model.run { _, root, _ in
                var item = ItemResult(.repository("repo"))
                item.data = ["disposition": disposition]
                return OperationResult(command: "repo.update", workspace: root.path, items: [item])
            }
            #expect(model.busy && model.completionMessage == nil)
            let operation = try #require(model.operation)
            await operation.value
            #expect(!model.busy && model.progress == nil && model.result == nil)
            #expect(model.completionMessage == nil)
            #expect(model.workspace?.root == PathSafety.canonical(fixture.root).path)
        }
    }

    @Test func repositoryUpdateProgressShowsCountsInBothLanguagesAndWhileCancelling() throws {
        let suite = "ModuProgressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        for (language, updating, cancelling) in [("en", "Updating repositories", "Cancelling…"), ("zh", "正在更新仓库", "正在取消…")] {
            model.language = language; model.cancelling = false; model.progress = nil
            #expect(model.repositoryUpdateProgressText == updating)
            model.progress = .init("", "Updating repositories…", total: 0)
            #expect(model.repositoryUpdateProgressText == updating)
            for completed in 0...3 {
                model.progress = .init("repo", "Updating repositories…", completed: completed, total: 3)
                #expect(model.repositoryUpdateProgressText == "\(updating) · \(completed)/3")
            }
            model.progress = .init("repo", "Updating repositories…", completed: 1, total: 3)
            model.cancelling = true
            #expect(model.repositoryUpdateProgressText == "\(cancelling) · 1/3")
        }
    }

    @Test(arguments: ["en", "zh"])
    func progressSheetSummarizesProcessedItemsAndKeepsCleanupVisible(_ language: String) throws {
        let suite = "ModuProgressSheetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        #expect(model.operationProgressSummaryText == nil)
        #expect(model.operationProgressPhaseText == model.t("Working…", "正在处理…"))
        model.progress = .init("repo", "Cloning…", total: 0)
        #expect(model.operationProgressSummaryText == nil)
        model.progress = .init("repo", "Cloning…", completed: 2, total: 26, counts: (2, 0, 0))
        #expect(model.operationProgressSummaryText == model.t("2 of 26 processed", "已处理 2 / 26"))
        model.progress = .init("repo", "Cloning…", completed: 4, total: 26, counts: (2, 1, 1))
        #expect(model.operationProgressSummaryText == model.t("4 of 26 processed · Skipped 1 · Failed 1", "已处理 4 / 26 · 已跳过 1 · 失败 1"))
        model.cancelling = true
        #expect(model.operationProgressPhaseText == model.t("Cancelling…", "正在取消…"))
        for phase in ["Saving…", "Cleaning up…"] {
            model.progress = .init("repo", phase, completed: 4, total: 26, cancellable: false, counts: (2, 1, 1))
            #expect(model.operationProgressPhaseText == model.statusText(phase))
            #expect(model.operationProgressSummaryText == model.t("4 of 26 processed · Skipped 1 · Failed 1", "已处理 4 / 26 · 已跳过 1 · 失败 1"))
        }
    }

    @Test(arguments: ["en", "zh"], [NSAppearance.Name.aqua, .darkAqua])
    func progressSheetKeepsItsSizeWhenTotalBecomesKnown(_ language: String, _ appearance: NSAppearance.Name) throws {
        let suite = "ModuProgressLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language; model.busy = true
        var sizes: [NSSize] = []
        for progress in [OperationProgress("", "Importing repositories…"),
                         .init("notification-service", "Cloning…", completed: 2, total: 26, counts: (2, 0, 0)),
                         .init("notification-service", "Cloning…", completed: 4, total: 26, counts: (2, 1, 1))] {
            model.progress = progress
            let host = NSHostingView(rootView: OperationProgressView(model: model, title: model.t("Importing repositories…", "正在导入仓库…"), context: ".modu.yaml")
                .fixedSize(horizontal: false, vertical: true))
            host.appearance = NSAppearance(named: appearance)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            sizes.append(host.fittingSize)
            if progress.completed == 2 {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "progress-\(language)-\(appearance.rawValue).png")
            }
        }
        #expect(sizes.allSatisfy { $0 == sizes[0] })
        #expect(sizes[0].width > 0 && sizes[0].height > 0)
    }

    @Test func toolMenuKeepsAvailableTargetsAndDispatchesOnlyChosenTool() throws {
        let button = ToolMenuControl()
        button.frame = NSRect(x: 0, y: 0, width: 26, height: 44)
        button.tools = ExternalTool.builtIn.filter { $0.category == "Agent" }
        var opened: [String] = []
        button.open = { opened.append($0.id) }
        for width: CGFloat in [180, 140] {
            button.menuWidth = width
            let menu = button.makeMenu()
            let origin = button.menuOrigin(for: menu)
            let topPadding = (menu.size.height - CGFloat(menu.numberOfItems) * 38) / 2
            let outerTop = origin.y + (button.isFlipped ? -topPadding : topPadding)
            #expect(origin.x == 26 - width)
            #expect(button.isFlipped ? outerTop - button.bounds.maxY == 4 : button.bounds.minY - outerTop == 4)
            #expect(menu.size.width == width)
            #expect(opened.isEmpty)
            #expect(menu.items.map(\.title) == ["Codex", "Claude Code"])
            #expect(!menu.showsStateColumn)
            #expect(menu.items.allSatisfy { $0.state == .off && $0.view?.frame.size == NSSize(width: width, height: 38) })
            #expect(menu.items.allSatisfy { $0.view?.isOpaque == false && $0.view?.allowsVibrancy == true })
            menu.cancelTracking()
            #expect(opened.isEmpty)
        }
        let menu = button.makeMenu()
        menu.performActionForItem(at: 1)
        #expect(opened == ["claude"])
        #expect(menu.items.allSatisfy { $0.state == .off })
    }

    @Test(arguments: [false, true], [false, true])
    func buttonHoverUsesVerticalGradientAndCircularClipping(hovered: Bool, enabled: Bool) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: Color.clear.frame(width: 40, height: 40)
                .modifier(ButtonHoverBackground(shape: Circle(), hovered: hovered))
                .disabled(!enabled).background(Color.black))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            }
            let top = try pixel(20, 1), bottom = try pixel(20, 38), corner = try pixel(1, 1)
            #expect(corner.redComponent < 0.01 && corner.greenComponent < 0.01 && corner.blueComponent < 0.01)
            if hovered && enabled {
                #expect(abs(top.redComponent - 225.0 / 255) < 0.01)
                #expect(abs(top.greenComponent - 227.0 / 255) < 0.01)
                #expect(abs(top.blueComponent - 229.0 / 255) < 0.01)
                #expect(abs(bottom.redComponent - 241.0 / 255) < 0.01)
                #expect(abs(bottom.greenComponent - 242.0 / 255) < 0.01)
                #expect(abs(bottom.blueComponent - 242.0 / 255) < 0.01)
            } else {
                #expect(top == corner && bottom == corner)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func sidebarRowsShareHoverAndSelectionBackground(selected: Bool, hovered: Bool) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: Button {} label: {
                Rectangle().frame(width: 4, height: 4)
            }.buttonStyle(SidebarButtonStyle()).frame(width: 160, height: 28)
                .modifier(SidebarRowBackground(selected: selected, hovered: hovered))
                .background(Color.black))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            }
            let background = try pixel(80, 4), foreground = try pixel(80, 14), corner = try pixel(0, 0)
            #expect(corner.redComponent < 0.01 && corner.greenComponent < 0.01 && corner.blueComponent < 0.01)
            if selected || hovered {
                #expect(abs(background.redComponent - 238.0 / 255) < 0.01)
                #expect(abs(background.greenComponent - 238.0 / 255) < 0.01)
                #expect(abs(background.blueComponent - 239.0 / 255) < 0.01)
                #expect(foreground.redComponent < 0.01 && foreground.greenComponent < 0.01 && foreground.blueComponent < 0.01)
            } else {
                #expect(background == corner)
            }
        }
    }

    @Test func groupRowClickTogglesAndKeepsSelectionVisible() throws {
        let suite = "ModuSidebarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)

        model.selectSidebarRow(.group("feature"))
        #expect(model.selection == .group("feature"))
        #expect(model.expandedGroups.contains("feature"))
        model.selectSidebarRow(.group("feature"))
        #expect(model.selection == .group("feature"))
        #expect(!model.expandedGroups.contains("feature"))

        model.selectSidebarRow(.group("feature"))
        #expect(model.expandedGroups.contains("feature"))
        for previous in [nil, .repository("repo"), .group("other"), .member("feature", "repo")] as [Resource?] {
            model.selection = previous
            model.expandedGroups.insert("feature")
            model.selectSidebarRow(.group("feature"))
            #expect(model.selection == .group("feature"))
            #expect(model.expandedGroups.contains("feature"))
            model.selectSidebarRow(.group("feature"))
            #expect(model.selection == .group("feature"))
            #expect(!model.expandedGroups.contains("feature"))
        }

        model.selectSidebarRow(.repository("repo"))
        model.toggleGroup("feature")
        #expect(model.selection == .repository("repo"))
        model.selectSidebarRow(.member("feature", "repo"))
        #expect(model.expandedGroups.contains("feature"))
        model.toggleGroup("feature")
        #expect(model.selection == .group("feature"))
        #expect(!model.expandedGroups.contains("feature"))
    }

    @Test func changeTreeSortsDirectoriesFirstAndCollapsesOnlyDescendants() {
        let changes = [
            FileChange(path: "src/file10.swift", index: "A", workingTree: " "),
            FileChange(path: "src/file2.swift", index: "M", workingTree: "M"),
            FileChange(path: "src/a.swift", index: "M", workingTree: " "),
            FileChange(path: "src/hooks/file.swift", index: " ", workingTree: "M"),
            FileChange(path: "README.md", index: " ", workingTree: "D")
        ]
        let tree = ChangeNode.tree(changes)
        let expanded = tree.flatMap { $0.visibleRows(collapsed: []) }
        #expect(expanded.map(\.id) == ["src", "src/hooks", "src/hooks/file.swift", "src/a.swift", "src/file2.swift", "src/file10.swift", "README.md"])
        #expect(expanded.map(\.depth) == [0, 1, 2, 1, 1, 1, 0])
        #expect(expanded[4].node.change?.workingTree == "M")
        #expect(tree.flatMap { $0.visibleRows(collapsed: ["src"]) }.map(\.id) == ["src", "README.md"])
        #expect(tree.flatMap { $0.visibleRows(collapsed: ["src/hooks"]) }.map(\.id) == ["src", "src/hooks", "src/a.swift", "src/file2.swift", "src/file10.swift", "README.md"])
    }

    @Test(arguments: ["en", "zh"])
    func gitPanelsDoNotAppearBeforeContentOrErrorsAreLoaded(_ language: String) throws {
        let suite = "ModuGitPanelsVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.language = language
        model.selection = .group("feature")
        model.detailLoading = true
        let changes = [FileChange(path: "new.txt", index: "?", workingTree: "?")]
        let remote = GitSummary(head: "feature", headOID: "abc", hasRemotes: true, base: "origin/main", baseOID: "def")
        let local = GitSummary(head: "feature", headOID: "abc", hasRemotes: false)
        let commits = [GitCommit(id: "abc", subject: "Commit", author: "Author", date: "not-a-date")]
        let cases: [(String, RepositoryDetailState, Bool, Bool)] = [
            ("unread", .init(), false, false),
            ("reading changes", .init(summary: local, commits: []), false, false),
            ("reading commits", .init(summary: remote, changes: []), false, false),
            ("empty", .init(summary: remote, changes: [], commits: []), false, false),
            ("changes loaded or refreshing", .init(changes: changes), true, false),
            ("no remote", .init(summary: local, changes: changes, commits: []), true, false),
            ("reading range", .init(summary: remote, changes: changes), true, false),
            ("empty range", .init(summary: remote, changes: changes, commits: []), true, false),
            ("commits loaded or refreshing", .init(summary: remote, commits: commits), false, true),
            ("both loaded or refreshing", .init(summary: remote, changes: changes, commits: commits), true, true),
            ("changes error", .init(changesError: "Repository is unavailable."), true, false),
            ("range error", .init(summary: remote, changes: changes, commitsError: "Base is unavailable."), true, true),
            ("commits error", .init(commitsError: "Repository is unavailable."), false, true),
            ("both errors", .init(changesError: "Repository is unavailable.", commitsError: "Repository is unavailable."), true, true)
        ]
        for (phase, detail, changesVisible, commitsVisible) in cases {
            let rendered = try render(detail)
            let view = RepositoryDetailView(model: model)
            #expect(view.showsChanges == changesVisible, "Changes visibility during \(phase)")
            #expect(view.showsCommits == commitsVisible, "Commits visibility during \(phase)")
            #expect(rendered.hasSplit == (changesVisible && commitsVisible), "Git split visibility during \(phase)")
            if !changesVisible && !commitsVisible {
                var empty = detail
                empty.changes = []; empty.commits = []
                let emptyPanels = try render(empty)
                #expect(rendered.pixels.elementsEqual(emptyPanels.pixels), "No empty panel should be drawn during \(phase)")
            }
        }

        func render(_ detail: RepositoryDetailState) throws -> (hasSplit: Bool, pixels: Data) {
            model.detail = detail
            let host = NSHostingView(rootView: RepositoryDetailView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return (!splitViews(in: host).isEmpty, try #require(bitmap.representation(using: .png, properties: [:])))
        }

        func splitViews(in view: NSView) -> [ModuSplitView] {
            ((view as? ModuSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
        }
    }

    @Test(arguments: [false, true], [Resource.repository("repo"), Resource.group("feature")])
    func changesHeightFitsRowsAndScrollsWhenSpaceIsLimited(_ includesCommits: Bool, _ resource: Resource) throws {
        let suite = "ModuChangesLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.selection = resource
        model.detail.commits = includesCommits ? [.init(id: "abc", subject: "Commit", author: "Author", date: "not-a-date")] : []

        for count in [1, 6, 100] {
            model.detail.changes = (0..<count).map { FileChange(path: "file\($0).swift", index: "M", workingTree: " ") }
            let host = NSHostingView(rootView: RepositoryDetailView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            host.layoutSubtreeIfNeeded()
            let scroll = try #require(scrollViews(in: host).first)
            if count < 100 { #expect(scroll.frame.height == CGFloat(count) * 28) }
            else {
                #expect(scroll.frame.height > 0)
                #expect(scroll.frame.height < CGFloat(count) * 28)
            }
        }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
    }

    @Test(arguments: [false, true], [Resource.repository("repo"), Resource.group("feature"), Resource.member("feature", "repo")])
    func commitsHeightFitsContentAndScrollsWhenSpaceIsLimited(_ includesChanges: Bool, _ resource: Resource) throws {
        let suite = "ModuCommitsLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.selection = resource
        model.detail.changes = includesChanges ? [.init(path: "file.swift", index: "M", workingTree: " ")] : []

        var maximumHeight: CGFloat?
        for count in [1, 2, 30, 100] {
            for canLoadMore in [false, true] {
                model.detail.commits = (0..<count).map { .init(id: "commit\($0)", subject: "Commit \($0)", author: "Author", date: "not-a-date") }
                model.detail.canLoadMore = canLoadMore
                let host = NSHostingView(rootView: RepositoryDetailView(model: model))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
                host.layoutSubtreeIfNeeded()
                let scroll = try #require(scrollViews(in: host).last)
                let contentHeight = CGFloat(count) * 28 + (canLoadMore ? 36 : 0)
                if count <= 2 {
                    #expect(scroll.frame.height == min(contentHeight, includesChanges ? 84 : contentHeight))
                } else {
                    #expect(scroll.frame.height > 0 && scroll.frame.height < contentHeight)
                    if let maximumHeight { #expect(scroll.frame.height == maximumHeight) }
                    maximumHeight = scroll.frame.height
                }

                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let scrollFrame = scroll.convert(scroll.bounds, to: host)
                let bottom = host.isFlipped ? scrollFrame.maxY : host.bounds.maxY - scrollFrame.minY
                let border = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int((bottom + 11.5) * scale))?.usingColorSpace(.deviceRGB))
                #expect(abs(border.redComponent - 227.0 / 255) < 0.02)
                #expect(abs(border.greenComponent - 227.0 / 255) < 0.02)
                #expect(abs(border.blueComponent - 227.0 / 255) < 0.02)
            }
        }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
    }

    @Test func changeIconsAlignAcrossDirectoriesAndFileStatuses() throws {
        let suite = "ModuChangesIndentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.selection = .repository("repo")
        model.detail.changes = [
            FileChange(path: "src/app/deck/deck-board-types.ts", index: " ", workingTree: "M"),
            FileChange(path: "src/app/hooks/use-home-focus-restore.test.tsx", index: "M", workingTree: " "),
            FileChange(path: "index.html", index: " ", workingTree: "M"),
            FileChange(path: "README_CN.md", index: "M", workingTree: " "),
            FileChange(path: "both.txt", index: "M", workingTree: "M"),
            FileChange(path: "added.txt", index: "A", workingTree: " "),
            FileChange(path: "untracked.txt", index: " ", workingTree: "?")
        ]
        model.detail.commits = []
        let host = NSHostingView(rootView: RepositoryDetailView(model: model))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let folders = iconFrames { $0.blueComponent > 0.7 && $0.greenComponent > 0.5 && $0.redComponent < 0.5 }.sorted { $0.minX < $1.minX }
        let statuses = iconFrames { $0.redComponent > 0.8 && $0.greenComponent > 0.6 && $0.blueComponent < 0.4 }.sorted { $0.minX < $1.minX }
        try #require(folders.count == 4)
        try #require(statuses.count == 5)
        let origin = folders[0].minX
        for (frame, offset) in zip(folders, [0, 16, 32, 32]) {
            #expect(abs(frame.minX - origin - CGFloat(offset)) <= 2)
        }
        for (frame, offset) in zip(statuses, [0, 0, 0, 48, 48]) {
            #expect(abs(frame.minX - origin - CGFloat(offset)) <= 2)
        }
        #expect(statuses.filter { $0.width > 20 }.count == 1)

        let additions = iconFrames { $0.greenComponent > 0.6 && $0.redComponent < 0.6 && $0.blueComponent < 0.5 }
        try #require(additions.count == 2)
        #expect(additions.allSatisfy { abs($0.minX - origin) <= 2 })
        #expect(additions[0].size == additions[1].size)
        #expect(iconPixels(additions[0]) == iconPixels(additions[1]))

        func iconPixels(_ frame: CGRect) -> [NSColor?] {
            (0..<Int(frame.height * scale)).flatMap { y in
                (0..<Int(frame.width * scale)).map { x in
                    bitmap.colorAt(x: Int(frame.minX * scale) + x, y: Int(frame.minY * scale) + y)
                }
            }
        }

        func iconFrames(where matches: (NSColor) -> Bool) -> [CGRect] {
            var frames: [CGRect] = []
            for y in 0..<bitmap.pixelsHigh {
                let columns = (0..<bitmap.pixelsWide).filter { x in
                    bitmap.colorAt(x: x, y: y).flatMap { $0.usingColorSpace(.deviceRGB) }.map(matches) == true
                }
                guard let first = columns.first, let last = columns.last else { continue }
                let line = CGRect(x: first, y: y, width: last - first + 1, height: 1)
                if frames.last?.maxY == CGFloat(y) { frames[frames.count - 1] = frames[frames.count - 1].union(line) }
                else { frames.append(line) }
            }
            return frames.map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) }
        }
    }

    @Test func commitDatePreservesUnreadableValues() {
        let commit = GitCommit(id: "abc", subject: "Subject", author: "Author", date: "not-a-date")
        #expect(commit.displayDate(language: "en") == "not-a-date")
        let valid = GitCommit(id: "abc", subject: "Subject", author: "Author", date: "2026-08-30T08:18:00Z")
        #expect(valid.displayDate(language: "en").contains("Aug"))
        #expect(valid.displayDate(language: "zh").contains("2026"))
        let hour = Calendar.current.component(.hour, from: ISO8601DateFormatter().date(from: valid.date)!)
        #expect(valid.displayDate(language: "en").hasSuffix(String(format: "%02d:18", hour)))
    }

    @Test func nativeSplitsValidateSidebarActionsWithoutRecursion() throws {
        let suite = "ModuSplitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: WorkspaceSplitView(
            sidebar: Text("Sidebar"),
            detail: GitSplitView(upper: Text("Changes"), lower: Text("Commits"), defaults: defaults)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        host.layoutSubtreeIfNeeded()

        let splits = splitViews(in: host)
        #expect(splits.count == 2)
        for split in splits {
            let delegate = try #require(split.delegate)
            try #require(delegate !== split)
            #expect(!split.responds(to: NSSelectorFromString("toggleSidebar:")))
            #expect(delegate.splitView?(split, constrainMinCoordinate: 0, ofSubviewAt: 0) == (split.isVertical ? 240 : 136))
            #expect(delegate.splitView?(split, constrainMaxCoordinate: 1200, ofSubviewAt: 0) == (split.isVertical ? min(480, split.bounds.width - 660) : split.bounds.height - 148))
            #expect(delegate.responds(to: #selector(NSSplitViewDelegate.splitViewDidResizeSubviews(_:))))
        }

        func splitViews(in view: NSView) -> [ModuSplitView] {
            ((view as? ModuSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
        }
    }

    @Test func nativeSplitUsesDesignWidthsAndKeepsThreeCommitRows() {
        let split = ModuSplitView()
        split.isVertical = true
        split.addArrangedSubview(NSView()); split.addArrangedSubview(NSView())
        split.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        #expect(split.arrangedSubviews[0].frame.width == 338)
        split.frame.size.width = 900
        #expect(split.arrangedSubviews[0].frame.width == 240)
        #expect(split.arrangedSubviews[1].frame.width == 659)

        let git = ModuSplitView()
        git.isVertical = false
        git.addArrangedSubview(NSView()); git.addArrangedSubview(NSView())
        git.frame = NSRect(x: 0, y: 0, width: 814, height: 548)
        #expect(git.arrangedSubviews[0].frame.height == 400)
        #expect(git.arrangedSubviews[1].frame.height == 136)
    }
}

import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class ManagementModel {
    private let service: WorkspaceService
    private let session: WorkspaceModel
    private let operations: OperationLifecycle
    private let presentation: OperationPresentation
    private let preferences: AppPreferences
    // SwiftUI can still render the closed sheet; reset its progress when the next sheet opens.
    private(set) var progressPresentation: ManagementProgressPresentation?
    var repositoryImport: RepositoryImportSelection?
    var importFileName: String?
    var formError: String? { didSet { formErrorDetails = nil } }
    var formErrorDetails: String?
    var sheet: ManagementSheet? {
        didSet {
            if sheet == nil, oldValue == .delete {
                dismissedDeletion = deletionPresentation
            }
            if let sheet, sheet != oldValue {
                progressPresentation = nil
                dismissedDeletion = nil
                // Back to Edit keeps the pending selection; newly opened forms start fresh.
                if sheet != .delete && (sheet != .edit || oldValue != .delete) {
                    deleteRequest = nil; pendingEdit = nil; deletion = []
                }
            }
            if oldValue == .delete && sheet != .delete { cancelDeletePreview() }
            if oldValue == .edit && sheet != .edit { cancelEditPreview() }
            if oldValue == .importRepositories && sheet != .importRepositories { repositoryImport = nil }
        }
    }
    var deletion: [DeletionTarget] = []
    var deletionLoading = false
    private(set) var deletePreviewTask: Task<Void, Never>?
    private(set) var editPreviewTask: Task<Void, Never>?
    var deleteRequest: DeleteRequest?
    var pendingEdit: (String, [String])?
    // The dismissed view must not depend on deletion authorization cleared by onDismiss.
    private var dismissedDeletion: DeletionPresentation?
    private var operationGeneration = 0
    private var deletePreviewGeneration = 0
    private var editPreviewGeneration = 0
    private var busy: Bool { operations.busy }
    private var text: InterfaceText { presentation.text }

    init(service: WorkspaceService, session: WorkspaceModel, operations: OperationLifecycle, presentation: OperationPresentation, preferences: AppPreferences) {
        self.service = service
        self.session = session
        self.operations = operations
        self.presentation = presentation
        self.preferences = preferences
    }

    func contextChanged(rootChanged: Bool) {
        cancelEditPreview()
        if rootChanged, sheet == .delete || sheet == .importRepositories { sheet = nil }
    }

    func finishDismissal() {
        guard sheet == nil, !busy else { return }
        deleteRequest = nil; pendingEdit = nil; deletion = []
    }

    private func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

    func run(_ body: @escaping @Sendable (WorkspaceService, URL, ProgressHandler) async -> OperationResult, select: Resource? = nil) {
        guard let root = session.record?.rootURL, !busy else { return }
        let previousEdit = editPreviewTask
        cancelEditPreview()
        cancelDeletePreview()
        session.cancelDetailPreload()
        progressPresentation = sheet == nil ? nil : .init(importFileName: importFileName)
        guard let operationID = operations.begin(.management) else { return }
        formError = nil; presentation.completionMessage = nil; session.invalidateReads()
        operationGeneration += 1; let operationToken = operationGeneration
        let report: ProgressHandler = { [self] progress in Task { @MainActor in
            guard self.operations.isCurrent(operationID), self.operations.kind != .workspace, self.operationGeneration == operationToken else { return }
            self.operations.report(progress, for: operationID)
            self.progressPresentation?.progress = progress
            // Publish additions immediately; apply removals together in the final reload.
            if let snapshot = progress.snapshot, let workspace = self.session.record, workspace.root == snapshot.root,
               Set(self.service.resources(workspace)).isSubset(of: Set(self.service.resources(snapshot))) {
                self.session.record = snapshot
            }
        } }
        let task = Task {
            await previousEdit?.value
            let outcome = await body(service, root, report)
            let isWorktreeOperation = ["worktree.create", "worktree.update", "worktree.remove"].contains(outcome.command)
            let noEffects = outcome.items.allSatisfy { $0.effects.isEmpty }
            if outcome.status == .failed, noEffects, sheet != nil, sheet != .delete, !presentation.quitPending {
                formError = outcome.message ?? outcome.items.compactMap(\.message).joined(separator: "\n")
                if outcome.command == "repo.add", let raw = formError {
                    let reason = outcome.reasonCode ?? outcome.items.first?.reasonCode
                    formError = text.repositoryAdditionMessage(reasonCode: reason, message: raw)
                    if formError != raw { formErrorDetails = Git.sanitize(raw) }
                }
                progressPresentation = nil
                operations.finish(operationID)
                importFileName = nil
                session.startDetailPreload()
                return
            }
            let retainedDetail: (resource: Resource, workspace: WorkspaceRecord, detail: RepositoryDetailState)?
            if outcome.status == .success, ["worktree.remove", "repo.remove"].contains(outcome.command),
               let selection = session.selection, let workspace = session.record, !outcome.items.contains(where: { $0.resource == selection }) {
                retainedDetail = (selection, workspace, session.detail)
            } else { retainedDetail = nil }
            session.invalidateDetailCache()
            pendingEdit = nil; deletion = []
            if outcome.command == "repo.update" {
                presentation.result = text.resultDisplayItems(outcome).isEmpty ? nil : outcome
            } else if outcome.status == .success && !presentation.quitPending {
                presentation.result = outcome.hasWarnings ? outcome : nil
                if presentation.result == nil, presentation.resultHost == .main, !isWorktreeOperation {
                    presentation.completionMessage = t("Completed", "已完成")
                    Task { try? await Task.sleep(for: .seconds(3)); if operationGeneration == operationToken { presentation.completionMessage = nil } }
                }
            } else if outcome.status == .cancelled, noEffects, !presentation.quitPending { presentation.result = nil }
            else { presentation.result = outcome }
            if presentation.result == nil { presentation.resultHost = .main }
            sheet = nil
            operations.finish(operationID)
            importFileName = nil
            if presentation.quitPending, presentation.result == nil { presentation.finishQuitIfPossible(); return }
            let selectionAtCompletion = session.selection
            await session.reload(showProgress: !isWorktreeOperation, afterLoad: { [self] in
                guard operationGeneration == operationToken, session.record?.rootURL == root, session.selection == selectionAtCompletion else { return }
                if let retainedDetail, session.selection == retainedDetail.resource, let workspace = session.record,
                   session.canRestoreDetail(retainedDetail.resource, from: retainedDetail.workspace, in: workspace) {
                    session.details.restore(retainedDetail.detail, for: retainedDetail.resource)
                }
                if let select, let workspace = session.record, service.resources(workspace).contains(select) { session.selection = select; if let group = select.group { session.expandedGroups.insert(group) } }
                else if let last = outcome.items.last(where: { $0.data?["disposition"] == "added" }), outcome.command == "repo.import-yaml" { session.selection = last.resource }
            })
        }
        operations.attach(task, to: operationID)
    }
    func add(_ url: String, name: String) { run({ service, root, progress in await service.addRepository(.init(url: url.trimmingCharacters(in: .whitespacesAndNewlines), name: name.isEmpty ? nil : name), at: root, progress: progress) }, select: try? Resource.repository(RepositoryIdentity(url.trimmingCharacters(in: .whitespacesAndNewlines)).name)) }
    func create(_ group: String, members: [String]) { run({ service, root, progress in await service.createGroup(group, repositories: members, at: root, progress: progress) }, select: .group(group)) }
    func edit(_ group: String, members: [String]) {
        guard let root = session.record?.rootURL, !busy else { return }
        let previous = editPreviewTask
        cancelEditPreview()
        let context = editPreviewGeneration
        formError = nil
        editPreviewTask = Task {
            await previous?.value
            guard !Task.isCancelled, editPreviewGeneration == context, session.record?.rootURL == root, sheet == .edit, !busy else { return }
            let preview = await service.editGroupPreview(group, repositories: members, at: root)
            guard !Task.isCancelled, editPreviewGeneration == context, session.record?.rootURL == root, sheet == .edit, !busy else { return }
            editPreviewTask = nil
            if preview.status == .confirmationRequired {
                deletion = preview.plan ?? []; deleteRequest = nil
                pendingEdit = (group, members); sheet = .delete
            }
            else if preview.status == .failed { formError = preview.message }
            else { run({ service, root, progress in await service.editGroup(group, repositories: members, at: root, progress: progress) }) }
        }
    }
    func prepareDelete(_ request: DeleteRequest) {
        guard let root = session.record?.rootURL, !busy else { return }
        let previousEdit = editPreviewTask
        cancelEditPreview()
        let previous = deletePreviewTask
        cancelDeletePreview()
        let context = deletePreviewGeneration
        deletion = []; formError = nil; deleteRequest = request; pendingEdit = nil
        sheet = .delete; deletionLoading = true
        deletePreviewTask = Task {
            await previousEdit?.value
            await previous?.value
            guard !Task.isCancelled, deletePreviewGeneration == context, session.record?.rootURL == root, sheet == .delete, !busy else { return }
            let preview = await Result(catching: { try await service.previewDelete(request, at: root) })
            guard !Task.isCancelled, deletePreviewGeneration == context, session.record?.rootURL == root, sheet == .delete, !busy else { return }
            switch preview {
            case .success(let targets): deletion = targets
            case .failure(let error): formError = error.localizedDescription
            }
            deletionLoading = false; deletePreviewTask = nil
        }
    }
    var deletionResources: [Resource] {
        if !deletion.isEmpty { return deletion.map(\.resource) }
        guard let workspace = session.record, let deleteRequest else { return [] }
        return (try? service.deleteResources(deleteRequest, record: workspace)) ?? []
    }
    var deletionPresentation: DeletionPresentation {
        dismissedDeletion ?? .init(request: deleteRequest, editingGroup: pendingEdit != nil, targets: deletion, resources: deletionResources, loading: deletionLoading)
    }
    var canConfirmDelete: Bool { sheet == .delete && !busy && !deletionLoading && !deletion.isEmpty }
    func confirmDelete() {
        guard canConfirmDelete else { return }
        let authorization = deletion
        if let edit = pendingEdit { run({ service, root, progress in await service.editGroup(edit.0, repositories: edit.1, at: root, authorization: authorization, progress: progress) }) }
        else if let request = deleteRequest { run({ service, root, progress in await service.remove(request, at: root, authorization: authorization, progress: progress) }) }
    }
    func prepareRepositoryImport(_ text: String, filename: String) {
        guard let root = session.record?.rootURL, sheet == .add, !busy else { return }
        formError = nil
        do {
            var seen = Set<String>()
            let urls = try WorkspaceService.repositoryURLs(in: text).filter { seen.insert($0).inserted }
            guard !urls.isEmpty else { throw ModuError("invalid-input", "No complete, supported Git repository URLs were found in this YAML file.") }
            repositoryImport = .init(root: root, filename: filename, urls: urls, selectedURLs: Set(urls))
            sheet = .importRepositories
        } catch { formError = error.localizedDescription }
    }
    var canConfirmRepositoryImport: Bool {
        guard sheet == .importRepositories, !busy, let repositoryImport, repositoryImport.root == session.record?.rootURL else { return false }
        return repositoryImport.urls.contains { repositoryImport.selectedURLs.contains($0) }
    }
    func confirmRepositoryImport() {
        guard canConfirmRepositoryImport, let repositoryImport else { return }
        let urls = repositoryImport.urls.filter { repositoryImport.selectedURLs.contains($0) }
        importFileName = repositoryImport.filename
        run { service, root, progress in await service.importRepositories(urls, at: root, progress: progress) }
    }
    func importWorkspace(_ text: String, filename: String) { importFileName = filename; run { service, root, progress in await service.importWorkspaceYAML(text, at: root, progress: progress) } }
    func update() { run { service, root, progress in await service.updateRepositories(at: root, progress: progress) } }

    private func cancelDeletePreview() {
        deletePreviewTask?.cancel(); deletePreviewGeneration += 1; deletionLoading = false
    }

    func cancelEditPreview() {
        editPreviewTask?.cancel(); editPreviewGeneration += 1
    }

}

enum ManagementSheet: String, Identifiable { case add, importRepositories, create, edit, delete; var id: String { rawValue } }
struct RepositoryImportSelection {
    let root: URL
    let filename: String
    let urls: [String]
    var selectedURLs: Set<String>
}
struct ManagementProgressPresentation {
    var progress: OperationProgress?
    var importFileName: String?
}
struct DeletionPresentation {
    let request: DeleteRequest?
    let editingGroup: Bool
    let targets: [DeletionTarget]
    let resources: [Resource]
    let loading: Bool
}
extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async { do { self = .success(try await body()) } catch { self = .failure(error) } }
}

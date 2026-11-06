import Foundation
import MonoDeckCore
import Observation

@MainActor @Observable
final class ManagementModel {
    private let service: WorkspaceService
    private let session: WorkspaceModel
    private let operations: OperationLifecycle
    private let presentation: OperationPresentation
    // SwiftUI can still render the closed sheet; reset its progress when the next sheet opens.
    private(set) var progressPresentation: ManagementProgressPresentation?
    var repositoryImport: RepositoryImportSelection?
    var importFileName: String?
    var formError: String? { didSet { formErrorDetails = nil } }
    var formErrorDetails: String?
    private(set) var formSession: ManagementFormSession?
    private(set) var openingFormTask: Task<Void, Never>?
    private var openingFormAction: ManagementFormAction?
    private var openingFormID = UUID()
    var sheet: ManagementSheet? {
        didSet {
            if sheet != oldValue, let action = ManagementFormAction(sheet: sheet),
               !(sheet == .add && oldValue == .importRepositories), let record = session.record {
                formSession = .init(action: action, contextID: session.contextID, record: record)
            }
            if sheet != .add, progressPresentation?.scanningRepositories == true { operations.cancel() }
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

    init(service: WorkspaceService, session: WorkspaceModel, operations: OperationLifecycle, presentation: OperationPresentation) {
        self.service = service
        self.session = session
        self.operations = operations
        self.presentation = presentation
    }

    func contextChanged(rootChanged: Bool) {
        cancelEditPreview()
        if rootChanged {
            cancelOpeningForm()
            if let formSession, formSession.contextID != session.contextID, sheet == .add || sheet == .create {
                formError = text.message(WorkspaceActionIssue.workspaceChanged)
            }
        }
        if rootChanged, progressPresentation?.scanningRepositories == true { operations.cancel() }
        if rootChanged, sheet == .delete || sheet == .importRepositories { sheet = nil }
    }

    func finishDismissal() {
        guard sheet == nil, !busy else { return }
        formSession = nil
        deleteRequest = nil; pendingEdit = nil; deletion = []
    }

    func requestForm(_ action: ManagementFormAction) {
        guard sheet == nil, presentation.result == nil, presentation.message == nil, !presentation.mainSheetVisible else { return }
        if openingFormAction == action, openingFormTask?.isCancelled == false { return }
        cancelOpeningForm()
        if let issue = session.managementIssue {
            presentEntryError(issue, action: action, contextID: session.contextID)
            return
        }
        guard let root = session.record?.rootURL else { return }
        let contextID = session.contextID
        let previous = openingFormTask
        let id = UUID(); openingFormID = id; openingFormAction = action
        openingFormTask = Task {
            defer { if openingFormID == id { openingFormTask = nil; openingFormAction = nil } }
            await previous?.value
            do {
                try Task.checkCancellation()
                let record = try await service.read(root)
                try checkActionDirectory(root)
                try await service.git.checkRepository(root, main: true)
                try Task.checkCancellation()
                guard session.contextID == contextID, sheet == nil, presentation.result == nil,
                      presentation.message == nil, !presentation.mainSheetVisible else { return }
                if let issue = session.managementIssue { throw issue }
                if action == .createGroup, record.repositories.isEmpty { throw WorkspaceActionIssue.noRepositories }
                formError = nil
                sheet = action.sheet
                formSession = .init(action: action, contextID: contextID, record: record)
            } catch {
                guard !Task.isCancelled, openingFormID == id, session.contextID == contextID,
                      !presentation.quitPending, !(error is CancellationError),
                      (error as? MonoDeckError)?.code != "cancelled" else { return }
                presentEntryError(error, action: action, contextID: contextID)
            }
        }
    }

    func cancelOpeningForm() { openingFormTask?.cancel() }

    var creationRepositories: [Repository] {
        (formSession?.record.repositories ?? session.sortedRepositories).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func presentEntryError(_ error: Error, action: ManagementFormAction, contextID: UUID) {
        presentation.enqueueActionError(error, title: text.string(action.failureTitle), contextID: contextID)
        if sheet == nil { presentation.presentNextActionMessage(in: session.contextID) }
    }

    private func validateForm(_ form: ManagementFormSession) throws {
        guard session.contextID == form.contextID, formSession?.id == form.id,
              sheet == form.action.sheet || (form.action == .addRepository && sheet == .importRepositories) else {
            throw WorkspaceActionIssue.workspaceChanged
        }
    }

    func run(_ body: @escaping @Sendable (WorkspaceService, URL, ProgressHandler) async -> OperationResult, select: Resource? = nil, members: [String]? = nil) {
        let form = sheet == .add || sheet == .create || sheet == .importRepositories ? formSession : nil
        if let form {
            do {
                try validateForm(form)
                if let issue = session.managementIssue { throw issue }
            } catch { presentError(error); return }
        }
        guard let root = session.record?.rootURL, session.canManage else { return }
        let previousEdit = editPreviewTask
        cancelEditPreview()
        cancelDeletePreview()
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
            await session.waitForReadCancellation()
            if let form {
                do {
                    try Task.checkCancellation()
                    try validateForm(form)
                    let actual = try await service.read(root)
                    try Task.checkCancellation()
                    try validateForm(form)
                    if let members {
                        let expected = form.record.repositories.filter { members.contains($0.id) }
                        try service.validateRepositorySelection(expected, repositoryIDs: members, record: actual)
                    }
                    if let issue = session.managementIssue(allowing: operationID) { throw issue }
                } catch {
                    if formSession?.id == form.id {
                        progressPresentation = nil
                        if Task.isCancelled { sheet = nil }
                        else { presentError(error) }
                    }
                    operations.finish(operationID)
                    session.startDetailPreload()
                    if presentation.quitPending { presentation.finishQuitIfPossible() }
                    return
                }
            }
            let outcome = await body(service, root, report)
            let isGroupOperation = ["group.create", "group.edit", "group.delete", "group.member.add", "group.member.delete"].contains(outcome.command)
            let noEffects = outcome.items.allSatisfy { $0.effects.isEmpty }
            if outcome.status == .failed, noEffects, sheet != nil, sheet != .delete, !presentation.quitPending {
                formError = outcome.message == nil ? outcome.items.filter { $0.message != nil }.map(text.message).joined(separator: "\n") : text.message(outcome)
                formErrorDetails = Git.sanitize(([outcome.message].compactMap { $0 } + outcome.items.compactMap(\.message)).joined(separator: "\n"))
                progressPresentation = nil
                operations.finish(operationID)
                importFileName = nil
                session.startDetailPreload()
                return
            }
            session.invalidateResources(after: outcome)
            pendingEdit = nil; deletion = []
            if outcome.command == "repo.update" {
                presentation.result = text.resultDisplayItems(outcome).isEmpty ? nil : outcome
            } else if outcome.status == .success && !presentation.quitPending {
                presentation.result = outcome.hasWarnings ? outcome : nil
                if presentation.result == nil, presentation.resultHost == .main, !isGroupOperation {
                    presentation.completionMessage = text.string(.uiCompleted)
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
            // Completed effects still need a record refresh when the business task was cancelled.
            await Task { @MainActor [self] in
                await session.refreshRecord(refreshingSidebar: false, afterLoad: { [self] in
                    guard operationGeneration == operationToken, session.record?.rootURL == root, session.selection == selectionAtCompletion else { return }
                    if let select, let workspace = session.record, service.resources(workspace).contains(select) { session.selection = select; if let group = select.groupName { session.expandedGroups.insert(group) } }
                    else if let last = outcome.items.last(where: { $0.data?["disposition"] == "added" }), outcome.command == "repo.import" { session.selection = last.resource }
                })
            }.value
        }
        operations.attach(task, to: operationID)
    }
    func add(_ url: String, displayName: String) {
        guard formSession?.action == .addRepository, sheet == .add else { presentError(WorkspaceActionIssue.workspaceChanged); return }
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        run({ service, root, progress in
            await service.addRepository(.init(url: url, displayNameOverride: displayName.isEmpty ? nil : displayName), at: root, progress: progress)
        }, select: try? Resource.repository(RepositoryIdentity(url).id))
    }
    func create(_ group: String, members: [String]) {
        guard let formSession, formSession.action == .createGroup, sheet == .create else { presentError(WorkspaceActionIssue.workspaceChanged); return }
        let expected = formSession.record.repositories.filter { members.contains($0.id) }
        run({ service, root, progress in await service.createGroup(group, repositoryIDs: members, at: root, expectedRepositories: expected, progress: progress) }, select: .group(group), members: members)
    }
    func edit(_ group: String, members: [String]) {
        guard let root = session.record?.rootURL, session.canManage else { return }
        let previous = editPreviewTask
        cancelEditPreview()
        let context = editPreviewGeneration
        formError = nil
        editPreviewTask = Task {
            await previous?.value
            guard !Task.isCancelled, editPreviewGeneration == context, session.record?.rootURL == root, sheet == .edit, !busy else { return }
            let preview = await service.editGroupPreview(group, repositoryIDs: members, at: root)
            guard !Task.isCancelled, editPreviewGeneration == context, session.record?.rootURL == root, sheet == .edit, !busy else { return }
            editPreviewTask = nil
            if preview.status == .confirmationRequired {
                deletion = preview.plan?.deletions ?? []; deleteRequest = nil
                pendingEdit = (group, members); sheet = .delete
            }
            else if preview.status == .failed { formError = text.message(preview); formErrorDetails = preview.message.map(Git.sanitize) }
            else { run({ service, root, progress in await service.editGroup(group, repositoryIDs: members, at: root, progress: progress) }) }
        }
    }
    func prepareDelete(_ request: DeleteRequest) {
        guard let root = session.record?.rootURL, session.canManage else { return }
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
            let preview = await Result(catching: {
                try await service.previewDelete(request, at: root) { [self] target in
                    await MainActor.run {
                        guard !Task.isCancelled, deletePreviewGeneration == context, session.record?.rootURL == root, sheet == .delete, !busy else { return }
                        deletion.append(target)
                    }
                }
            })
            guard !Task.isCancelled, deletePreviewGeneration == context, session.record?.rootURL == root, sheet == .delete, !busy else { return }
            switch preview {
            case .success(let targets): deletion = targets
            case .failure(let error): deletion = []; presentError(error)
            }
            deletionLoading = false; deletePreviewTask = nil
        }
    }
    var deletionResources: [Resource] {
        if let workspace = session.record, let deleteRequest,
           let resources = try? service.deleteResources(deleteRequest, record: workspace) { return resources }
        return deletion.map(\.resource)
    }
    var deletionPresentation: DeletionPresentation {
        dismissedDeletion ?? .init(request: deleteRequest, editingGroup: pendingEdit != nil, targets: deletion, resources: deletionResources)
    }
    var canConfirmDelete: Bool { sheet == .delete && !busy && !deletionLoading && !deletion.isEmpty }
    func confirmDelete() {
        guard canConfirmDelete else { return }
        let authorization = deletion
        if let edit = pendingEdit { run({ service, root, progress in await service.editGroup(edit.0, repositoryIDs: edit.1, at: root, authorization: authorization, progress: progress) }) }
        else if let request = deleteRequest { run({ service, root, progress in await service.delete(request, at: root, authorization: authorization, progress: progress) }) }
    }
    func prepareRepositoryImport(_ text: String, filename: String) {
        guard let root = session.record?.rootURL, sheet == .add, session.canManage else { return }
        formError = nil
        do {
            var seen = Set<String>()
            let urls = try WorkspaceService.repositoryURLs(in: text).filter { seen.insert($0).inserted }
            guard !urls.isEmpty else { throw MonoDeckError("invalid-input", .noCompleteSupportedGitRepositoryURLsWereFound) }
            repositoryImport = .init(root: root, filename: filename, urls: urls, selectedURLs: Set(urls))
            sheet = .importRepositories
        } catch { presentError(error) }
    }
    func prepareLocalRepositoryImport(_ directories: [URL]) {
        guard let root = session.record?.rootURL, sheet == .add, session.canManage, !directories.isEmpty,
              let operationID = operations.begin(.management) else { return }
        formError = nil
        progressPresentation = .init(scanningRepositories: true)
        let report: ProgressHandler = { [self] progress in Task { @MainActor in
            guard operations.isCurrent(operationID), session.record?.rootURL == root, sheet == .add else { return }
            operations.report(progress, for: operationID)
            progressPresentation?.progress = progress
        } }
        let task = Task {
            await session.waitForReadCancellation()
            let outcome = await Result(catching: { try await service.scanLocalRepositories(in: directories, at: root, progress: report) })
            guard operations.isCurrent(operationID) else { return }
            operations.finish(operationID)
            progressPresentation = nil
            if presentation.quitPending { presentation.finishQuitIfPossible(); return }
            guard !Task.isCancelled, session.record?.rootURL == root, sheet == .add else { return }
            switch outcome {
            case .success(let scan):
                if scan.urls.isEmpty {
                    formError = text.string(.uiNoRepositoriesWithAccessibleRemoteAndValidDefault)
                } else {
                    repositoryImport = .init(root: root, filename: text.string(.uiLocalRepositories), urls: scan.urls, selectedURLs: Set(scan.urls))
                    sheet = .importRepositories
                }
            case .failure(let error):
                if MonoDeckError.wrap(error).code != "cancelled" { presentError(error) }
            }
        }
        operations.attach(task, to: operationID)
    }
    var canConfirmRepositoryImport: Bool {
        guard sheet == .importRepositories, session.canManage, let repositoryImport, repositoryImport.root == session.record?.rootURL else { return false }
        return repositoryImport.urls.contains { repositoryImport.selectedURLs.contains($0) }
    }
    func confirmRepositoryImport() {
        guard canConfirmRepositoryImport, let repositoryImport else { return }
        let urls = repositoryImport.urls.filter { repositoryImport.selectedURLs.contains($0) }
        importFileName = repositoryImport.filename
        run { service, root, progress in await service.importRepositories(urls, at: root, progress: progress) }
    }
    func importWorkspace(_ text: String, filename: String) { importFileName = filename; run { service, root, progress in await service.importWorkspaceYAML(text, at: root, progress: progress) } }
    func updateRepositories() { run { service, root, progress in await service.updateRepositories(at: root, progress: progress) } }

    func presentError(_ error: Error) {
        formError = text.message(error)
        if !(error is WorkspaceActionIssue) { formErrorDetails = Git.sanitize(error.localizedDescription) }
    }

    private func cancelDeletePreview() {
        if deletionLoading { deletion = [] }
        deletePreviewTask?.cancel(); deletePreviewGeneration += 1; deletionLoading = false
    }

    func cancelEditPreview() {
        editPreviewTask?.cancel(); editPreviewGeneration += 1
    }

}

enum ManagementSheet: String, Identifiable { case add, importRepositories, create, edit, delete; var id: String { rawValue } }
enum ManagementFormAction {
    case addRepository, createGroup

    init?(sheet: ManagementSheet?) {
        switch sheet {
        case .add: self = .addRepository
        case .create: self = .createGroup
        default: return nil
        }
    }

    var sheet: ManagementSheet { self == .addRepository ? .add : .create }
    var failureTitle: LocalizedStringResource {
        self == .addRepository ? .uiCanTAddRepository : .init("action.cannotCreateGroup", defaultValue: "Can’t Create Group")
    }
}
struct ManagementFormSession {
    let id = UUID()
    let action: ManagementFormAction
    let contextID: UUID
    let record: WorkspaceRecord
}
struct RepositoryImportSelection {
    let root: URL
    let filename: String
    let urls: [String]
    var selectedURLs: Set<String>
}
struct ManagementProgressPresentation {
    var progress: OperationProgress?
    var importFileName: String?
    var scanningRepositories = false
}
struct DeletionPresentation {
    let request: DeleteRequest?
    let editingGroup: Bool
    let targets: [DeletionTarget]
    let resources: [Resource]
}
extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async { do { self = .success(try await body()) } catch { self = .failure(error) } }
}

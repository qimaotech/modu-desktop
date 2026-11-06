import Foundation
import MonoDeckCore
import Observation

@MainActor @Observable
final class OperationPresentation {
    private let preferences: AppPreferences
    private let operations: OperationLifecycle
    private let terminate: () -> Void
    var result: OperationResult? { didSet { isMaintenanceFailure = false } }
    var resultHost = ResultHost.main
    private(set) var isMaintenanceFailure = false
    var mainSheetVisible = false
    var message: String? { didSet { if message == nil { presentedActionMessage = nil } } }
    var messageTitle: String?
    var messageHost = ResultHost.main
    var completionMessage: String?
    var quitPending = false
    private(set) var actionMessages: [ActionMessage] = []
    private var presentedActionMessage: ActionMessage?
    var text: InterfaceText { preferences.text }
    private var progress: OperationProgress? { operations.progress }
    private var cancelling: Bool { operations.cancelling }
    private var openingWorkspace: Bool { operations.kind == .workspace }

    init(preferences: AppPreferences, operations: OperationLifecycle, terminate: @escaping () -> Void) {
        self.preferences = preferences
        self.operations = operations
        self.terminate = terminate
    }

    func dismissResult() {
        result = nil; resultHost = .main
        if quitPending { terminate() }
    }

    func presentMaintenanceFailure(_ result: OperationResult) {
        self.result = result; resultHost = .main; isMaintenanceFailure = true
    }

    func presentMessage(_ message: String, title: String, host: ResultHost = .main) {
        presentedActionMessage = nil
        messageTitle = title; messageHost = host; self.message = message
    }

    func presentMessage(_ error: Error, title: String, host: ResultHost = .main) {
        presentMessage(text.message(error) + "\n\n" + text.string(.uiDetails) + ":\n" + Git.sanitize(error.localizedDescription), title: title, host: host)
    }

    func enqueueActionError(_ error: Error, title: String, contextID: UUID, target: String? = nil) {
        var body = text.message(error)
        if !(error is WorkspaceActionIssue) {
            let diagnostic = Git.sanitize(error.localizedDescription)
            if !diagnostic.isEmpty, diagnostic != body { body += "\n\n" + text.string(.uiDetails) + ":\n" + diagnostic }
        }
        if let target { body = target + "\n\n" + body }
        let allowsDuringQuit: Bool
        if case .quitting? = error as? WorkspaceActionIssue { allowsDuringQuit = true }
        else { allowsDuringQuit = false }
        let value = ActionMessage(title: title, body: body, contextID: contextID, allowsDuringQuit: allowsDuringQuit)
        guard value != presentedActionMessage, !actionMessages.contains(value) else { return }
        actionMessages.append(value)
    }

    func discardActionMessages(outside contextID: UUID) {
        actionMessages.removeAll { $0.contextID != contextID }
        if let presentedActionMessage, presentedActionMessage.contextID != contextID { message = nil }
    }

    func presentNextActionMessage(in contextID: UUID) {
        discardActionMessages(outside: contextID)
        guard message == nil, result == nil, !mainSheetVisible, let value = nextActionMessage(in: contextID) else { return }
        actionMessages.removeAll { $0.id == value.id }
        presentMessage(value.body, title: value.title)
        presentedActionMessage = value
    }

    func nextActionMessage(in contextID: UUID) -> ActionMessage? {
        actionMessages.first { $0.contextID == contextID && (!quitPending || $0.allowsDuringQuit) }
    }

    func finishQuitIfPossible() {
        if quitPending, result == nil { terminate() }
    }

    var operationProgressPhaseText: String {
        operationProgressPhaseText(for: progress)
    }

    func operationProgressPhaseText(for progress: OperationProgress?) -> String {
        if cancelling {
            if progress?.cancellable == false { return text.string(.uiFinishingCurrentItemBeforeCancellation) }
            return text.string(.uiCancelling)
        }
        return progress.map { text.statusText($0.phase.rawValue) } ?? text.string(.uiWorking)
    }

    func operationProgressSummaryText(for progress: OperationProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        var parts = [text.string(.uiOfProcessed(Int(progress.completed), Int(progress.total)))]
        if let counts = progress.counts {
            if counts.skipped > 0 { parts.append(text.string(.uiSkipped("\(counts.skipped)"))) }
            if counts.failed > 0 { parts.append(text.string(.uiFailed("\(counts.failed)"))) }
        }
        return parts.joined(separator: " · ")
    }

    var repositoryUpdateProgressText: String {
        let title = cancelling ? text.string(.uiCancelling) : openingWorkspace ? text.string(.uiReloadingWorkspace) : text.string(.uiUpdatingRepositories)
        guard let progress, progress.total > 0 else { return title }
        return "\(title) · \(progress.completed)/\(progress.total)"
    }

}

struct ActionMessage: Equatable {
    let id = UUID()
    let title: String
    let body: String
    let contextID: UUID
    let allowsDuringQuit: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.body == rhs.body && lhs.contextID == rhs.contextID
    }
}

enum ResultHost { case main, settings, setup }

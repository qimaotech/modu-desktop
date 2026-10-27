import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class OperationPresentation {
    private let preferences: AppPreferences
    private let operations: OperationLifecycle
    private let terminate: () -> Void
    var result: OperationResult?
    var resultHost = ResultHost.main
    var message: String?
    var messageTitle: String?
    var messageHost = ResultHost.main
    var completionMessage: String?
    var quitPending = false
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

    func presentMessage(_ message: String, title: String, host: ResultHost = .main) {
        messageTitle = title; messageHost = host; self.message = message
    }

    func presentMessage(_ error: Error, title: String, host: ResultHost = .main) {
        presentMessage(text.message(error) + "\n\n" + text.string(.uiDetails) + ":\n" + Git.sanitize(error.localizedDescription), title: title, host: host)
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

enum ResultHost { case main, settings, setup }

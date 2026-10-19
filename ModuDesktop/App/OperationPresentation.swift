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
    var text: InterfaceText { .init(language: preferences.language) }
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

    func finishQuitIfPossible() {
        if quitPending, result == nil { terminate() }
    }

    private func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

    var operationProgressPhaseText: String {
        operationProgressPhaseText(for: progress)
    }

    func operationProgressPhaseText(for progress: OperationProgress?) -> String {
        if cancelling, progress?.cancellable != false { return t("Cancelling…", "正在取消…") }
        return progress.map { text.statusText($0.phase.rawValue) } ?? t("Working…", "正在处理…")
    }

    var operationProgressSummaryText: String? {
        operationProgressSummaryText(for: progress)
    }

    func operationProgressSummaryText(for progress: OperationProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        var parts = [t("\(progress.completed) of \(progress.total) processed", "已处理 \(progress.completed) / \(progress.total)")]
        if let counts = progress.counts {
            if counts.skipped > 0 { parts.append(t("Skipped \(counts.skipped)", "已跳过 \(counts.skipped)")) }
            if counts.failed > 0 { parts.append(t("Failed \(counts.failed)", "失败 \(counts.failed)")) }
        }
        return parts.joined(separator: " · ")
    }

    var repositoryUpdateProgressText: String {
        let title = cancelling ? t("Cancelling…", "正在取消…") : openingWorkspace ? t("Reloading workspace", "正在重新加载工作区") : t("Updating repositories", "正在更新仓库")
        guard let progress, progress.total > 0 else { return title }
        return "\(title) · \(progress.completed)/\(progress.total)"
    }

}

enum ResultHost { case main, settings, setup }

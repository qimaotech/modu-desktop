import SwiftUI
import AppKit
import ModuCore

struct ResultView: View {
    var text: InterfaceText
    var result: OperationResult
    var retry: (() -> Void)? = nil
    var dismiss: () -> Void
    var body: some View {
        if result.reasonCode == "workspace-not-empty" {
            VStack(alignment: .leading, spacing: 16) {
                resultHeader
                if let workspace = result.workspace { Text(text.string(.uiWorkspace2) + (workspace as NSString).abbreviatingWithTildeInPath).font(DialogTypography.path).textSelection(.enabled) }
                Text(text.string(.uiWorkspaceMustHaveNoRegisteredRepositoriesOrWorktree))
                Text(text.string(.uiChooseAnotherWorkspaceInSettingsThenTryAgain))
                Divider()
                Button(text.string(.uiOk), action: dismiss).keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
            }.font(DialogTypography.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background)
        } else {
            resultContents
        }
    }
    private var resultHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: resultSymbol).font(DialogTypography.body).foregroundStyle(resultColor).accessibilityHidden(true)
            Text(result.reasonCode == "workspace-not-empty" ? text.string(.uiCanTImportIntoWorkspace) : text.resultTitle(result)).font(DialogTypography.title)
        }
    }
    private var resultSymbol: String {
        if result.status == .success, result.hasWarnings { return "exclamationmark.triangle" }
        return switch result.status {
        case .success: "checkmark.circle"
        case .cancelled: "stop.circle"
        case .skipped: "info.circle"
        case .failed: "xmark.circle"
        default: "exclamationmark.triangle"
        }
    }
    private var resultColor: Color {
        if result.status == .success, result.hasWarnings { return .orange }
        return switch result.status {
        case .success: .green
        case .failed: .red
        case .cancelled, .skipped: .secondary
        default: .orange
        }
    }
    private var resultContents: some View {
        let items = text.resultDisplayItems(result)
        return VStack(alignment: .leading, spacing: result.command == "repo.update" ? 12 : 16) {
            VStack(alignment: .leading, spacing: result.command == "repo.update" ? 4 : 6) {
                resultHeader
                if let summary = text.resultSummaryText(result) {
                    Text(summary).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary).monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if result.command == "workspace.open", let workspace = result.workspace { Text(workspace).font(DialogTypography.path) }
                    if let raw = result.message { IssueDescriptionView(message: text.message(result), details: Git.sanitize(raw), text: text) }
                    if result.command == "repo.update", !items.isEmpty {
                        RepositoryUpdateResultsView(text: text, result: result)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            itemContents(item, count: items.count)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 360)
            Divider()
            HStack {
                if let retry {
                    Button(text.string(.uiChooseAnother), action: retry)
                    Spacer()
                    Button(text.string(.uiCancel), role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                } else {
                    Button(text.string(.uiOk), action: dismiss).keyboardShortcut(.defaultAction)
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.font(DialogTypography.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background)
    }

    private func itemContents(_ item: ItemResult, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if result.command != "workspace.open" {
                Text(item.resource.path).font(DialogTypography.path)
                if result.command != "repo.add" || count > 1 || result.status != .failed {
                    Text(text.resultStatus(item)).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                }
            }
            let message = text.resultMessage(item, overallMessage: result.message, command: result.command)
            if let message { Text(message).foregroundStyle(DesignStyle.secondary) }
            ForEach(text.effectSummaries(item, workspace: result.workspace), id: \.self) { Text($0).font(DialogTypography.auxiliary) }
            if let trash = item.trashPath { Text(text.string(.uiTrash2(trash))).font(DialogTypography.path) }
            let errorDetails = item.message.flatMap { raw in message != nil && message != raw ? Git.sanitize(raw) : nil }
            if !item.effects.isEmpty || errorDetails != nil {
                DisclosureGroup(text.string(.uiDetails)) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let errorDetails { Text(errorDetails) }
                        ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
                            Text("\(text.statusText(effect.action)): \(effect.target) [\(text.statusText(effect.state))]")
                        }
                    }.font(DialogTypography.path).frame(maxWidth: .infinity, alignment: .leading)
                }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
            }
        }
    }
}

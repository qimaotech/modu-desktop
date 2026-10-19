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
                if let workspace = result.workspace { Text(text.t("Workspace: ", "工作区：") + (workspace as NSString).abbreviatingWithTildeInPath).textSelection(.enabled) }
                Text(text.t("The workspace must have no registered repositories or worktree groups, and no content in its repositories or worktrees folders.", "工作区不能包含已登记的仓库或工作树组，repositories 和 worktrees 目录也必须为空。"))
                Text(text.t("Choose another workspace in Settings, then try again. Your files and configuration have not been changed.", "请在设置中选择其他工作区后重试。你的文件和配置未被修改。"))
                Divider()
                Button(text.t("OK", "好"), action: dismiss).keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
            }.font(.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background)
        } else {
            resultContents
        }
    }
    private var resultHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: resultSymbol).font(.body).foregroundStyle(resultColor).accessibilityHidden(true)
            Text(result.reasonCode == "workspace-not-empty" ? text.t("Can’t import into this workspace", "无法导入此工作区") : text.resultTitle(result)).font(.headline)
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
                    Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if result.command == "workspace.open", let workspace = result.workspace { Text(workspace).font(.system(.caption, design: .monospaced)) }
                    if let message = result.message { Text(message) }
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
                    Button(text.t("Choose Another…", "重新选择…"), action: retry)
                    Spacer()
                    Button(text.t("Cancel", "取消"), role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                } else {
                    Button(text.t("OK", "好"), action: dismiss).keyboardShortcut(.defaultAction)
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background)
    }

    private func itemContents(_ item: ItemResult, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if result.command != "workspace.open" {
                Text(item.resource.path).font(.system(.body, design: .monospaced))
                if result.command != "repo.add" || count > 1 || result.status != .failed {
                    Text(text.resultStatus(item)).font(.caption).foregroundStyle(.secondary)
                }
            }
            let message = text.resultMessage(item, overallMessage: result.message, command: result.command)
            if let message { Text(message).foregroundStyle(.secondary) }
            ForEach(text.effectSummaries(item, workspace: result.workspace), id: \.self) { Text($0).font(.caption) }
            if let trash = item.trashPath { Text(text.t("Trash: ", "废纸篓：") + trash).font(.system(.caption, design: .monospaced)) }
            let errorDetails = item.message.flatMap { raw in !item.hasWarning && message != nil && message != raw ? Git.sanitize(raw) : nil }
            if !item.effects.isEmpty || errorDetails != nil {
                DisclosureGroup(text.t("Details", "详细信息")) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let errorDetails { Text(errorDetails) }
                        ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
                            Text("\(effect.action): \(effect.target) [\(effect.state)]")
                        }
                    }.font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(.secondary)
            }
        }
    }
}

import SwiftUI
import AppKit
import ModuCore

struct OperationProgressView: View {
    var operations: OperationLifecycle
    var operationPresentation: OperationPresentation
    let title: String
    var context: String?
    var keepsCompletedItems = true
    var presentation: ManagementProgressPresentation? = nil
    private var progress: OperationProgress? { presentation?.progress ?? operations.progress }
    private var phaseText: String { operationPresentation.operationProgressPhaseText(for: progress) }
    private var summaryText: String? { operationPresentation.operationProgressSummaryText(for: progress) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let context {
                    Text(context).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(context)
                }
            }
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).frame(width: 20, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress?.target ?? " ").font(.system(.body, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).help(progress?.target ?? "")
                    Text(phaseText).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 36)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    } else { ProgressView() }
                }.progressViewStyle(.linear).controlSize(.small)
                    .accessibilityLabel(title).accessibilityValue(summaryText ?? phaseText)
                Text(summaryText ?? " ").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityHidden(summaryText == nil)
            }
            Divider()
            HStack(spacing: 12) {
                if keepsCompletedItems {
                    Text(operationPresentation.text.t("Completed items are kept when cancelled.", "取消后保留已完成项。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(operationPresentation.text.t("Cancel", "取消")) { operations.cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(!operations.busy || operations.cancelling || progress?.cancellable == false)
            }.controlSize(.regular)
        }.font(.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background).interactiveDismissDisabled(operations.busy)
    }
}

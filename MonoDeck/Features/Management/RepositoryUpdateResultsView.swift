import SwiftUI
import MonoDeckCore

struct RepositoryUpdateResultsView: View {
    var text: InterfaceText
    var result: OperationResult
    static let resultColumnWidth: CGFloat = 96

    var body: some View {
        let items = text.resultDisplayItems(result)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(text.string(.uiRepository)).frame(maxWidth: .infinity, alignment: .leading)
                Text(text.string(.uiResult)).padding(.leading, 6)
                    .frame(width: Self.resultColumnWidth, alignment: .leading)
            }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary).padding(.bottom, 6)
            Divider()
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                RepositoryUpdateResultRow(text: text, item: item, workspace: result.workspace)
                if index < items.count - 1 { Divider() }
            }
        }
    }
}

struct RepositoryUpdateResultRow: View {
    var text: InterfaceText
    var item: ItemResult
    var workspace: String?
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Text(repositoryID).font(DialogTypography.body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .help(fullPath)
            Button { showingDetails.toggle() } label: {
                Label(statusLabel, systemImage: status.symbolName)
                    .font(DialogTypography.auxiliary)
                    .padding(.horizontal, 6).frame(minHeight: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverPlainButtonStyle(shape: RoundedRectangle(cornerRadius: 6), foreground: status.color, hoverForeground: status.color))
            .background(showingDetails ? DesignStyle.field : .clear, in: RoundedRectangle(cornerRadius: 6))
            .textSelection(.disabled)
            .help(text.string(.uiViewDetails))
            .accessibilityIdentifier("repo-update-status-\(item.resource.id)")
            .accessibilityValue(text.string(showingDetails ? .uiExpanded : .uiCollapsed))
            .accessibilityHint(text.string(.uiViewDetails))
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                RepositoryUpdateResultPopover(text: text, item: item, fullPath: fullPath)
                    .onExitCommand { showingDetails = false }
            }
            .fixedSize()
            .frame(width: RepositoryUpdateResultsView.resultColumnWidth, alignment: .leading)
        }.padding(.vertical, 4)
    }

    var repositoryID: String { item.resource.repositoryID ?? (item.resource.path as NSString).lastPathComponent }
    var fullPath: String { workspace.map { URL(fileURLWithPath: $0).appending(path: item.resource.path).path } ?? item.resource.path }
    var status: RepositoryUpdateResultStatus { .init(item) }
    var statusLabel: String { text.resultStatus(item) }
}

struct RepositoryUpdateResultPopover: View {
    var text: InterfaceText
    var item: ItemResult
    var fullPath: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            details
        }
        .font(DialogTypography.auxiliary).padding(16).frame(width: 420)
        .textSelection(.enabled)
        // Focus the container, not the scroll view, so Escape stays within the popover.
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .accessibilityIdentifier("repo-update-details-\(item.resource.id)")
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let message { Text(message).font(DialogTypography.body) }
                Text(fullPath).font(DialogTypography.path).foregroundStyle(DesignStyle.secondary)
                if !item.effects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(text.statusText(effect.action))
                                    Spacer()
                                    Text(text.statusText(effect.state)).foregroundStyle(DesignStyle.secondary)
                                }
                                if effect.target != item.resource.path, effect.target != fullPath {
                                    Text(effect.target).font(DialogTypography.path).foregroundStyle(DesignStyle.secondary)
                                }
                            }
                        }
                    }
                }
                if let head = item.data?["actual-head"] { Text("HEAD: \(head)").font(DialogTypography.path) }
                if let workingTree = item.data?["working-tree"] {
                    Text(text.string(.uiWorkingTree2(text.statusText(workingTree == "clean" ? "Clean" : "Dirty"))))
                }
                if let diagnostic {
                    Divider()
                    Text(diagnostic).font(DialogTypography.path).foregroundStyle(DesignStyle.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 300)
    }

    private var message: String? { text.resultMessage(item, overallMessage: nil).map { Git.sanitize($0) } }
    private var diagnostic: String? {
        guard let raw = item.message else { return nil }
        let sanitized = Git.sanitize(raw)
        return sanitized.isEmpty || sanitized == message ? nil : sanitized
    }
}

enum RepositoryUpdateResultStatus: Equatable {
    case updated, failed

    init(_ item: ItemResult) {
        self = item.status == .failed ? .failed : .updated
    }

    var symbolName: String {
        switch self {
        case .updated: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .updated: .blue
        case .failed: .red
        }
    }
}

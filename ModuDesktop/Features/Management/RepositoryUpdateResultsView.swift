import SwiftUI
import AppKit
import ModuCore

struct RepositoryUpdateResultsView: View {
    var text: InterfaceText
    var result: OperationResult
    static let resultColumnWidth: CGFloat = 64

    var body: some View {
        let items = text.resultDisplayItems(result)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(text.t("Repository", "仓库")).frame(maxWidth: .infinity, alignment: .leading)
                Text(text.t("Result", "结果")).frame(width: Self.resultColumnWidth)
            }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(repositoryName).font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                    .help(fullPath)
                Image(systemName: status.symbolName).font(.system(size: 16))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(status.color)
                    .frame(width: RepositoryUpdateResultsView.resultColumnWidth, height: 16)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + repositoryFont.capHeight / 2
                    }
                    .accessibilityLabel(statusLabel)
                    .accessibilityIdentifier("repo-update-status-\(item.resource.id)")
                    .help(statusLabel)
            }
            if let message = text.resultMessage(item, overallMessage: nil, command: "repo.update") {
                Text(message).foregroundStyle(.secondary)
            }
            ForEach(visibleEffects, id: \.self) { Text($0).font(.caption) }
            DisclosureGroup(text.t("Details", "详细信息")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fullPath)
                    ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
                        Text("\(effect.action): \(effect.target) [\(effect.state)]")
                    }
                    if let head = item.data?["actual-head"] { Text("HEAD: \(head)") }
                    if let workingTree = item.data?["working-tree"] {
                        Text(text.t("Working tree: ", "工作树：") + text.statusText(workingTree == "clean" ? "Clean" : "Dirty"))
                    }
                }.font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disclosureGroupStyle(RepositoryResultDetailsStyle(
                identifier: "repo-update-details-\(item.resource.id)",
                expandedLabel: text.t("Expanded", "已展开"), collapsedLabel: text.t("Collapsed", "已折叠")))
            .font(.callout).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    var repositoryName: String { item.resource.repo ?? (item.resource.path as NSString).lastPathComponent }
    var fullPath: String { workspace.map { URL(fileURLWithPath: $0).appending(path: item.resource.path).path } ?? item.resource.path }
    var status: RepositoryUpdateResultStatus { .init(item) }
    var statusLabel: String { text.resultStatus(item) }
    var visibleEffects: [String] { item.status == .success ? [] : text.effectSummaries(item, workspace: workspace) }

    private var repositoryFont: NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize, weight: .regular)
    }
}

struct RepositoryResultDetailsStyle: DisclosureGroupStyle {
    var identifier: String
    var expandedLabel: String
    var collapsedLabel: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 8, height: 12).accessibilityHidden(true)
                    configuration.label
                }.frame(maxWidth: .infinity, minHeight: 15, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).textSelection(.disabled)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(configuration.isExpanded ? expandedLabel : collapsedLabel)
            if configuration.isExpanded { configuration.content.padding(.leading, 12) }
        }
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

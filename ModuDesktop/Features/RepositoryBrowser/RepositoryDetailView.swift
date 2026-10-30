import SwiftUI
import AppKit
import ModuCore

struct RepositoryDetailView: View {
    @Bindable var workspace: WorkspaceModel
    var preferences: AppPreferences
    var tools: [ExternalTool]
    var preferredToolIDs: [String: String]
    var openTool: (ExternalTool) -> Void
    @State private var collapsed = Set<String>()

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                ToolBarView(tools: tools, preferredToolIDs: preferredToolIDs, directory: workspace.currentURL, gitUnavailable: workspace.selection.map { workspace.states[$0.id]?.available == false } == true, text: preferences.text, open: openTool, availableWidth: geometry.size.width - 36)
                    .textSelection(.disabled)
                VStack(spacing: 12) {
                    summary(compact: geometry.size.width < 760)
                    if showsChanges && showsCommits { GitSplitView(upper: changesSection, lower: commitsSection, defaults: preferences.defaults) }
                    else if showsChanges { changesSection }
                    else if showsCommits { commitsSection }
                    else { Spacer() }
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.overlay(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                if workspace.detailLoading, workspace.detail.changes == nil, workspace.detail.changesError == nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel(preferences.text.string(.uiLoadingChanges))
                }
                if workspace.detailLoading, workspace.detail.commits == nil, workspace.detail.commitsError == nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel(preferences.text.string(.uiLoadingCommits))
                }
            }.allowsHitTesting(false)
        }.textSelection(.enabled)
            .onChange(of: workspace.selection) { collapsed.removeAll() }
    }

    var showsChanges: Bool { workspace.detail.changes?.isEmpty == false || workspace.detail.changesError != nil }
    var showsCommits: Bool { workspace.detail.summary?.baseOID != nil && workspace.detail.commits?.isEmpty == false }

    private func summary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workspace.selection?.path ?? "").font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                .help(workspace.currentURL?.path ?? "").accessibilityValue(workspace.currentURL?.path ?? "")
                .frame(height: 22)
            if let summary = workspace.detail.summary {
                HStack(spacing: compact ? 8 : 12) {
                    if summary.hasRemotes {
                        HStack(spacing: 6) {
                            DesignIcon(name: "BaseBranch", size: 14)
                            Text(preferences.text.string(.uiBaseBranch)).font(.system(size: 12)).foregroundStyle(DesignStyle.secondary)
                            Text(summary.base ?? preferences.text.string(.uiUnavailable)).fontWeight(.medium).help(preferences.text.baseBranchHelp(summary))
                        }.fixedSize()
                        Rectangle().fill(DesignStyle.border).frame(width: 1, height: 14)
                    }
                    HStack(spacing: 6) {
                        DesignIcon(name: "HeadBranch", size: 14)
                        Text(preferences.text.string(.uiHeadBranch)).font(.system(size: 12)).foregroundStyle(DesignStyle.secondary).fixedSize()
                        Text(summary.head).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(summary.head)
                    }
                    if let commits = workspace.detail.behindCommits, !commits.isEmpty, let base = summary.base {
                        Rectangle().fill(DesignStyle.border).frame(width: 1, height: 14)
                        BehindCommitsButton(base: base, commits: commits, text: preferences.text)
                            .id("\(workspace.record?.root ?? "")|\(workspace.selection?.id ?? "")|\(summary.headOID)|\(summary.baseOID ?? "")")
                    } else if let error = workspace.detail.comparisonError {
                        Rectangle().fill(DesignStyle.border).frame(width: 1, height: 14)
                        Text(preferences.text.string(.uiBranchComparisonUnavailable)).foregroundStyle(DesignStyle.secondary)
                            .lineLimit(1).help(preferences.text.message(error))
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 13)).frame(height: 22)
            } else if let error = workspace.detail.summaryError { IssueDescriptionView(message: preferences.text.message(error), details: error.message, text: preferences.text).foregroundStyle(.secondary) }
            else { Color.clear.frame(height: 22).accessibilityElement()
                .accessibilityLabel(preferences.text.string(.uiLoadingSummary)) }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).detailCard()
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preferences.text.string(.uiChanges)).font(.system(size: 13)).frame(height: 22)
            if let error = workspace.detail.changesError { unavailable(error) }
            else if let changes = workspace.detail.changes {
                let rows = ChangeNode.tree(changes).flatMap { $0.visibleRows(collapsed: collapsed) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            changeRow(row.node, depth: row.depth)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(idealHeight: CGFloat(rows.count) * 22, maxHeight: CGFloat(rows.count) * 22)
                    .padding(.leading, -6)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
    }

    private func changeRow(_ node: ChangeNode, depth: Int) -> some View {
        HStack(spacing: 0) {
            if node.children != nil {
                Button {
                    if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                } label: {
                    DisclosureIcon(expanded: !collapsed.contains(node.id))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).accessibilityLabel(preferences.text.string(.uiExpandOrCollapse) + " " + node.name)
            } else { Color.clear.frame(width: 20, height: 20) }
            HStack(spacing: 6) {
                if let change = node.change {
                    status(change.index, conflict: change.conflict, staged: true)
                    status(change.workingTree, conflict: change.conflict, staged: false)
                } else { DesignIcon(name: "ChangeTreeFolder") }
                Text(node.name).font(.system(size: 13)).lineLimit(1)
                    .help(node.change?.originalPath.map { "\($0) → \(node.id)" } ?? node.id)
                Spacer(minLength: 0)
            }
        }.padding(.leading, CGFloat(depth) * 14).frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.change.map { "\($0.path), \(preferences.text.string(.uiStaged)): \(preferences.text.fileStatus($0.index)), \(preferences.text.string(.uiUnstaged)): \(preferences.text.fileStatus($0.workingTree))" } ?? node.id)
        .contextMenu {
            Button(preferences.text.string(.uiRevealInFinder)) {
                if let url = safeChangedPath(node.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.textSelection(.disabled).disabled(safeChangedPath(node.id) == nil)
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preferences.text.string(.uiCommits)).font(.system(size: 13)).frame(height: 22)
            if let commits = workspace.detail.commits {
                let contentHeight = CGFloat(commits.count) * 22 + (workspace.detail.canLoadMore ? 32 : 0)
                let columnWidths = commitColumnWidths(commits)
                GeometryReader { geometry in
                    let columnSpacing = min(36, max(12, 12 + (geometry.size.width - 640) / 20))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                                HStack(spacing: 2) {
                                    CommitLaneView(index: index, count: commits.count, rowHeight: 22)
                                        .offset(x: 1)
                                    HStack(spacing: columnSpacing) {
                                        Text(commit.subject).truncationMode(.tail)
                                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutPriority(-1).help(commit.subject)
                                        Text(commit.author).font(.system(size: 12)).foregroundStyle(DesignStyle.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: columnWidths.author, alignment: .leading).help(commit.author)
                                        Text(commit.displayDate(locale: preferences.activeLocale)).font(.system(size: 12)).foregroundStyle(DesignStyle.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: columnWidths.date, alignment: .leading).help(commit.date)
                                        Text(String(commit.id.prefix(7))).font(.system(size: 12, design: .monospaced)).foregroundStyle(DesignStyle.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: columnWidths.hash, alignment: .trailing).help(commit.id)
                                    }.lineLimit(1)
                                }.font(.system(size: 13)).frame(height: 22)
                                    .accessibilityElement(children: .combine)
                            }
                            if workspace.detail.canLoadMore { Button(preferences.text.string(.uiLoadMore)) { workspace.loadMore() }.textSelection(.disabled).disabled(workspace.detailLoading).frame(height: 28).padding(.top, 4) }
                        }
                    }.padding(.leading, -9)
                }.frame(idealHeight: contentHeight, maxHeight: contentHeight)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
    }
    private func commitColumnWidths(_ commits: [GitCommit]) -> (author: CGFloat, date: CGFloat, hash: CGFloat) {
        let font = NSFont.systemFont(ofSize: 12)
        let hashFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return commits.reduce(into: (author: CGFloat.zero, date: CGFloat.zero, hash: CGFloat.zero)) { widths, commit in
            widths.author = max(widths.author, ceil((commit.author as NSString).size(withAttributes: [.font: font]).width))
            widths.date = max(widths.date, ceil((commit.displayDate(locale: preferences.activeLocale) as NSString).size(withAttributes: [.font: font]).width))
            widths.hash = max(widths.hash, ceil((String(commit.id.prefix(7)) as NSString).size(withAttributes: [.font: hashFont]).width))
        }
    }

    private func unavailable(_ reason: ModuError) -> some View { VStack(alignment: .leading) { Label(preferences.text.string(.uiUnavailable), systemImage: "exclamationmark.circle"); IssueDescriptionView(message: preferences.text.message(reason), details: reason.message, text: preferences.text).foregroundStyle(.secondary) } }
    @ViewBuilder private func status(_ value: String, conflict: Bool, staged: Bool) -> some View {
        let name = FileChange.label(value)
        if name != "—" {
            Group {
                if conflict { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 16) }
                else if value == "?" || ["Added", "Moved", "Modified", "Deleted"].contains(name) {
                    Image("GitFileStatus/\(value == "?" ? "Added" : name)").resizable().frame(width: 14, height: 14)
                        .frame(width: 16, height: 16, alignment: .leading)
                }
                else { Text(value).foregroundStyle(.secondary).frame(width: 16) }
            }.help("\(staged ? preferences.text.string(.uiStaged) : preferences.text.string(.uiUnstaged)): \(conflict ? preferences.text.statusText("Conflict") + " (\(value))" : preferences.text.fileStatus(value))")
        }
    }
    private func safeChangedPath(_ relative: String) -> URL? {
        guard let root = workspace.currentURL, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let path = root.appending(path: relative), real = PathSafety.canonical(path)
        guard real.path.hasPrefix(PathSafety.canonical(root).path + "/"), PathSafety.exists(path) else { return nil }
        return path
    }
}

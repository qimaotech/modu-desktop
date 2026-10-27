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
            VStack(alignment: .leading, spacing: 16) {
                ToolBarView(tools: tools, preferredToolIDs: preferredToolIDs, directory: workspace.currentURL, gitUnavailable: workspace.selection.map { workspace.states[$0.id]?.available == false } == true, text: preferences.text, open: openTool, availableWidth: geometry.size.width - 48)
                VStack(spacing: 12) {
                    summary(compact: geometry.size.width < 760)
                    if showsChanges && showsCommits { GitSplitView(upper: changesSection, lower: commitsSection, defaults: preferences.defaults) }
                    else if showsChanges { changesSection }
                    else if showsCommits { commitsSection }
                    else { Spacer() }
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        }.onChange(of: workspace.selection) { collapsed.removeAll() }
    }

    var showsChanges: Bool { workspace.detail.changes?.isEmpty == false || workspace.detail.changesError != nil }
    var showsCommits: Bool { workspace.detail.summary?.baseOID != nil && workspace.detail.commits?.isEmpty == false }

    private func summary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.selection?.path ?? "").font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(workspace.currentURL?.path ?? "").accessibilityValue(workspace.currentURL?.path ?? "").textSelection(.enabled)
            if let summary = workspace.detail.summary {
                HStack(spacing: compact ? 8 : 12) {
                    if summary.hasRemotes {
                        HStack(spacing: 6) {
                            DesignIcon(name: "BaseBranch", size: 16)
                            Text(preferences.text.string(.uiBaseBranch)).foregroundStyle(DesignStyle.secondary)
                            Text(summary.base ?? preferences.text.string(.uiUnavailable)).fontWeight(.medium).help(preferences.text.baseBranchHelp(summary))
                        }.fixedSize()
                        Rectangle().fill(DesignStyle.border).frame(width: 1, height: 20)
                    }
                    HStack(spacing: 6) {
                        DesignIcon(name: "HeadBranch", size: 16)
                        Text(preferences.text.string(.uiHeadBranch)).foregroundStyle(DesignStyle.secondary).fixedSize()
                        Text(summary.head).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(summary.head)
                    }
                }.font(.system(size: 13)).frame(height: 28)
            } else if let error = workspace.detail.summaryError { IssueDescriptionView(message: preferences.text.message(error), details: error.message, text: preferences.text).foregroundStyle(.secondary) }
            else { Color.clear.frame(height: 28).accessibilityElement()
                .accessibilityLabel(preferences.text.string(.uiLoadingSummary)) }
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).detailCard()
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(preferences.text.string(.uiChanges)).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(preferences.text.string(.uiStagedUnstaged)).font(.system(size: 11)).foregroundStyle(DesignStyle.secondary)
            }.frame(height: 20)
            if let error = workspace.detail.changesError { unavailable(error) }
            else if let changes = workspace.detail.changes {
                let rows = ChangeNode.tree(changes).flatMap { $0.visibleRows(collapsed: collapsed) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            changeRow(row.node, depth: row.depth)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(idealHeight: CGFloat(rows.count) * 24, maxHeight: CGFloat(rows.count) * 24)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
    }

    private func changeRow(_ node: ChangeNode, depth: Int) -> some View {
        HStack(spacing: 4) {
            if node.children != nil {
                Button {
                    if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                } label: { DesignIcon(name: "Disclosure").rotationEffect(.degrees(collapsed.contains(node.id) ? -90 : 0)) }
                    .buttonStyle(.plain).accessibilityLabel(preferences.text.string(.uiExpandOrCollapse) + " " + node.name)
            } else { Color.clear.frame(width: 16, height: 16) }
            if let change = node.change {
                status(change.index, conflict: change.conflict, staged: true)
                status(change.workingTree, conflict: change.conflict, staged: false)
            } else { DesignIcon(name: "FolderClosed") }
            Text(node.name).font(.system(size: 13)).lineLimit(1).textSelection(.enabled)
                .help(node.change?.originalPath.map { "\($0) → \(node.id)" } ?? node.id)
            Spacer(minLength: 0)
        }.padding(.leading, CGFloat(depth) * 16).frame(height: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.change.map { "\($0.path), \(preferences.text.string(.uiStaged)): \(preferences.text.fileStatus($0.index)), \(preferences.text.string(.uiUnstaged)): \(preferences.text.fileStatus($0.workingTree))" } ?? node.id)
        .contextMenu {
            Button(preferences.text.string(.uiRevealInFinder)) {
                if let url = safeChangedPath(node.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.disabled(safeChangedPath(node.id) == nil)
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preferences.text.string(.uiCommits)).font(.system(size: 14, weight: .medium)).frame(height: 20)
            if let commits = workspace.detail.commits {
                let contentHeight = CGFloat(commits.count) * 24 + (workspace.detail.canLoadMore ? 32 : 0)
                GeometryReader { geometry in
                    let compact = geometry.size.width < 720
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                                HStack(spacing: 6) {
                                    Image("DesignIcons/CommitLane").resizable().frame(width: 24, height: 72)
                                        .offset(y: index == 0 ? 0 : index == commits.count - 1 ? -48 : -24)
                                        .frame(width: 24, height: 24, alignment: .top).clipped()
                                        .mask { if commits.count == 1 { Circle().frame(width: 6, height: 6) } else { Rectangle() } }
                                        .accessibilityHidden(true)
                                    HStack(spacing: compact ? 12 : 16) {
                                        Text(commit.subject).frame(maxWidth: .infinity, alignment: .leading).help(commit.subject)
                                        Text(commit.author).frame(width: compact ? 84 : 100, alignment: .leading).help(commit.author)
                                        Text(commit.displayDate(locale: preferences.activeLocale)).frame(width: compact ? 160 : 172, alignment: .leading).help(commit.date)
                                        Text(String(commit.id.prefix(7))).frame(width: 60, alignment: .trailing).help(commit.id)
                                    }.lineLimit(1)
                                }.font(.system(size: 13)).frame(height: 24)
                                    .accessibilityElement(children: .combine)
                            }
                            if workspace.detail.canLoadMore { Button(preferences.text.string(.uiLoadMore)) { workspace.loadMore() }.disabled(workspace.detailLoading).frame(height: 28).padding(.top, 4) }
                        }
                    }
                }.frame(idealHeight: contentHeight, maxHeight: contentHeight)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
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

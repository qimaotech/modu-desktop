import SwiftUI
import AppKit
import MonoDeckCore

struct GitBrowserView: View {
    @Bindable var workspace: WorkspaceModel
    var preferences: AppPreferences
    var tools: [ExternalTool]
    var preferredToolIDs: [String: String]
    var openTool: (ExternalTool) -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                ToolBarView(tools: tools, preferredToolIDs: preferredToolIDs, text: preferences.text, open: openTool, availableWidth: geometry.size.width - 36)
                    .textSelection(.disabled)
                VStack(spacing: 12) {
                    summary(compact: geometry.size.width < 760)
                    GitBrowserSections(workspace: workspace, preferences: preferences)
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.overlay(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                if workspace.detailLoading, workspace.detail.changes == nil, workspace.detail.changesError == nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel(preferences.text.string(.uiLoadingLocalChanges))
                }
                if workspace.detailLoading, workspace.detail.uniqueCommits == nil, workspace.detail.uniqueCommitsError == nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel(preferences.text.string(.uiLoadingUniqueCommits))
                }
            }.allowsHitTesting(false)
        }.textSelection(.enabled)
    }

    private func summary(compact: Bool) -> some View {
        let path = workspace.record.map { record in
            workspace.selection.map { record.rootURL.appending(path: $0.path).path } ?? record.root
        } ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(workspace.selection?.path ?? "").font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    .help(path).accessibilityValue(path)
                ZStack {
                    if workspace.detailLoading {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(preferences.text.string(.uiLoadingGitDetails))
                    }
                }.frame(width: 14, height: 14)
                Spacer(minLength: 0)
            }.frame(height: 22)
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
}

private struct GitBrowserSections: View {
    @Bindable var workspace: WorkspaceModel
    var preferences: AppPreferences
    private var presentation: GitBrowserPresentation { workspace.details.presentationCache }
    private static let rowHeight: CGFloat = 22
    private static let verticalPadding: CGFloat = 8

    var body: some View {
        let rows = workspace.detail.changes.map { presentation.changeRows($0, collapsed: workspace.details.collapsedPaths) } ?? []
        let showsLocalChanges = workspace.detail.changes?.isEmpty == false || workspace.detail.changesError != nil
        let showsUniqueCommits = workspace.detail.summary?.baseOID != nil && workspace.detail.uniqueCommits?.isEmpty == false
        if showsLocalChanges && showsUniqueCommits {
            GitSplitView(upper: localChangesSection(rows), lower: uniqueCommitsSection,
                         upperHeight: workspace.detail.changesError == nil ? sectionHeight(rowCount: rows.count) : nil,
                         lowerHeight: sectionHeight(rowCount: workspace.detail.uniqueCommits?.count ?? 0),
                         defaults: preferences.defaults)
        } else if showsLocalChanges { localChangesSection(rows) }
        else if showsUniqueCommits { uniqueCommitsSection }
        else { Spacer() }
    }

    private func localChangesSection(_ rows: [ChangeNode.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preferences.text.string(.uiLocalChanges)).font(.system(size: 13)).frame(height: Self.rowHeight)
            if let error = workspace.detail.changesError { unavailable(error) }
            else if workspace.detail.changes != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            changeRow(row.node, depth: row.depth)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(idealHeight: CGFloat(rows.count) * Self.rowHeight, maxHeight: CGFloat(rows.count) * Self.rowHeight)
                    .padding(.leading, -6)
            }
        }.padding(.horizontal, 12).padding(.vertical, Self.verticalPadding).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
    }

    private func changeRow(_ node: ChangeNode, depth: Int) -> some View {
        HStack(spacing: 0) {
            if node.children != nil {
                Button {
                    if !workspace.details.collapsedPaths.insert(node.id).inserted { workspace.details.collapsedPaths.remove(node.id) }
                } label: {
                    DisclosureIcon(expanded: !workspace.details.collapsedPaths.contains(node.id))
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
        }.padding(.leading, CGFloat(depth) * 14).frame(height: Self.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.change.map { "\($0.path), \(preferences.text.string(.uiStaged)): \(preferences.text.fileStatus($0.index)), \(preferences.text.string(.uiUnstaged)): \(preferences.text.fileStatus($0.workingTree))" } ?? node.id)
        .contextMenu {
            Button(preferences.text.string(.uiRevealInFinder)) {
                if let url = safeChangedPath(node.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.textSelection(.disabled).disabled(safeChangedPath(node.id) == nil)
        }
    }

    private var uniqueCommitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preferences.text.string(.uiUniqueCommits)).font(.system(size: 13)).frame(height: Self.rowHeight)
            if let commits = workspace.detail.uniqueCommits {
                let contentHeight = CGFloat(commits.count) * Self.rowHeight
                let content = presentation.commitRows(commits, locale: preferences.activeLocale)
                GeometryReader { geometry in
                    let columnSpacing = min(36, max(12, 12 + (geometry.size.width - 640) / 20))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(content.rows) { row in
                                let commit = row.commit
                                HStack(spacing: 2) {
                                    CommitLaneView(index: row.index, count: commits.count, rowHeight: Self.rowHeight)
                                        .offset(x: 1)
                                    HStack(spacing: columnSpacing) {
                                        Text(commit.subject).truncationMode(.tail)
                                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutPriority(-1).help(commit.subject)
                                        Text(commit.author).font(.system(size: 12)).foregroundStyle(DesignStyle.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: content.authorWidth, alignment: .leading).help(commit.author)
                                        Text(row.date).font(.system(size: 12)).foregroundStyle(DesignStyle.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: content.dateWidth, alignment: .leading).help(commit.date)
                                        Text(String(commit.id.prefix(7))).font(.system(size: 12, design: .monospaced)).foregroundStyle(DesignStyle.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(width: content.hashWidth, alignment: .trailing).help(commit.id)
                                    }.lineLimit(1)
                                }.font(.system(size: 13)).frame(height: Self.rowHeight)
                                    .accessibilityElement(children: .combine)
                            }
                        }
                    }.padding(.leading, -9)
                }.frame(idealHeight: contentHeight, maxHeight: contentHeight)
            }
        }.padding(.horizontal, 12).padding(.vertical, Self.verticalPadding).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
    }

    private func sectionHeight(rowCount: Int) -> CGFloat {
        CGFloat(rowCount + 1) * Self.rowHeight + Self.verticalPadding * 2
    }

    private func unavailable(_ reason: MonoDeckError) -> some View { VStack(alignment: .leading) { Label(preferences.text.string(.uiUnavailable), systemImage: "exclamationmark.circle"); IssueDescriptionView(message: preferences.text.message(reason), details: reason.message, text: preferences.text).foregroundStyle(.secondary) } }
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

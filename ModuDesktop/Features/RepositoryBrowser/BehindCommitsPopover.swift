import SwiftUI
import AppKit
import ModuCore

struct BehindCommitsButton: View {
    let base: String
    let commits: [GitCommit]
    let text: InterfaceText
    @State private var showingCommits = false
    @State private var hovered = false

    var body: some View {
        Button { showingCommits.toggle() } label: {
            Text(text.string(.uiCommitsBehind(commits.count)))
                .font(.system(size: 12)).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(hovered || showingCommits ? DesignStyle.branchBehind : DesignStyle.secondary).fixedSize()
        .textSelection(.disabled)
        .onHover { hovered = $0 }
        .help(text.string(.uiBaseHasNewCommits(base, commits.count)))
        .accessibilityIdentifier("behind-commits-button")
        .accessibilityValue(showingCommits ? text.string(.uiExpanded) : text.string(.uiCollapsed))
        .popover(isPresented: $showingCommits, arrowEdge: .bottom) {
            BehindCommitsPopover(base: base, commits: commits, text: text)
        }
    }
}

struct BehindCommitsPopover: View {
    let base: String
    let commits: [GitCommit]
    let text: InterfaceText
    @State private var scrollEdges = ScrollEdges()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).help(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                        commitRow(commit, index: index)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                ScrollEdges(
                    top: geometry.contentOffset.y + geometry.contentInsets.top > 1,
                    bottom: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height + geometry.contentInsets.bottom - 1
                )
            } action: { _, edges in scrollEdges = edges }
            .frame(height: listHeight)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: scrollEdges.top ? [.clear, .black] : [.black, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                    Rectangle().fill(.black)
                    LinearGradient(colors: scrollEdges.bottom ? [.black, .clear] : [.black, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                }
            }
        }
        .lineLimit(1).truncationMode(.tail)
        .padding(16).frame(width: contentWidth).clipped()
        .textSelection(.enabled)
        .accessibilityIdentifier("behind-commits-popover")
    }

    private func commitRow(_ commit: GitCommit, index: Int) -> some View {
        HStack(spacing: 8) {
            CommitLaneView(index: index, count: commits.count, rowHeight: 22)
            Text(String(commit.id.prefix(7))).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignStyle.secondary).frame(width: 56, alignment: .leading).help(commit.id)
            Text(commit.subject).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).help(commit.subject)
        }.frame(height: 22).accessibilityElement(children: .combine)
    }

    private var title: String { text.string(.uiBaseHasNewCommits(base, commits.count)) }
    private var contentWidth: CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]).width
        var width = titleWidth
        for commit in commits {
            if width >= 528 { break }
            let rowWidth = (commit.subject as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 96
            width = max(width, rowWidth)
        }
        return min(560, max(280, ceil(width) + 32))
    }

    private var listHeight: CGFloat {
        min(300, CGFloat(commits.count) * 22)
    }

    private struct ScrollEdges: Equatable {
        var top = false
        var bottom = false
    }
}

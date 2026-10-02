import SwiftUI
import AppKit
import ModuCore

struct ToolBarView: View {
    var model: AppModel
    var category: String?
    var availableWidth: CGFloat?
    private var categories: [String] {
        (category.map { [$0] } ?? ["Agent", "Git GUI", "Editor", "Terminal"]).filter { category in
            model.tools.contains { $0.category == category }
        }
    }

    var body: some View {
        let categories = self.categories
        let layout = ToolBarLayout(buttonCount: categories.count, availableWidth: availableWidth,
                                   minimumButtonWidth: ToolBarLayout.minimumButtonWidth(for: model.tools))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<layout.rows, id: \.self) { row in
                HStack(spacing: layout.spacing) {
                    ForEach(Array(categories.dropFirst(row * layout.columns).prefix(layout.columns)), id: \.self) { category in
                        button(category: category, width: layout.buttonWidth)
                    }
                }
            }
        }.fixedSize(horizontal: category != nil, vertical: true)
    }

    @ViewBuilder private func button(category: String, width: CGFloat) -> some View {
        let available = model.tools.filter { $0.category == category }
        if let first = available.first {
            let preferred = available.first { $0.id == model.preferredToolIDs[category] } ?? first
            HStack(spacing: 0) {
                Button { model.openTool(preferred) } label: {
                    HStack(spacing: 6) {
                        Image("ToolIcons/\(preferred.icon)").resizable().scaledToFit().frame(width: 24, height: 24)
                        Text(preferred.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(HoverPlainButtonStyle(shape: Rectangle()))
                Rectangle().fill(DesignStyle.border).frame(width: 1, height: 36)
                ToolMenuButton(tools: available, width: width,
                               label: model.t("Choose tool", "选择工具") + " " + category,
                               open: { model.openTool($0) })
                    .frame(width: 26, height: 36)
                    .modifier(ButtonHoverBackground(shape: Rectangle()))
            }
            .frame(width: width, height: 36)
            .background(DesignStyle.background, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignStyle.border, lineWidth: 1))
            .disabled(model.currentURL.map { !FileManager.default.isReadableFile(atPath: $0.path) } ?? true || (category == "Git GUI" && model.selection.map { model.states[$0.id]?.available == false } == true))
        }
    }
}

private struct ToolMenuButton: NSViewRepresentable {
    let tools: [ExternalTool]
    let width: CGFloat
    let label: String
    let open: (ExternalTool) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.buttonHovered) private var hovered

    func makeNSView(context: Context) -> ToolMenuControl { ToolMenuControl() }
    static func dismantleNSView(_ button: ToolMenuControl, coordinator: ()) { button.dismissMenu() }
    func updateNSView(_ button: ToolMenuControl, context: Context) {
        button.tools = tools
        button.menuWidth = width
        button.open = open
        button.isEnabled = enabled
        button.contentTintColor = hovered ? .black : .labelColor
        if !enabled { button.dismissMenu() }
        button.setAccessibilityLabel(label)
    }
}

final class ToolMenuControl: NSButton, NSMenuDelegate {
    var tools: [ExternalTool] = []
    var menuWidth: CGFloat = 180
    var open: (ExternalTool) -> Void = { _ in }
    private var presentedMenu: NSMenu?

    init() {
        super.init(frame: .zero)
        title = ""
        image = NSImage(named: "DesignIcons/Chevron")?.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        imagePosition = .imageOnly
        isBordered = false
        target = self
        action = #selector(showTools)
        setAccessibilityRole(.menuButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }

    func menuOrigin(for menu: NSMenu) -> NSPoint {
        let rowsHeight = menu.items.compactMap { $0.view?.frame.height }.reduce(0, +)
        // AppKit anchors the menu content, excluding the padding above the first row.
        let topPadding = (menu.size.height - rowsHeight) / 2
        let offset = 4 + topPadding
        return NSPoint(x: bounds.maxX - menuWidth, y: isFlipped ? bounds.maxY + offset : bounds.minY - offset)
    }

    @objc private func showTools() {
        guard isEnabled, !tools.isEmpty else { return }
        let menu = makeMenu()
        presentedMenu = menu
        window?.makeFirstResponder(self)
        defer {
            presentedMenu = nil
            window?.makeFirstResponder(self)
        }
        menu.popUp(positioning: nil, at: menuOrigin(for: menu), in: self)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.minimumWidth = menuWidth
        menu.delegate = self
        for tool in tools {
            let item = NSMenuItem(title: tool.name, action: #selector(chooseTool(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool
            item.view = ToolMenuRow(tool: tool, width: menuWidth)
            menu.addItem(item)
        }
        return menu
    }

    func dismissMenu() { presentedMenu?.cancelTracking() }

    @objc private func chooseTool(_ item: NSMenuItem) {
        if let tool = item.representedObject as? ExternalTool { open(tool) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for candidate in menu.items {
            (candidate.view as? ToolMenuRow)?.highlighted = candidate === item
        }
    }
}

private final class ToolMenuRow: NSView {
    let tool: ExternalTool
    var highlighted = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { true }

    init(tool: ExternalTool, width: CGFloat) {
        self.tool = tool
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 8, yRadius: 8).fill()
        }
        NSImage(named: "ToolIcons/\(tool.icon)")?.draw(in: NSRect(x: 16, y: 7, width: 24, height: 24),
                                                      from: .zero, operation: .sourceOver, fraction: 1,
                                                      respectFlipped: true, hints: nil)
        let label = NSAttributedString(string: tool.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: highlighted ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
        ])
        label.draw(at: NSPoint(x: 48, y: (bounds.height - label.size().height) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

struct RepositoryDetailView: View {
    @Bindable var model: AppModel
    @State private var collapsed = Set<String>()

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                ToolBarView(model: model, availableWidth: geometry.size.width - 48)
                VStack(spacing: 12) {
                    summary(compact: geometry.size.width < 760)
                    if showsChanges && showsCommits { GitSplitView(upper: changesSection, lower: commitsSection, defaults: model.defaults) }
                    else if showsChanges { changesSection }
                    else if showsCommits { commitsSection }
                    else { Spacer() }
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.overlay(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                if model.detailLoading, model.detail.changes == nil, model.detail.changesError == nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel(model.t("Loading changes…", "正在加载更改…"))
                }
                if model.detailLoading, model.detail.commits == nil, model.detail.commitsError == nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel(model.t("Loading commits…", "正在加载提交…"))
                }
            }.allowsHitTesting(false)
        }.onChange(of: model.selection) { collapsed.removeAll() }
    }

    var showsChanges: Bool { model.detail.changes?.isEmpty == false || model.detail.changesError != nil }
    var showsCommits: Bool { model.detail.commits?.isEmpty == false || model.detail.commitsError != nil }

    private func summary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selection?.path ?? "").font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(model.currentURL?.path ?? "").accessibilityValue(model.currentURL?.path ?? "").textSelection(.enabled)
            if let summary = model.detail.summary {
                HStack(spacing: compact ? 8 : 12) {
                    if summary.hasRemotes {
                        HStack(spacing: 6) {
                            DesignIcon(name: "BaseBranch", size: 16)
                            Text(model.t("Base branch", "基准分支")).foregroundStyle(DesignStyle.secondary)
                            Text(summary.base ?? model.t("Unavailable", "不可用")).fontWeight(.medium).help(summary.baseError ?? "")
                        }.fixedSize()
                        Rectangle().fill(DesignStyle.border).frame(width: 1, height: 20)
                    }
                    HStack(spacing: 6) {
                        DesignIcon(name: "HeadBranch", size: 16)
                        Text(model.t("Head branch", "当前分支")).foregroundStyle(DesignStyle.secondary).fixedSize()
                        Text(summary.head).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(summary.head)
                    }
                }.font(.system(size: 13)).frame(height: 28)
            } else if let error = model.detail.summaryError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            else { Color.clear.frame(height: 28).accessibilityElement()
                .accessibilityLabel(model.t("Loading summary…", "正在加载摘要…")) }
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).detailCard()
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.t("Changes", "更改")).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(model.t("Staged / Unstaged", "已暂存 / 未暂存")).font(.system(size: 11)).foregroundStyle(DesignStyle.secondary)
            }.frame(height: 20)
            if let error = model.detail.changesError { unavailable(error) }
            else if let changes = model.detail.changes {
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
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func changeRow(_ node: ChangeNode, depth: Int) -> some View {
        HStack(spacing: 4) {
            if node.children != nil {
                Button {
                    if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                } label: { DesignIcon(name: "Disclosure").rotationEffect(.degrees(collapsed.contains(node.id) ? -90 : 0)) }
                    .buttonStyle(.plain).accessibilityLabel(model.t("Expand or collapse", "展开或折叠") + " " + node.name)
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
        .accessibilityLabel(node.change.map { "\($0.path), \(model.t("Staged", "已暂存")): \(model.statusText(FileChange.label($0.index))), \(model.t("Unstaged", "未暂存")): \(model.statusText(FileChange.label($0.workingTree)))" } ?? node.id)
        .contextMenu {
            Button(model.t("Reveal in Finder", "在访达中显示")) {
                if let url = safeChangedPath(node.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.disabled(safeChangedPath(node.id) == nil)
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t("Commits", "提交")).font(.system(size: 14, weight: .medium)).frame(height: 20)
            if let error = model.detail.commitsError { unavailable(error) }
            else if let commits = model.detail.commits {
                let contentHeight = CGFloat(commits.count) * 24 + (model.detail.canLoadMore ? 32 : 0)
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
                                        Text(commit.displayDate(language: model.language)).frame(width: compact ? 160 : 172, alignment: .leading).help(commit.date)
                                        Text(String(commit.id.prefix(7))).frame(width: 60, alignment: .trailing).help(commit.id)
                                    }.lineLimit(1)
                                }.font(.system(size: 13)).frame(height: 24)
                                    .accessibilityElement(children: .combine)
                            }
                            if model.detail.canLoadMore { Button(model.t("Load More", "加载更多")) { model.loadMore() }.disabled(model.detailLoading).frame(height: 28).padding(.top, 4) }
                        }
                    }
                }.frame(idealHeight: contentHeight, maxHeight: contentHeight)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .topLeading).detailCard()
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }
    private func unavailable(_ reason: String) -> some View { VStack(alignment: .leading) { Label(model.t("Unavailable", "不可用"), systemImage: "exclamationmark.circle"); Text(reason).foregroundStyle(.secondary).textSelection(.enabled) } }
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
            }.help("\(staged ? model.t("Staged", "已暂存") : model.t("Unstaged", "未暂存")): \(conflict ? model.statusText("Conflict") + " (\(value))" : model.statusText(name))")
        }
    }
    private func safeChangedPath(_ relative: String) -> URL? {
        guard let root = model.currentURL, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let path = root.appending(path: relative), real = PathSafety.canonical(path)
        guard real.path.hasPrefix(PathSafety.canonical(root).path + "/"), PathSafety.exists(path) else { return nil }
        return path
    }
}

struct ChangeNode: Identifiable {
    var id: String
    var name: String
    var change: FileChange?
    var children: [ChangeNode]?
    struct Row: Identifiable {
        let node: ChangeNode
        let depth: Int
        var id: String { node.id }
    }
    func visibleRows(collapsed: Set<String>, depth: Int = 0) -> [Row] {
        [Row(node: self, depth: depth)] + (collapsed.contains(id) ? [] : children?.flatMap { $0.visibleRows(collapsed: collapsed, depth: depth + 1) } ?? [])
    }
    static func tree(_ changes: [FileChange], prefix: String = "") -> [ChangeNode] {
        let grouped = Dictionary(grouping: changes) { change in
            let relative = change.path.dropFirst(prefix.count)
            guard let separator = relative.firstIndex(of: "/"), separator != relative.index(before: relative.endIndex) else { return String(relative) }
            return String(relative[..<separator])
        }
        return grouped.keys.map { name -> ChangeNode in
            let path = prefix + name, values = grouped[name]!
            if let leaf = values.first(where: { $0.path == path }) { return .init(id: path, name: name, change: leaf, children: values.count > 1 ? tree(values.filter { $0.path != path }, prefix: path + "/") : nil) }
            return .init(id: path, name: name, children: tree(values, prefix: path + "/"))
        }.sorted {
            if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

extension GitCommit {
    func displayDate(language: String) -> String {
        guard let value = ISO8601DateFormatter().date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "zh" ? "zh_CN" : "en_US")
        formatter.dateFormat = language == "zh" ? "yyyy年M月d日 HH:mm" : "MMM d, yyyy 'at' HH:mm"
        return formatter.string(from: value)
    }
}

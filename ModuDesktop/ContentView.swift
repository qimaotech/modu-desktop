import SwiftUI
import AppKit
import ModuCore

struct ContentView: View {
    @Bindable var model: AppModel
    var chromeHeight: CGFloat = 40
    @State private var startupCompleted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSplitView(sidebar: WorkspaceSidebar(model: model).id(model.workspace?.root), detail: detail.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        .background(DesignStyle.background)
        .navigationTitle(model.workspace?.rootURL.lastPathComponent ?? "Modu")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.busy, model.sheet == nil, model.resultHost == .main {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.repositoryUpdateProgressText).monospacedDigit()
                        Button { model.cancel() } label: { DesignIcon(name: "Cancel", size: 20) }
                            .buttonStyle(HoverPlainButtonStyle(shape: Circle()))
                            .disabled(model.progress?.cancellable == false)
                            .help(model.openingWorkspace ? model.t("Cancel Reload", "取消重新加载") : model.t("Cancel Update", "取消更新"))
                            .accessibilityLabel(model.openingWorkspace ? model.t("Cancel Reload", "取消重新加载") : model.t("Cancel Update", "取消更新"))
                    }
                } else if let completion = model.completionMessage {
                    Label(completion, systemImage: "checkmark.circle")
                } else { Text(model.workspace?.rootURL.lastPathComponent ?? "Modu").font(.system(size: 13, weight: .semibold)) }
            }.sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: mainSheetPresentation, onDismiss: { model.finishManagementDismissal() }) {
            if let result = model.result, model.resultHost == .main {
                ResultView(model: model, result: result) { model.dismissResult() }
            } else if let sheet = model.sheet {
                ManagementView(model: model, sheet: sheet).id(sheet)
            }
        }
        .alert(model.messageTitle ?? model.t("Operation failed", "操作失败"), isPresented: Binding(get: { model.message != nil && model.messageHost == .main }, set: { if !$0 && model.messageHost == .main { model.message = nil } })) { Button(model.t("OK", "好")) {} } message: { Text(model.message ?? "") }
        .task {
            let needsCLISetup = await model.start()
            guard !Task.isCancelled else { return }
            startupCompleted = !needsCLISetup
            if needsCLISetup || !model.hasSavedWorkspace { openWindow(id: "setup"); dismissWindow(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if startupCompleted { Task { await model.activate() } }
        }
    }

    var mainSheetPresentation: Binding<Bool> {
        Binding(get: { model.sheet != nil || (model.result != nil && model.resultHost == .main) }, set: {
            if !$0 {
                model.sheet = nil
                if model.resultHost == .main { model.dismissResult() }
            }
        })
    }

    @ViewBuilder private var detail: some View {
        if let blocked = model.blocked {
            ContentUnavailableView {
                Label(model.t("Workspace data couldn’t be loaded", "无法加载工作区数据"), systemImage: "exclamationmark.triangle")
            } description: { Text(blocked).textSelection(.enabled) } actions: {
                Button(model.t("Reload", "重新加载")) { Task { await model.reload() } }
                Button(model.t("Set Up Workspace", "设置工作区")) { openWindow(id: "setup") }
                Button(model.t("Quit", "退出")) { NSApp.terminate(nil) }
            }
        } else if model.workspace == nil, model.hasSavedWorkspace {
            if model.workspaceWaiting {
                ContentUnavailableView {
                    Label(model.t("Workspace is busy", "工作区正忙"), systemImage: "clock")
                } description: {
                    Text(model.t("Workspace is in use. Reload shortly.", "工作区正被其他操作使用，请稍后重新加载。"))
                } actions: {
                    Button(model.t("Reload", "重新加载")) { model.requestReload() }
                }
            } else {
                Color.clear.accessibilityElement()
                    .accessibilityLabel(model.t("Loading workspace…", "正在加载工作区…"))
            }
        } else if model.workspace == nil {
            ContentUnavailableView { Label(model.t("No workspace selected", "尚未选择工作区"), systemImage: "folder") } actions: { Button(model.t("Set Up Workspace", "设置工作区")) { openWindow(id: "setup") } }
        } else if model.selection == nil {
            VStack(spacing: 24) {
                Text(model.t("Let’s start", "开始使用")).font(.system(size: 26)).frame(height: 32)
                ToolBarView(model: model, agentOnly: true)
                HStack(spacing: 8) {
                    Button(model.t("Add Repository", "添加仓库")) { model.sheet = .add }
                    Button(model.t("Create Worktree Group", "创建工作树组")) { model.sheet = .create }.disabled(model.sortedRepositories.isEmpty)
                }.buttonStyle(StartButtonStyle()).disabled(model.busy)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).offset(x: -12, y: -chromeHeight / 2)
        } else { RepositoryDetailView(model: model) }
    }
}

// Expansion state belongs inside the AppKit-hosted sidebar so root-view updates preserve its animation history.
private struct WorkspaceSidebar: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var repositoriesExpanded: Bool
    @AppStorage private var groupsExpanded: Bool
    @FocusState private var sidebarFocused: Bool
    private var expansionAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.16) }

    init(model: AppModel) {
        self.model = model
        _repositoriesExpanded = AppStorage(wrappedValue: true, model.sidebarPreferenceKey("repositoriesExpanded"), store: model.defaults)
        _groupsExpanded = AppStorage(wrappedValue: true, model.sidebarPreferenceKey("groupsExpanded"), store: model.defaults)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        VStack(spacing: 0) {
                            sectionHeader("repositories", expanded: $repositoriesExpanded, add: .add)
                            if repositoriesExpanded {
                                VStack(spacing: 1) {
                                    ForEach(model.sortedRepositories) { repo in resourceRow(.repository(repo.id), title: repo.displayName) }
                                }.transition(.opacity)
                            }
                        }.clipped()
                        VStack(spacing: 0) {
                            sectionHeader("worktrees", expanded: $groupsExpanded, add: .create)
                            if groupsExpanded {
                                VStack(spacing: 1) {
                                    ForEach(model.sortedGroups, id: \.self) { group in
                                        VStack(spacing: 1) {
                                            resourceRow(.group(group), title: group)
                                            if model.expandedGroups.contains(group) {
                                                VStack(spacing: 1) {
                                                    ForEach(model.sortedRepositories.filter { model.workspace?.groups[group]?.repositories.contains($0.id) == true }) { repo in
                                                        resourceRow(.member(group, repo.id), title: repo.displayName)
                                                    }
                                                }.transition(.opacity)
                                            }
                                        }.clipped()
                                    }
                                }.transition(.opacity)
                            }
                        }.clipped()
                    }
                    .animation(expansionAnimation, value: repositoriesExpanded)
                    .animation(expansionAnimation, value: groupsExpanded)
                    .animation(expansionAnimation, value: model.expandedGroups)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .background {
                        Button { model.selection = nil; sidebarFocused = true } label: {
                            Color.clear.contentShape(Rectangle())
                        }.accessibilityLabel(model.t("Show Workspace", "显示工作区"))
                    }
                }
                .onChange(of: model.selection) { _, selection in if let selection { proxy.scrollTo(selection.id) } }
            }
        }
        .background(DesignStyle.sidebar)
        .buttonStyle(SidebarButtonStyle())
        .focusable().focused($sidebarFocused).focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) {
            guard let selection = model.selection, selection.kind == "group", let group = selection.group else { return .ignored }
            model.expandedGroups.insert(group); return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let group = model.selection?.group else { return .ignored }
            model.expandedGroups.remove(group); model.selection = .group(group); return .handled
        }
    }

    private func sectionHeader(_ title: String, expanded: Binding<Bool>, add: ManagementSheet) -> some View {
        HStack(spacing: 4) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    DesignIcon(name: "Disclosure").rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
                    DesignIcon(name: "FolderOpen")
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? model.t("Expanded", "已展开") : model.t("Collapsed", "已折叠"))
            if add == .add {
                Button { model.update() } label: { DesignIcon(name: "Update").frame(width: 24, height: 24) }
                    .buttonStyle(HoverPlainButtonStyle(shape: Circle()))
                    .help(model.t("Update Repositories", "更新仓库")).accessibilityLabel(model.t("Update Repositories", "更新仓库"))
                    .disabled(model.busy || model.sortedRepositories.isEmpty)
            }
            Button { model.sheet = add } label: { DesignIcon(name: "Plus").frame(width: 24, height: 24) }
                .buttonStyle(HoverPlainButtonStyle(shape: Circle()))
                .help(add == .add ? model.t("Add Repository", "添加仓库") : model.t("Create Worktree Group", "创建工作树组"))
                .accessibilityLabel(add == .add ? model.t("Add Repository", "添加仓库") : model.t("Create Worktree Group", "创建工作树组"))
                .disabled(model.busy || model.workspace == nil || (add == .create && model.sortedRepositories.isEmpty))
        }.frame(height: 32)
    }

    private func resourceRow(_ resource: Resource, title: String) -> some View {
        HStack(spacing: 6) {
            if resource.kind == "group" {
                Button { model.toggleGroup(title); sidebarFocused = true } label: {
                    DesignIcon(name: "Disclosure").rotationEffect(.degrees(model.expandedGroups.contains(title) ? 0 : -90))
                }.accessibilityLabel(model.t("Expand or collapse", "展开或折叠") + " " + title)
            }
            Button { model.selectSidebarRow(resource); sidebarFocused = true } label: {
                HStack(spacing: 6) {
                    DesignIcon(name: resource.kind == "group" ? "FolderGroup" : "FolderGit")
                    Text(title).font(.system(size: 13, weight: resource.kind == "group" ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if model.states[resource.id]?.available == false {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).frame(width: 24)
                            .help(model.states[resource.id]?.reason ?? "Unavailable").accessibilityLabel(model.t("Unavailable", "不可用"))
                    } else if model.states[resource.id]?.dirty == true {
                        DesignIcon(name: "Unset", size: 20).frame(width: 24).accessibilityHidden(false)
                            .accessibilityLabel(model.t("Working tree has changes", "工作树有更改"))
                    }
                }.frame(height: 28).contentShape(Rectangle())
            }.accessibilityLabel(title).accessibilityAddTraits(model.selection == resource ? [.isSelected] : [])
                .accessibilityValue(resource.kind == "group" ? (model.expandedGroups.contains(title) ? model.t("Expanded", "已展开") : model.t("Collapsed", "已折叠")) : "")
        }
        .padding(.leading, resource.kind == "group" ? 16 : resource.kind == "member" ? 38 : 22)
        .frame(height: 28)
        .modifier(SidebarRowBackground(selected: model.selection == resource))
        .id(resource.id).help(model.workspace?.rootURL.appending(path: resource.path).path ?? resource.path)
        .contextMenu { ResourceActions(model: model, resource: resource) }
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let resources = model.visibleResources.filter { $0.kind == "repository" ? repositoriesExpanded : groupsExpanded }
        guard !resources.isEmpty else { return .ignored }
        let current = model.selection.flatMap { resources.firstIndex(of: $0) } ?? (offset > 0 ? -1 : resources.count)
        model.selection = resources[min(resources.count - 1, max(0, current + offset))]
        return .handled
    }
}

struct ResourceActions: View {
    var model: AppModel
    var resource: Resource?
    var body: some View {
        if let resource, let root = model.workspace?.rootURL {
            let path = try? PathSafety.child(resource.path, of: root, allowMissing: false)
            if let path { Button(model.t("Copy Path", "复制路径")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path.path, forType: .string) } }
            Button(model.t("Reveal in Finder", "在访达中显示")) { if let path { NSWorkspace.shared.activateFileViewerSelecting([path]) } }.disabled(path == nil)
            Divider()
            if resource.kind == "group" { Button(model.t("Edit Worktree Group…", "编辑工作树组…")) { model.selection = resource; model.pendingEdit = nil; model.sheet = .edit }.disabled(model.busy) }
            Button(model.t("Delete…", "删除…"), role: .destructive) {
                let request: DeleteRequest = resource.kind == "repository" ? .repository(resource.repo!) : resource.repo.map { .member(group: resource.group!, repo: $0) } ?? .group(resource.group!)
                model.prepareDelete(request)
            }.disabled(model.busy)
        }
    }
}

import SwiftUI
import AppKit
import ModuCore

// Expansion state belongs inside the AppKit-hosted sidebar so root-view updates preserve its animation history.
struct WorkspaceSidebar: View {
    @Bindable var workspace: WorkspaceModel
    var management: ManagementModel
    var operations: OperationLifecycle
    var preferences: AppPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var repositoriesExpanded: Bool
    @AppStorage private var groupsExpanded: Bool
    @FocusState private var sidebarFocused: Bool
    private var expansionAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.16) }

    init(workspace: WorkspaceModel, management: ManagementModel, operations: OperationLifecycle, preferences: AppPreferences) {
        self.workspace = workspace
        self.management = management
        self.operations = operations
        self.preferences = preferences
        _repositoriesExpanded = AppStorage(wrappedValue: true, workspace.sidebarPreferenceKey("repositoriesExpanded"), store: preferences.defaults)
        _groupsExpanded = AppStorage(wrappedValue: true, workspace.sidebarPreferenceKey("groupsExpanded"), store: preferences.defaults)
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
                                    ForEach(workspace.sortedRepositories) { repo in resourceRow(.repository(repo.id), title: repo.displayName) }
                                }.transition(.opacity)
                            }
                        }.clipped()
                        VStack(spacing: 0) {
                            sectionHeader("worktrees", expanded: $groupsExpanded, add: .create)
                            if groupsExpanded {
                                VStack(spacing: 1) {
                                    ForEach(workspace.sortedGroups, id: \.self) { group in
                                        VStack(spacing: 1) {
                                            resourceRow(.group(group), title: group)
                                            if workspace.expandedGroups.contains(group) {
                                                VStack(spacing: 1) {
                                                    ForEach(workspace.sortedRepositories.filter { workspace.record?.groups[group]?.repositories.contains($0.id) == true }) { repo in
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
                    .animation(expansionAnimation, value: workspace.expandedGroups)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .background {
                        Button { workspace.selection = nil; sidebarFocused = true } label: {
                            Color.clear.contentShape(Rectangle())
                        }.accessibilityLabel(preferences.t("Show Workspace", "显示工作区"))
                    }
                }
                .onChange(of: workspace.selection) { _, selection in if let selection { proxy.scrollTo(selection.id) } }
            }
        }
        .background(DesignStyle.sidebar)
        .buttonStyle(SidebarButtonStyle())
        .focusable().focused($sidebarFocused).focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) {
            guard let selection = workspace.selection, selection.kind == .group, let group = selection.group else { return .ignored }
            workspace.expandedGroups.insert(group); return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let group = workspace.selection?.group else { return .ignored }
            workspace.expandedGroups.remove(group); workspace.selection = .group(group); return .handled
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
            }.accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? preferences.t("Expanded", "已展开") : preferences.t("Collapsed", "已折叠"))
            if add == .add {
                Button { management.update() } label: { DesignIcon(name: "Update").frame(width: 24, height: 24) }
                    .buttonStyle(HoverPlainButtonStyle(shape: Circle()))
                    .help(preferences.t("Update Repositories", "更新仓库")).accessibilityLabel(preferences.t("Update Repositories", "更新仓库"))
                    .disabled(operations.busy || workspace.sortedRepositories.isEmpty)
            }
            Button { management.sheet = add } label: { DesignIcon(name: "Plus").frame(width: 24, height: 24) }
                .buttonStyle(HoverPlainButtonStyle(shape: Circle()))
                .help(add == .add ? preferences.t("Add Repository", "添加仓库") : preferences.t("Create Worktree Group", "创建工作树分组"))
                .accessibilityLabel(add == .add ? preferences.t("Add Repository", "添加仓库") : preferences.t("Create Worktree Group", "创建工作树分组"))
                .disabled(operations.busy || workspace.record == nil || (add == .create && workspace.sortedRepositories.isEmpty))
        }.frame(height: 32)
    }

    private func resourceRow(_ resource: Resource, title: String) -> some View {
        HStack(spacing: 6) {
            if resource.kind == .group {
                Button { workspace.toggleGroup(title); sidebarFocused = true } label: {
                    DesignIcon(name: "Disclosure").rotationEffect(.degrees(workspace.expandedGroups.contains(title) ? 0 : -90))
                }.accessibilityLabel(preferences.t("Expand or collapse", "展开或折叠") + " " + title)
            }
            Button { workspace.selectSidebarRow(resource); sidebarFocused = true } label: {
                HStack(spacing: 6) {
                    DesignIcon(name: resource.kind == .group ? "FolderGroup" : "FolderGit")
                    Text(title).font(.system(size: 13, weight: resource.kind == .group ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if workspace.states[resource.id]?.available == false {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).frame(width: 24)
                            .help(workspace.states[resource.id]?.reason ?? "Unavailable").accessibilityLabel(preferences.t("Unavailable", "不可用"))
                    } else if workspace.states[resource.id]?.dirty == true {
                        DesignIcon(name: "Unset", size: 20).frame(width: 24).accessibilityHidden(false)
                            .accessibilityLabel(preferences.t("Working tree has changes", "工作树有更改"))
                    }
                }.frame(height: 28).contentShape(Rectangle())
            }.accessibilityLabel(title).accessibilityAddTraits(workspace.selection == resource ? [.isSelected] : [])
                .accessibilityValue(resource.kind == .group ? (workspace.expandedGroups.contains(title) ? preferences.t("Expanded", "已展开") : preferences.t("Collapsed", "已折叠")) : "")
        }
        .padding(.leading, resource.kind == .group ? 16 : resource.kind == .member ? 38 : 22)
        .frame(height: 28)
        .modifier(SidebarRowBackground(selected: workspace.selection == resource))
        .id(resource.id).help(workspace.record?.rootURL.appending(path: resource.path).path ?? resource.path)
        .contextMenu { ResourceActions(workspace: workspace, management: management, operations: operations, text: InterfaceText(language: preferences.language), resource: resource) }
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let resources = workspace.visibleResources.filter { $0.kind == .repository ? repositoriesExpanded : groupsExpanded }
        guard !resources.isEmpty else { return .ignored }
        let current = workspace.selection.flatMap { resources.firstIndex(of: $0) } ?? (offset > 0 ? -1 : resources.count)
        workspace.selection = resources[min(resources.count - 1, max(0, current + offset))]
        return .handled
    }
}

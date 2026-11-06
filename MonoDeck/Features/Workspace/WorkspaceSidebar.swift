import SwiftUI
import AppKit
import MonoDeckCore

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
        // Build rows outside the geometry closure; width changes only need to resize the viewport.
        let sections = sections
        let resources = Set(visibleResources)
        let workspaceRoot = workspace.record?.root
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    sections
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .background {
                        Button { workspace.selection = nil; sidebarFocused = true } label: {
                            Color.clear.contentShape(Rectangle())
                        }.accessibilityLabel(preferences.text.string(.uiShowWorkspace))
                    }
                }
                .onChange(of: workspace.selection, initial: true) { _, selection in if let selection { proxy.scrollTo(selection.id) } }
                .onChange(of: resources, initial: true) { _, resources in
                    if let workspaceRoot { workspace.setVisibleResources(resources, in: workspaceRoot) }
                }
            }
        }
        .background(DesignStyle.sidebar)
        .buttonStyle(SidebarButtonStyle())
        .focusable().focused($sidebarFocused).focusEffectDisabled()
        .onAppear { workspace.refreshSidebarStructure() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            workspace.refreshSidebarStructure()
        }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) {
            guard let selection = workspace.selection, selection.kind == .group, let group = selection.groupName else { return .ignored }
            workspace.expandedGroups.insert(group); return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let group = workspace.selection?.groupName else { return .ignored }
            workspace.expandedGroups.remove(group); workspace.selection = .group(group); return .handled
        }
    }

    private var sections: some View {
        let structure = workspace.sidebarStructure
        return VStack(spacing: 8) {
            VStack(spacing: 0) {
                sectionHeader("repositories", expanded: $repositoriesExpanded, add: .add)
                if repositoriesExpanded {
                    VStack(spacing: 1) {
                        ForEach(structure.repositories) { repo in
                            WorkspaceSidebarRow(workspace: workspace, management: management, operations: operations, preferences: preferences,
                                                resource: .repository(repo.id), title: repo.title, sidebarFocused: $sidebarFocused)
                        }
                    }.transition(.opacity)
                }
            }.clipped()
            VStack(spacing: 0) {
                sectionHeader("worktrees", expanded: $groupsExpanded, add: .create)
                if groupsExpanded {
                    VStack(spacing: 1) {
                        ForEach(structure.groups) { group in
                            VStack(spacing: 1) {
                                WorkspaceSidebarRow(workspace: workspace, management: management, operations: operations, preferences: preferences,
                                                    resource: .group(group.name), title: group.name, sidebarFocused: $sidebarFocused)
                                if workspace.expandedGroups.contains(group.name) {
                                    VStack(spacing: 1) {
                                        ForEach(group.members) { repo in
                                            WorkspaceSidebarRow(workspace: workspace, management: management, operations: operations, preferences: preferences,
                                                                resource: .member(groupName: group.name, repositoryID: repo.id), title: repo.title, sidebarFocused: $sidebarFocused)
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
    }

    private func sectionHeader(_ title: String, expanded: Binding<Bool>, add: ManagementSheet) -> some View {
        HStack(spacing: 4) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    DisclosureIcon(expanded: expanded.wrappedValue)
                    SidebarFolderIcon()
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? preferences.text.string(.uiExpanded) : preferences.text.string(.uiCollapsed))
            if add == .add {
                Button { management.updateRepositories() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24).accessibilityHidden(true)
                }
                    .buttonStyle(HoverPlainButtonStyle(shape: Circle(), foreground: DesignStyle.secondary, hoverForeground: DesignStyle.secondary))
                    .help(preferences.text.string(.uiUpdateRepositories)).accessibilityLabel(preferences.text.string(.uiUpdateRepositories))
                    .disabled(!workspace.canManage || workspace.sidebarStructure.repositories.isEmpty)
            }
            Button { management.requestForm(add == .add ? .addRepository : .createGroup) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).accessibilityHidden(true)
            }
                .buttonStyle(HoverPlainButtonStyle(shape: Circle(), foreground: DesignStyle.secondary, hoverForeground: DesignStyle.secondary))
                .help(add == .add ? preferences.text.string(.uiAddRepository2) : preferences.text.string(.uiCreateWorktreeGroup2))
                .accessibilityLabel(add == .add ? preferences.text.string(.uiAddRepository2) : preferences.text.string(.uiCreateWorktreeGroup2))
        }.frame(height: 32)
    }

    private var visibleResources: [Resource] {
        workspace.sidebarStructure.resources(expandedGroups: workspace.expandedGroups,
                                             repositoriesExpanded: repositoriesExpanded, groupsExpanded: groupsExpanded)
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let resources = visibleResources
        guard !resources.isEmpty else { return .ignored }
        let current = workspace.selection.flatMap { resources.firstIndex(of: $0) } ?? (offset > 0 ? -1 : resources.count)
        workspace.selection = resources[min(resources.count - 1, max(0, current + offset))]
        return .handled
    }
}

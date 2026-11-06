import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MonoDeckCore

struct WorkspaceSidebarRow: View {
    var workspace: WorkspaceModel
    var management: ManagementModel
    var operations: OperationLifecycle
    var preferences: AppPreferences
    let resource: Resource
    let title: String
    var sidebarFocused: FocusState<Bool>.Binding

    var body: some View {
        let state = workspace.state(for: resource)
        let selected = workspace.selection == resource
        let expanded = resource.kind == .group && workspace.expandedGroups.contains(title)
        HStack(spacing: 6) {
            if resource.kind == .group {
                Button { workspace.toggleGroup(title); sidebarFocused.wrappedValue = true } label: {
                    DisclosureIcon(expanded: expanded)
                }.accessibilityLabel(preferences.text.string(.uiExpandOrCollapse) + " " + title)
            }
            Button { workspace.selectSidebarRow(resource); sidebarFocused.wrappedValue = true } label: {
                HStack(spacing: 6) {
                    if resource.kind == .group { SidebarFolderIcon() }
                    else { DesignIcon(name: "FolderGit") }
                    Text(title).font(.system(size: 13, weight: resource.kind == .group ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if state?.available == false {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).frame(width: 24)
                            .help(state?.reasonMessage.map(preferences.text.message) ?? preferences.text.string(.uiUnavailable)).accessibilityLabel(preferences.text.string(.uiUnavailable))
                    } else if state?.dirty == true {
                        Circle().fill(.tertiary).frame(width: 7, height: 7).frame(width: 24, height: 20)
                            .accessibilityLabel(preferences.text.string(.uiWorkingTreeHasChanges))
                    }
                }.frame(height: 28).contentShape(Rectangle())
            }.accessibilityLabel(title).accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityValue(resource.kind == .group ? (expanded ? preferences.text.string(.uiExpanded) : preferences.text.string(.uiCollapsed)) : "")
        }
        .padding(.leading, resource.kind == .member ? 32 : 16)
        .frame(height: 28)
        .modifier(SidebarRowBackground(selected: selected))
        .id(resource.id).help(workspace.record?.rootURL.appending(path: resource.path).path ?? resource.path)
        .contextMenu { ResourceActions(workspace: workspace, management: management, operations: operations, text: preferences.text, resource: resource) }
    }
}

struct SidebarFolderIcon: View {
    var body: some View {
        Image(nsImage: Self.folderImage).renderingMode(.original).resizable().scaledToFit()
            .frame(width: 16, height: 16).scaleEffect(0.92).accessibilityHidden(true)
    }

    private static let folderImage = NSWorkspace.shared.icon(for: .folder)
}

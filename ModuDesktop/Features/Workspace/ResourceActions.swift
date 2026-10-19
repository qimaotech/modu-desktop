import SwiftUI
import AppKit
import ModuCore

struct ResourceActions: View {
    var workspace: WorkspaceModel
    var management: ManagementModel
    var operations: OperationLifecycle
    var text: InterfaceText
    var resource: Resource?
    var body: some View {
        if let resource, let root = workspace.record?.rootURL {
            let path = try? PathSafety.child(resource.path, of: root, allowMissing: false)
            if let path { Button(text.t("Copy Path", "复制路径")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path.path, forType: .string) } }
            Button(text.t("Reveal in Finder", "在访达中显示")) { if let path { NSWorkspace.shared.activateFileViewerSelecting([path]) } }.disabled(path == nil)
            Divider()
            if resource.kind == .group { Button(text.t("Edit Worktree Group…", "编辑工作树分组…")) { workspace.selection = resource; management.pendingEdit = nil; management.sheet = .edit }.disabled(operations.busy) }
            if let request = DeleteRequest(resource) {
                Button(text.t("Delete…", "删除…"), role: .destructive) { management.prepareDelete(request) }.disabled(operations.busy)
            }
        }
    }
}

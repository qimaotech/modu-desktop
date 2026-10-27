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
            if let path { Button(text.string(.uiCopyPath)) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path.path, forType: .string) } }
            Button(text.string(.uiRevealInFinder)) { if let path { NSWorkspace.shared.activateFileViewerSelecting([path]) } }.disabled(path == nil)
            Divider()
            if resource.kind == .group { Button(text.string(.uiEditWorktreeGroup)) { workspace.selection = resource; management.pendingEdit = nil; management.sheet = .edit }.disabled(operations.busy) }
            if let request = DeleteRequest(resource) {
                Button(text.string(.uiDelete), role: .destructive) { management.prepareDelete(request) }.disabled(operations.busy)
            }
        }
    }
}

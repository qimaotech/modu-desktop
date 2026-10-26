import SwiftUI
import AppKit
import ModuCore

struct WorkingTreeStatus: View {
    var text: InterfaceText
    let status: String
    var body: some View {
        HStack(spacing: 4) {
            DesignIcon(name: status == "Clean" ? "Success" : status == "Unset" ? "Unset" : "Warning", size: 16)
            Text(text.statusText(status)).font(DialogTypography.auxiliary)
        }.foregroundStyle(status == "Clean" ? Color.green : status == "Dirty" ? Color.orange : DesignStyle.secondary)
    }
}

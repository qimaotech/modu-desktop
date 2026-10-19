import SwiftUI
import AppKit
import ModuCore

struct FormErrorView: View {
    let message: String
    var title: String? = nil
    var details: String? = nil
    var detailsTitle = "Details"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.red) }
            ScrollView {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
            if let details {
                DisclosureGroup(detailsTitle) {
                    ScrollView {
                        Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

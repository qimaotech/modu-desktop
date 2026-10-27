import SwiftUI
import AppKit
import ModuCore

struct FormErrorView: View {
    let message: String
    var title: String? = nil
    var details: String? = nil
    var detailsTitle = String(localized: .uiDetails)
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(DialogTypography.auxiliary.weight(.semibold)).foregroundStyle(.red) }
            ScrollView {
                Text(message).font(DialogTypography.auxiliary).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
            if let details {
                DisclosureGroup(detailsTitle) {
                    ScrollView {
                        Text(details).font(DialogTypography.path).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
            }
        }
    }
}

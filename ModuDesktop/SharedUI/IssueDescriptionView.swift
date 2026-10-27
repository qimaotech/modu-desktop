import SwiftUI

struct IssueDescriptionView: View {
    let message: String
    var details: String?
    let text: InterfaceText

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
            if let details, !details.isEmpty, details != message {
                DisclosureGroup(text.string(.uiDetails)) {
                    Text(details).font(DialogTypography.path).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.textSelection(.enabled)
    }
}

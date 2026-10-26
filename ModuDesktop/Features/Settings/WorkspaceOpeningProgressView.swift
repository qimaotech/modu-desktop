import SwiftUI

struct WorkspaceOpeningProgressView: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(DesignStyle.secondary)
                    .lineLimit(1).truncationMode(.middle).help(url.path).accessibilityValue(url.path)
            }
            ProgressView().progressViewStyle(.linear).controlSize(.small)
                .accessibilityLabel(title)
        }.padding(24).frame(width: 368).background(DesignStyle.background)
            .interactiveDismissDisabled()
    }
}

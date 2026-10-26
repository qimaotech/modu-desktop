import SwiftUI
import AppKit
import ModuCore

struct RepositoryImportForm: View {
    @Bindable var management: ManagementModel
    let text: InterfaceText
    private let rowHeight: CGFloat = 28
    private let horizontalInset: CGFloat = 12
    private let listShape = RoundedRectangle(cornerRadius: 6)

    var body: some View {
        if let pending = management.repositoryImport {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Toggle(text.t("Select All", "全选"), sources: pending.urls.map { selectionBinding(for: $0) }, isOn: \.self)
                        .toggleStyle(.checkbox).font(DialogTypography.body)
                        .background {
                            Button(text.t("Select All", "全选")) { management.repositoryImport?.selectedURLs = Set(pending.urls) }
                                .keyboardShortcut("a").hidden().accessibilityHidden(true)
                        }
                    Spacer(minLength: 8)
                    Text(text.t("\(pending.selectedURLs.count) of \(pending.urls.count) selected", "已选择 \(pending.selectedURLs.count) / \(pending.urls.count) 个"))
                        .font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary).monospacedDigit()
                }.padding(.horizontal, horizontalInset).frame(height: 32)
                    .background(Color.primary.opacity(0.035))
                Divider()
                List(pending.urls, id: \.self) { url in
                    repositoryRow(url)
                        // Plain list cells add 8 points, matching the header's 12-point inset.
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain).alternatingRowBackgrounds()
                .contentMargins(0, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, rowHeight)
                .frame(height: CGFloat(min(pending.urls.count, 8)) * rowHeight)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(listShape)
            .overlay(listShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    private func repositoryRow(_ url: String) -> some View {
        Toggle(isOn: selectionBinding(for: url)) {
            Text((try? RepositoryIdentity(url).name) ?? url)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox).font(DialogTypography.body)
        .help(url).accessibilityHint(url)
    }

    private func selectionBinding(for url: String) -> Binding<Bool> {
        Binding(get: { management.repositoryImport?.selectedURLs.contains(url) == true }, set: {
            if $0 { management.repositoryImport?.selectedURLs.insert(url) }
            else { management.repositoryImport?.selectedURLs.remove(url) }
        })
    }
}

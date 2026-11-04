import SwiftUI

struct DisclosureIcon: View {
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: expanded)
            .frame(width: 10, height: 16).accessibilityHidden(true)
    }
}

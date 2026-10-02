import SwiftUI
import AppKit

enum DesignStyle {
    static let sheetWidth: CGFloat = 460
    static let background = adaptive(light: 0xffffff, dark: 0x202020)
    static let sidebar = adaptive(light: 0xfdfdfd, dark: 0x252525)
    static let sidebarHighlight = Color(.sRGB, red: 238.0 / 255, green: 238.0 / 255, blue: 239.0 / 255, opacity: 1)
    static let border = adaptive(light: 0xe8e8ed, dark: 0x48484a)
    static let cardBorder = adaptive(light: 0xe3e3e3, dark: 0x48484a)
    static let field = adaptive(light: 0xf5f5f5, dark: 0x303030)
    static let selection = adaptive(light: 0xe0efff, dark: 0x294966)
    static let secondary = adaptive(light: 0x7c7c80, dark: 0xa5a5aa)
    static let buttonHover = LinearGradient(colors: [
        Color(.sRGB, red: 225.0 / 255, green: 227.0 / 255, blue: 229.0 / 255, opacity: 1),
        Color(.sRGB, red: 241.0 / 255, green: 242.0 / 255, blue: 242.0 / 255, opacity: 1)
    ], startPoint: .top, endPoint: .bottom)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func detailCard() -> some View {
        background(DesignStyle.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignStyle.cardBorder, lineWidth: 1))
    }

    func formPlate() -> some View {
        background(DesignStyle.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignStyle.cardBorder, lineWidth: 0.5))
    }
}

struct DesignIcon: View {
    let name: String
    var size: CGFloat = 16
    var body: some View {
        Image("DesignIcons/\(name)").resizable().scaledToFit()
            .frame(width: name == "Disclosure" ? 10 : size, height: name == "Disclosure" ? 6 : size)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct SidebarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.primary).opacity(enabled ? 1 : 0.4)
    }
}

struct SidebarRowBackground: ViewModifier {
    let selected: Bool
    @State var hovered = false

    func body(content: Content) -> some View {
        let highlighted = selected || hovered
        content.foregroundStyle(highlighted ? Color.black : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(highlighted ? DesignStyle.sidebarHighlight : .clear)
                    .animation(nil, value: highlighted)
            }
            .onHover { hovered = $0 }
    }
}

private struct ButtonHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var buttonHovered: Bool {
        get { self[ButtonHoverKey.self] }
        set { self[ButtonHoverKey.self] = newValue }
    }
}

struct ButtonHoverBackground<Background: Shape>: ViewModifier {
    let shape: Background
    @Environment(\.isEnabled) private var enabled
    @State var hovered = false

    func body(content: Content) -> some View {
        let highlighted = enabled && hovered
        content
            .foregroundStyle(highlighted ? Color.black : Color.primary)
            .environment(\.buttonHovered, highlighted)
            .background(DesignStyle.buttonHover.opacity(highlighted ? 1 : 0), in: shape)
            .onHover { hovered = $0 }
    }
}

struct HoverPlainButtonStyle<Background: Shape>: ButtonStyle {
    let shape: Background
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ButtonHoverBackground(shape: shape))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct StartButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14)).padding(.horizontal, 16).frame(height: 36)
            .modifier(ButtonHoverBackground(shape: RoundedRectangle(cornerRadius: 8)))
            .background(configuration.isPressed ? DesignStyle.selection : DesignStyle.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignStyle.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

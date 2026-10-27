import SwiftUI

struct GlobalShortcutSettingsView: View {
    @Bindable var model: GlobalShortcutModel
    private let controlHeight: CGFloat = 28
    private let controlShape = RoundedRectangle(cornerRadius: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text.string(.uiGlobalShortcut)).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                Text(model.text.string(.uiShowHideModu))
                Spacer(minLength: 16)
                if model.isRecording {
                    ShortcutRecorder(onKey: model.record, onCancel: model.cancelRecording,
                                     label: model.text.string(.uiPressShortcut))
                        .frame(width: 148, height: 30)
                        .background(DesignStyle.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) {
                            Text(model.text.string(.uiPressShortcut)).padding(.horizontal, 10)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1))
                    Button(model.text.string(.uiCancel)) { model.cancelRecording() }
                        .buttonStyle(.plain).foregroundStyle(DesignStyle.secondary)
                        .accessibilityIdentifier("cancelGlobalShortcutRecording")
                } else {
                    Button { model.beginRecording() } label: {
                        Text(model.shortcutLabel ?? model.text.string(.uiUnassigned))
                            .foregroundStyle(model.shortcut == nil ? DesignStyle.secondary : Color.primary)
                            .frame(minWidth: 48).padding(.horizontal, 12).frame(height: controlHeight)
                            .background(Color.primary.opacity(0.04), in: controlShape)
                            .contentShape(controlShape)
                    }.buttonStyle(HoverPlainButtonStyle(shape: controlShape))
                        .accessibilityLabel(model.text.string(.uiEditGlobalShortcut))
                        .accessibilityValue(model.shortcutLabel ?? model.text.string(.uiUnassigned))
                        .accessibilityIdentifier("globalShortcut")
                    // Icon hit areas include padding; a smaller gap keeps the visible spacing balanced.
                    HStack(spacing: 4) {
                        Button { model.beginRecording() } label: {
                            DesignIcon(name: "Pencil").foregroundStyle(DesignStyle.secondary)
                                .frame(width: controlHeight, height: controlHeight)
                        }.accessibilityLabel(model.text.string(.uiEditGlobalShortcut))
                        Button { model.clear() } label: {
                            Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(DesignStyle.secondary)
                                .frame(width: controlHeight, height: controlHeight)
                        }.disabled(model.shortcut == nil)
                            .accessibilityLabel(model.text.string(.uiDeleteGlobalShortcut))
                            .accessibilityIdentifier("deleteGlobalShortcut")
                    }.buttonStyle(HoverPlainButtonStyle(shape: controlShape))
                }
            }.padding(.horizontal, 16).frame(height: 60).formPlate()
        }
        .onDisappear { model.cancelRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.cancelRecording() }
        .alert(model.text.string(.uiCanTSetGlobalShortcut), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(model.text.string(.uiOk)) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

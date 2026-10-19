import SwiftUI
import AppKit
import ModuCore

struct RepositorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.sendsSearchStringImmediately = true
        field.maximumRecents = 0
        field.font = .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("repositorySearch")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing, field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if focused, field.currentEditor() == nil {
            // SwiftUI releases the name field's focus after this update.
            DispatchQueue.main.async {
                guard context.coordinator.parent.focused, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: RepositorySearchField
        init(parent: RepositorySearchField) { self.parent = parent }

        @objc func search(_ field: NSSearchField) { updateText(field) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // Publish native edits before a focus update can restore the previous binding value.
            updateText(field, editor: notification.userInfo?["NSFieldEditor"] as? NSTextView)
        }
        func controlTextDidBeginEditing(_ notification: Notification) { if !parent.focused { parent.focused = true } }
        func controlTextDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSResponder.insertNewline(_:))
        }

        private func updateText(_ field: NSSearchField, editor: NSTextView? = nil) {
            let editor = editor ?? field.currentEditor() as? NSTextView
            guard editor?.hasMarkedText() != true else { return }
            parent.text = editor?.string ?? field.stringValue
        }
    }
}

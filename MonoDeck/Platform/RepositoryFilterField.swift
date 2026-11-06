import SwiftUI
import AppKit
import MonoDeckCore

struct RepositoryFilterField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = RepositoryFilterControl()
        field.controlSize = .large
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.focused != focused else { return }
            coordinator.parent.focused = focused
        }
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.filterChanged(_:))
        field.sendsSearchStringImmediately = true
        field.maximumRecents = 0
        field.font = .systemFont(ofSize: DialogTypography.bodySize, weight: .regular)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("repositoryFilter")
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

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        (field as? RepositoryFilterControl)?.stopMonitoringClicks()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: RepositoryFilterField
        init(parent: RepositoryFilterField) { self.parent = parent }

        @objc func filterChanged(_ field: NSSearchField) { updateText(field) }
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

private final class RepositoryFilterControl: NSSearchField {
    var onFocusChange: ((Bool) -> Void)?
    private var clickMonitor: Any?

    override class var cellClass: AnyClass? {
        get { RepositoryFilterCell.self }
        set { super.cellClass = newValue }
    }

    // Text-change notifications do not report focus on an untouched filter field.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoringClicks()
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.dismissFilterForOutsideClick(event)
            return event
        }
    }

    func stopMonitoringClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func dismissFilterForOutsideClick(_ event: NSEvent) {
        guard let window, event.window === window,
              !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if currentEditor() != nil, !window.makeFirstResponder(nil) { return }
        onFocusChange?(false)
    }
}

private final class RepositoryFilterCell: NSSearchFieldCell {
    // Borderless cells otherwise edit across the full bounds, including the magnifying glass and clear buttons.
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }

    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}

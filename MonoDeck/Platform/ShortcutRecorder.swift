import SwiftUI
import AppKit

struct ShortcutRecorder: NSViewRepresentable {
    let onKey: (NSEvent) -> Void
    let onCancel: () -> Void
    let label: String

    func makeNSView(context: Context) -> RecordingView {
        let view = RecordingView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textField)
        view.setAccessibilityIdentifier("globalShortcutRecorder")
        return view
    }

    func updateNSView(_ view: RecordingView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
        view.setAccessibilityLabel(label)
    }

    static func dismantleNSView(_ view: RecordingView, coordinator: ()) {
        view.onKey = nil
        view.onCancel = nil
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }

    final class RecordingView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(cancelRecording), name: NSWindow.didResignKeyNotification, object: window)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.onKey != nil else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) { onKey?(event) }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            onKey?(event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            cancelRecording()
            return true
        }

        @objc private func cancelRecording() {
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        }
    }
}

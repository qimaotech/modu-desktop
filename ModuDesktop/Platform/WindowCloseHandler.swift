import SwiftUI
import AppKit
import ModuCore

struct WindowCloseHandler: NSViewRepresentable {
    var shouldQuit: () -> Bool
    var onClose: () -> Void = {}
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldQuit = shouldQuit
        context.coordinator.onClose = onClose
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.delegate !== context.coordinator { context.coordinator.original = window.delegate; window.delegate = context.coordinator }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(shouldQuit: shouldQuit, onClose: onClose) }
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldQuit: () -> Bool
        var onClose: () -> Void
        private let terminate: () -> Void
        weak var original: (any NSWindowDelegate)?
        init(shouldQuit: @escaping () -> Bool, onClose: @escaping () -> Void = {}, terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
            self.shouldQuit = shouldQuit
            self.onClose = onClose
            self.terminate = terminate
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldQuit() { terminate(); return false }
            guard original?.windowShouldClose?(sender) ?? true else { return false }
            onClose()
            return true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}

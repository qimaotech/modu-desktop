import SwiftUI
import AppKit
import ModuCore

struct WindowCloseHandler: NSViewRepresentable {
    var shouldQuit: () -> Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldQuit = shouldQuit
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.delegate !== context.coordinator { context.coordinator.original = window.delegate; window.delegate = context.coordinator }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(shouldQuit: shouldQuit) }
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldQuit: () -> Bool
        private let terminate: () -> Void
        weak var original: (any NSWindowDelegate)?
        init(shouldQuit: @escaping () -> Bool, terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
            self.shouldQuit = shouldQuit
            self.terminate = terminate
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldQuit() { terminate(); return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}

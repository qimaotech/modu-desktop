import SwiftUI
import AppKit
import ModuCore

struct WindowCloseHandler: NSViewRepresentable {
    var quit: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.quit = quit
            if window.delegate !== context.coordinator { context.coordinator.original = window.delegate; window.delegate = context.coordinator }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, NSWindowDelegate {
        var quit = false
        weak var original: (any NSWindowDelegate)?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if quit { NSApp.terminate(nil); return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}

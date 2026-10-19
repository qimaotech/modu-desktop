import SwiftUI
import AppKit
import ModuCore

struct WindowChromeHeight: NSViewRepresentable {
    @Binding var height: CGFloat
    var onWindow: ((NSWindow) -> Void)? = nil
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow?(window)
            let measured = window.frame.height - window.contentLayoutRect.height
            if height != measured { height = measured }
        }
    }
}

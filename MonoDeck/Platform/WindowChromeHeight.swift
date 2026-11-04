import SwiftUI
import AppKit
import MonoDeckCore

struct WindowChromeHeight: NSViewControllerRepresentable {
    @Binding var height: CGFloat
    var onWindow: ((NSWindow) -> Void)? = nil
    func makeNSViewController(context: Context) -> Controller { Controller(onWindow: onWindow) }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.onWindow = onWindow
        DispatchQueue.main.async {
            guard let window = controller.view.window else { return }
            onWindow?(window)
            let measured = window.frame.height - window.contentLayoutRect.height
            if height != measured { height = measured }
        }
    }

    final class Controller: NSViewController {
        var onWindow: ((NSWindow) -> Void)?

        init(onWindow: ((NSWindow) -> Void)?) {
            self.onWindow = onWindow
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() { view = NSView() }

        override func viewWillAppear() {
            super.viewWillAppear()
            // Configure the title bar before the window's first visible layout.
            if let window = view.window { onWindow?(window) }
        }
    }
}

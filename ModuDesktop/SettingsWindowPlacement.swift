import AppKit
import SwiftUI

struct SettingsWindowPlacement: NSViewControllerRepresentable {
    var size: CGSize
    var sourceWindow: () -> NSWindow?

    func makeNSViewController(context: Context) -> Controller {
        Controller(size: size, sourceWindow: sourceWindow)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.size = size
        controller.sourceWindow = sourceWindow
        controller.centerIfNeeded()
    }

    static func dismantleNSViewController(_ controller: Controller, coordinator: ()) {
        controller.stopObserving()
    }

    final class Controller: NSViewController {
        var size: CGSize
        var sourceWindow: () -> NSWindow?
        private weak var observedWindow: NSWindow?
        private var needsCenter = true
        private var appearing = false

        init(size: CGSize, sourceWindow: @escaping () -> NSWindow?) {
            self.size = size
            self.sourceWindow = sourceWindow
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() { view = NSView() }

        override func viewWillAppear() {
            super.viewWillAppear()
            appearing = true
            centerIfNeeded()
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            centerIfNeeded()
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            appearing = false
        }

        @objc func centerIfNeeded() {
            guard appearing, let window = viewIfLoaded?.window else { return }
            if observedWindow !== window {
                stopObserving()
                observedWindow = window
                needsCenter = true
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(centerIfNeeded), name: NSWindow.didResizeNotification, object: window)
            }
            // SwiftUI adjusts the content height after measuring the title bar.
            guard needsCenter, abs(window.frame.width - size.width) < 1, abs(window.frame.height - size.height) < 1 else { return }
            let source = sourceWindow()
            guard let screen = (source?.isVisible == true ? source?.screen : nil) ?? window.screen ?? NSScreen.main else { return }
            needsCenter = false
            window.setFrameOrigin(Self.centeredOrigin(size: window.frame.size, visibleFrame: screen.visibleFrame))
        }

        static func centeredOrigin(size: CGSize, visibleFrame: CGRect) -> CGPoint {
            CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
        }

        @objc private func windowWillClose() {
            needsCenter = true
            appearing = false
        }

        func stopObserving() {
            if let window = observedWindow { NotificationCenter.default.removeObserver(self, name: nil, object: window) }
            observedWindow = nil
        }
    }
}

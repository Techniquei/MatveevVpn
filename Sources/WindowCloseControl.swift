import SwiftUI
import AppKit

// macOS 13 has no windowDismissBehavior API. Use the native close button so
// both its click and the standard Close command respect the busy operation.
// Remove this bridge when the minimum OS supports windowDismissBehavior.
struct WindowCloseControl: NSViewRepresentable {
    let isBusy: Bool
    var onClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> CloseButtonView { CloseButtonView() }

    func updateNSView(_ view: CloseButtonView, context: Context) {
        view.closingDisabled = isBusy
        view.onClose = onClose
    }

    static func dismantleNSView(_ view: CloseButtonView, coordinator: ()) {
        view.window?.standardWindowButton(.closeButton)?.isEnabled = true
        view.onClose = nil
    }

    final class CloseButtonView: NSView {
        var onClose: (() -> Void)?

        var closingDisabled = false {
            didSet { updateCloseButton() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let window {
                notifications.addObserver(self, selector: #selector(windowWillClose),
                                          name: NSWindow.willCloseNotification, object: window)
            }
            updateCloseButton()
        }

        @objc private func windowWillClose() {
            onClose?()
        }

        private func updateCloseButton() {
            window?.standardWindowButton(.closeButton)?.isEnabled = !closingDisabled
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

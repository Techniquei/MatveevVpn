import SwiftUI
import AppKit

// macOS 13 has no windowDismissBehavior API. Use the native close button so
// both its click and the standard Close command respect the busy operation.
// Remove this bridge when the minimum OS supports windowDismissBehavior.
struct WindowCloseControl: NSViewRepresentable {
    let isBusy: Bool

    func makeNSView(context: Context) -> CloseButtonView { CloseButtonView() }

    func updateNSView(_ view: CloseButtonView, context: Context) {
        view.closingDisabled = isBusy
    }

    static func dismantleNSView(_ view: CloseButtonView, coordinator: ()) {
        view.window?.standardWindowButton(.closeButton)?.isEnabled = true
    }

    final class CloseButtonView: NSView {
        var closingDisabled = false {
            didSet { updateCloseButton() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateCloseButton()
        }

        private func updateCloseButton() {
            window?.standardWindowButton(.closeButton)?.isEnabled = !closingDisabled
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

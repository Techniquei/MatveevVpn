import SwiftUI
import AppKit

@main struct WindowCloseControlTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func window() -> NSWindow {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            result.isReleasedWhenClosed = false
            return result
        }
        let first = window()
        let second = window()
        let control = WindowCloseControl.CloseButtonView()
        control.closingDisabled = true
        first.contentView?.addSubview(control)
        precondition(first.standardWindowButton(.closeButton)?.isEnabled == false, "The first update arrives before the SwiftUI view attaches to its window")
        control.closingDisabled = false
        precondition(first.standardWindowButton(.closeButton)?.isEnabled == true)
        control.closingDisabled = true
        WindowCloseControl.dismantleNSView(control, coordinator: ())
        precondition(first.standardWindowButton(.closeButton)?.isEnabled == true, "Removing the bridge must restore the window control")
        second.contentView?.addSubview(control)
        precondition(second.standardWindowButton(.closeButton)?.isEnabled == false)
        control.closingDisabled = false
        precondition(second.standardWindowButton(.closeButton)?.isEnabled == true)
        precondition(control.hitTest(.zero) == nil, "The bridge must not intercept input or window dragging")
        var editorOpen = true
        control.onClose = { editorOpen = false }
        first.close()
        precondition(editorOpen, "Closing an unrelated window must preserve the editor state")
        second.close()
        precondition(!editorOpen, "Closing the native editor window must clear its open state")
        print("window close control: attachment, busy state, reuse and input passthrough passed")
    }
}

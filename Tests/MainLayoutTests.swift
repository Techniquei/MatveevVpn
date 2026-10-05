import SwiftUI
import AppKit

private extension SpeedMonitor {
    static func assertTunnelSelection() {
        let interfaces = [(name: "en0", address: "192.168.31.38"), (name: "utun4", address: "198.18.0.1"), (name: "utun900", address: "169.254.250.2")]
        precondition(tunnelName(among: interfaces) == "utun900",
                     "Speed must follow the Xray utun local address, not the previous sing-box address")
        precondition(tunnelName(among: [(name: "utun4", address: "198.18.0.1")]) == nil)
        let now = Date()
        let first = pace(previous: nil, name: "utun900", received: 1_000, sent: 100, time: now)
        precondition(first.download == 0 && first.upload == 0)
        let live = pace(previous: first.next, name: "utun900", received: 5_000, sent: 1_100, time: now.addingTimeInterval(1))
        precondition(live.download == 4_000 && live.upload == 1_000)
        let restarted = pace(previous: live.next, name: "utun901", received: 50, sent: 10, time: now.addingTimeInterval(2))
        precondition(restarted.download == 0 && restarted.upload == 0,
                     "A replaced tunnel must start a new baseline instead of keeping the previous counters")
        let afterRestart = pace(previous: restarted.next, name: "utun901", received: 2_050, sent: 1_010, time: now.addingTimeInterval(3))
        precondition(afterRestart.download == 2_000 && afterRestart.upload == 1_000)
        let recycled = pace(previous: afterRestart.next, name: "utun901", received: 10, sent: 1, time: now.addingTimeInterval(4))
        precondition(recycled.download == 0 && recycled.upload == 0)
        let afterRecycle = pace(previous: recycled.next, name: "utun901", received: 410, sent: 201, time: now.addingTimeInterval(5))
        precondition(afterRecycle.download == 400 && afterRecycle.upload == 200,
                     "Counters that restart on the same utun must become the new baseline, not stay at zero")
    }
}

// validate.sh appends this test to the UI source to exercise its private views.
@main struct MainLayoutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        SpeedMonitor.assertTunnelSelection()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(directory: root, legacyDirectory: root.appendingPathComponent("none"), runtimeHashFile: root.appendingPathComponent("no-runtime"))
        var state = SavedState()
        state.subscription = (1...16).map {
            "vless://11111111-1111-1111-1111-111111111111@server\($0).example.invalid:443?security=tls#Server%20\($0)"
        }.joined(separator: "\n")
        state.selectedNodeID = try Subscription.nodes(state.subscription)[5].id
        try store.save(state)
        SystemService.installedValue = true
        let controller = VPNController(store: store)
        let host = NSHostingView(rootView: NodeListView(controller: controller).frame(width: 284))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()

        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScrollView).first
        }
        guard let scroll = findScrollView(host), let document = scroll.documentView else {
            preconditionFailure("The server list must remain scrollable")
        }
        // Reproduce the gutter used when macOS keeps scrollbars visible for a mouse.
        scroll.scrollerStyle = .legacy
        scroll.tile()
        precondition(document.frame.height > scroll.contentView.frame.height)
        precondition(abs(scroll.contentView.frame.width - scroll.frame.width) < 1,
                     "A scrollbar gutter must not make alternate rows narrower than the pinned row")
        precondition(abs(document.frame.width - scroll.frame.width) < 1,
                     "Server rows must fill the list width")
        precondition(abs(scroll.frame.width - host.frame.width) < 1,
                     "The server list must not add another inset inside the main content margin")
        controller.openSetup()
        let connectionHost = NSHostingView(rootView: ConnectionView(controller: controller))
        connectionHost.frame = NSRect(x: 0, y: 0, width: 1800, height: 600)
        let connectionWindow = NSWindow(contentRect: connectionHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        connectionWindow.isReleasedWhenClosed = false
        connectionWindow.contentView = connectionHost
        defer { connectionWindow.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        connectionHost.layoutSubtreeIfNeeded()
        guard let connectionScroll = findScrollView(connectionHost) else {
            preconditionFailure("Subscription options must remain scrollable")
        }
        precondition(connectionScroll.frame.width <= 480,
                     "A restored wide window must not stretch the subscription fields and compatibility controls")
        for (view, width) in [(AnyView(SettingsView(controller: controller)), CGFloat(540)),
                              (AnyView(RoutingRulesView(controller: controller)), CGFloat(640))] {
            let editor = NSHostingView(rootView: view)
            editor.frame = NSRect(x: 0, y: 0, width: 1800, height: 900)
            let editorWindow = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            editorWindow.isReleasedWhenClosed = false
            editorWindow.contentView = editor
            defer { editorWindow.close() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            editor.layoutSubtreeIfNeeded()
            guard let options = findScrollView(editor) else { preconditionFailure("Editor options must remain scrollable") }
            precondition(options.frame.width <= width, "Restored window sizes must not stretch editor controls")
        }
        print("UI layout: full-width server rows and compact subscription controls passed")
    }
}

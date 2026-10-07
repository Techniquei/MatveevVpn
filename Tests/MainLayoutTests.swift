import SwiftUI
import AppKit

// validate.sh appends this test to the UI source to exercise its private views.
@main struct MainLayoutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
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
        controller.autoFailoverEnabled = false
        controller.state.desiredOn = true
        let progressHost = NSHostingView(rootView: BackgroundConnectionStatusView(controller: controller).frame(width: 284))
        let progressWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 284, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        progressWindow.isReleasedWhenClosed = false
        progressWindow.contentView = progressHost
        defer { progressWindow.close() }
        for status in ["starting", "waiting for network", "waiting for direct DNS", "waiting for VPN DNS", "waiting to retry", "recovering"] {
            SystemService.runningValue = false
            SystemService.runtimeStatusValue = status
            controller.refresh()
            precondition(controller.isConnecting && !controller.isBusy,
                         "Service progress must not disable manual Disconnect")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            progressHost.frame = NSRect(origin: .zero, size: progressHost.fittingSize)
            progressHost.layoutSubtreeIfNeeded()
            precondition(abs(progressHost.frame.width - 284) < 1 && progressHost.frame.height > 20 && progressHost.frame.height < 100,
                         "Waiting-state copy must wrap within the main window")
        }
        let mainHost = NSHostingView(rootView: MainView(controller: controller, speedMonitor: SpeedMonitor()))
        mainHost.frame = NSRect(origin: .zero, size: mainHost.fittingSize)
        let mainWindow = NSWindow(contentRect: mainHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.contentView = mainHost
        defer { mainWindow.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        mainHost.layoutSubtreeIfNeeded()
        if let bitmap = mainHost.bitmapImageRepForCachingDisplay(in: mainHost.bounds) {
            mainHost.cacheDisplay(in: mainHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/matveev-vpn-background-progress.png"))
        }
        SystemService.runningValue = true
        SystemService.runtimeStatusValue = "running"
        controller.refresh()
        precondition(!controller.isConnecting && controller.connectionStatusText == "Connected")
        controller.state.desiredOn = false
        SystemService.runningValue = false
        SystemService.runtimeStatusValue = "stopped"
        controller.refresh()
        precondition(!controller.isConnecting && controller.connectionStatusText == "Disconnected")
        print("UI layout: full-width server rows and compact subscription controls and service connection progress passed")
    }
}

import SwiftUI

// Appended to the real UI source with fake config, command and subscription boundaries.
@main struct InteractionPreview: App {
    @StateObject private var controller: VPNController

    init() {
        SystemService.installedValue = true
        let root = try! temporaryDirectory()
        let store = StateStore(directory: root, legacyDirectory: root.appendingPathComponent("none"), runtimeHashFile: root.appendingPathComponent("none"))
        _controller = StateObject(wrappedValue: VPNController(store: store))
    }

    var body: some Scene {
        Window("Subscription — fake service", id: "connection") {
            ConnectionView(controller: controller).toolbar { PreviewNavigation() }
        }.windowResizability(.contentSize)
        Window("Settings — fake service", id: "settings") {
            SettingsView(controller: controller).toolbar { PreviewNavigation() }
        }.windowResizability(.contentSize)
        Window("Routing — fake service", id: "routing") {
            RoutingRulesView(controller: controller).toolbar { PreviewNavigation() }
        }.windowResizability(.contentSize)
        Window("Main — fake service", id: "main") {
            MainView(controller: controller, speedMonitor: SpeedMonitor()).toolbar { PreviewNavigation() }
        }.windowResizability(.contentSize)
    }
}

private struct PreviewNavigation: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Menu("Preview") {
            Button("Subscription") { openWindow(id: "connection") }
            Button("Settings") { openWindow(id: "settings") }
            Button("Routing") { openWindow(id: "routing") }
            Button("Main") { openWindow(id: "main") }
        }
    }
}

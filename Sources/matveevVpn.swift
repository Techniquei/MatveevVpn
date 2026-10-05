import SwiftUI
import AppKit
import Darwin

@MainActor
final class SpeedMonitor: ObservableObject {
    @Published var downloadSpeed: Double = 0
    @Published var uploadSpeed: Double = 0

    private struct TunnelPace {
        var name: String
        var received: UInt64
        var sent: UInt64
        var time: Date
    }

    private var previous: TunnelPace?
    private var timer: Timer?

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let monitor = self else { return }
            Task { @MainActor in monitor.sample() }
        }
    }

    private func sample() {
        let now = Date()
        guard let totals = Self.tunnelTotals() else {
            previous = nil
            updateSpeeds(download: 0, upload: 0)
            return
        }
        let paced = Self.pace(previous: previous, name: totals.name, received: totals.received, sent: totals.sent, time: now)
        previous = paced.next
        updateSpeeds(download: paced.download, upload: paced.upload)
    }

    // A restarted utun is a new interface or starts its counters over. That sample
    // is only a baseline, so the next interval shows the new tunnel's rate.
    private nonisolated static func pace(previous: TunnelPace?, name: String, received: UInt64, sent: UInt64, time: Date) -> (download: Double, upload: Double, next: TunnelPace) {
        let next = TunnelPace(name: name, received: received, sent: sent, time: time)
        guard let old = previous, old.name == name, received >= old.received, sent >= old.sent else {
            return (0, 0, next)
        }
        let elapsed = max(time.timeIntervalSince(old.time), 0.1)
        return (Double(received - old.received) / elapsed, Double(sent - old.sent) / elapsed, next)
    }

    private func updateSpeeds(download: Double, upload: Double) {
        downloadSpeed = download
        uploadSpeed = upload
    }

    // Local address of the Xray utun. policy.Build sets gateway 169.254.250.1/30;
    // macOS assigns this host the other address in that point-to-point pair.
    private nonisolated static let tunnelAddress = "169.254.250.2"

    private nonisolated static func tunnelName(among interfaces: [(name: String, address: String)]) -> String? {
        interfaces.first { $0.address == tunnelAddress }?.name
    }

    private nonisolated static func tunnelTotals() -> (name: String, received: UInt64, sent: UInt64)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var interfaces: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    interfaces.append((String(cString: interface.ifa_name), String(cString: buffer)))
                }
            }
            cursor = interface.ifa_next
        }

        guard let tunnelName = tunnelName(among: interfaces) else { return nil }
        cursor = firstAddress
        while let current = cursor {
            let interface = current.pointee
            if String(cString: interface.ifa_name) == tunnelName,
               let dataPointer = interface.ifa_data {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                return (tunnelName, UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
            }
            cursor = interface.ifa_next
        }
        return nil
    }
}

enum AppPalette {
    static let cyan = Color(red: 0.25, green: 0.80, blue: 0.94)
    static let blue = Color(red: 0.32, green: 0.48, blue: 0.95)
    static let violet = Color(red: 0.64, green: 0.55, blue: 0.94)
    static let background = LinearGradient(
        colors: [Color(red: 0.035, green: 0.065, blue: 0.13), Color(red: 0.065, green: 0.055, blue: 0.15)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

private struct ActionIconButton: View {
    let systemName: String
    let title: String
    var active = false
    var loading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Group {
                if loading { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: systemName).font(.system(size: 17, weight: .semibold)) }
            }
            .frame(width: 48, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.white : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(active ? AppPalette.blue.opacity(hovering && isEnabled ? 0.95 : 0.75) : Color.white.opacity(hovering && isEnabled ? 0.14 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(hovering && isEnabled ? 0.22 : 0), lineWidth: 1)
        }
        .scaleEffect(hovering && isEnabled && !reduceMotion ? 1.045 : 1)
        .opacity(isEnabled ? 1 : 0.42)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct TrafficSummaryView: View {
    @ObservedObject var monitor: SpeedMonitor
    @ObservedObject var controller: VPNController

    var body: some View {
        HStack(spacing: 10) {
            speedMetric(monitor.downloadSpeed, title: "Download", icon: "arrow.down", activeColor: AppPalette.cyan)
            speedMetric(monitor.uploadSpeed, title: "Upload", icon: "arrow.up", activeColor: AppPalette.violet)
        }
    }

    private func speedText(_ value: Double) -> String {
        if value < 1 { return "0 B/s" }
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1_048_576 { return String(format: "%.1f KB/s", value / 1024) }
        if value < 1_073_741_824 { return String(format: "%.1f MB/s", value / 1_048_576) }
        return String(format: "%.1f GB/s", value / 1_073_741_824)
    }

    private func speedMetric(_ value: Double, title: String, icon: String, activeColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(speedText(value))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(controller.isRunning ? activeColor : Color.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RoutingRulesView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var automaticRoutingEnabled = true
    @State private var automaticServices = Set<String>()
    @State private var adBlockingEnabled = false
    @State private var domainsText = ""
    @State private var confirmClear = false
    private let presetColumns = [GridItem(.adaptive(minimum: 145), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppWindowHeader(title: "Routing", subtitle: "Choose what uses the VPN", icon: "arrow.triangle.branch")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Automatically route selected services", isOn: $automaticRoutingEnabled)
                            .font(.headline)
                            .modifier(InteractiveHover())
                        Text("Presets route selected services through the VPN. Lists refresh daily.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let date = controller.automaticRoutingLastUpdate {
                            Label("Last data refresh: \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                                .font(.caption).foregroundStyle(AppPalette.cyan)
                        } else {
                            Text("Data update date is not available yet.").font(.caption).foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 9) {
                            ForEach(AutomaticRoutingCatalog.services, id: \.self) { service in
                                Toggle(AutomaticRoutingCatalog.title(for: service), isOn: presetBinding(service))
                                    .toggleStyle(.checkbox)
                                    .modifier(InteractiveHover())
                            }
                        }
                        .disabled(!automaticRoutingEnabled)
                        .opacity(automaticRoutingEnabled ? 1 : 0.55)

                        HStack {
                            Text("Selected: \(automaticServices.count) of \(AutomaticRoutingCatalog.services.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Select All") { automaticServices = Set(AutomaticRoutingCatalog.services) }
                                .disabled(!automaticRoutingEnabled || automaticServices.count == AutomaticRoutingCatalog.services.count)
                            Button("Clear Presets") { automaticServices.removeAll() }
                                .disabled(!automaticRoutingEnabled || automaticServices.isEmpty)
                        }
                        .controlSize(.small)

                        Divider()
                        Toggle("Block ads and trackers", isOn: $adBlockingEnabled)
                            .font(.headline)
                            .modifier(InteractiveHover())
                        Text("Blocks known third-party advertising and tracking domains. Ads delivered from the same domain as a video may still appear.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom rules").font(.headline)
                        Text("One entry per line. Use these for sites that are not covered by a preset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        editor(title: "Domains", hint: "example.com or *.example.com", text: $domainsText, height: 145)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            Divider()

            HStack {
                Text(controller.rulesMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Revert Changes") { load(controller.state.rules) }
                Button("Clear Custom…") { confirmClear = true }
                Button("Save and Apply") {
                    controller.applyRoutingRules(
                        automaticRoutingEnabled: automaticRoutingEnabled,
                        automaticServices: automaticServices,
                        adBlockingEnabled: adBlockingEnabled,
                        domains: lines(domainsText),
                        applications: [],
                        paths: []
                    )
                }
                .buttonStyle(HoverButtonStyle(prominent: true))
                .disabled(controller.isBusy)
            }
        }
        .controlSize(.large)
        .tint(AppPalette.blue)
        .padding(22)
        .frame(width: 640, height: 700)
        .background(AppPalette.background)
        .preferredColorScheme(.dark)
        .buttonStyle(HoverButtonStyle())
        .confirmationDialog("Clear custom routing rules?", isPresented: $confirmClear) {
            Button("Clear Custom Rules", role: .destructive) { domainsText = "" }
        } message: { Text("Changes take effect after Save and Apply.") }
        .onAppear {
            controller.rulesMessage = ""
            controller.loadAutomaticRoutingUpdate()
            load(controller.state.rules)
        }
    }

    private func editor(title: String, hint: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text("For example: \(hint)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .frame(height: height)
                .modifier(InteractiveHover())
        }
        .frame(maxWidth: .infinity)
    }

    private func presetBinding(_ service: String) -> Binding<Bool> {
        Binding(
            get: { automaticServices.contains(service) },
            set: { selected in
                if selected { automaticServices.insert(service) }
                else { automaticServices.remove(service) }
            }
        )
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private func load(_ rules: RoutingRules) {
        automaticRoutingEnabled = rules.automaticRoutingEnabled
        automaticServices = Set(rules.automaticServices)
        adBlockingEnabled = rules.adBlockingEnabled
        domainsText = rules.domains.joined(separator: "\n")
    }
}

private struct NodeListView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringNodeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Servers").font(.headline)
                Text("\(controller.availableNodes.count)").font(.caption).foregroundStyle(.secondary)
                if !controller.isInitialSetup {
                    Button("Change") {
                        controller.openSetup()
                        openWindow(id: "connection")
                    }
                    .buttonStyle(HoverButtonStyle())
                    .controlSize(.small)
                    .help("Change subscription")
                    .accessibilityLabel("Change subscription")
                    .disabled(controller.isBusy)
                }
                Spacer(minLength: 0)
                if controller.testingNodes {
                    ProgressView().controlSize(.small)
                } else {
                    Button { controller.testNodes() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(HoverButtonStyle())
                        .controlSize(.small)
                        .help("Check server latency")
                        .accessibilityLabel("Check server latency")
                        .disabled(controller.isBusy)
                }
            }

            if controller.availableNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network").font(.title).foregroundStyle(.secondary)
                    Text("Add your subscription to see servers.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add subscription") {
                        controller.openSetup()
                        openWindow(id: "connection")
                    }
                    .buttonStyle(HoverButtonStyle(prominent: true))
                    .disabled(controller.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let selected = controller.selectedNode {
                    nodeButton(selected, selected: true)
                    Divider()
                }
                if controller.unselectedNodes.isEmpty {
                    Text("No other servers in this subscription.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(controller.unselectedNodes) { node in
                                nodeButton(node, selected: false)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // Unlike .hidden, .never removes the scroller gutter with a mouse attached.
                    .scrollIndicators(.never)
                }
            }
        }
        .frame(height: 320)
        .onAppear { controller.testNodes() }
    }

    private func nodeButton(_ node: VPNNode, selected: Bool) -> some View {
        let hovering = hoveringNodeID == node.id && !controller.isBusy
        return Button { controller.selectNode(node.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let result = controller.probeResults[node.id] {
                        Text(result.displayText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppPalette.cyan)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hovering ? Color.white : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(selected ? AppPalette.cyan.opacity(hovering ? 0.22 : 0.12) : Color.white.opacity(hovering ? 0.11 : 0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(hovering ? 0.16 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .opacity(controller.isBusy ? 0.6 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .onHover { inside in
            if inside { hoveringNodeID = node.id }
            else if hoveringNodeID == node.id { hoveringNodeID = nil }
        }
        .help("Connect to " + node.name)
        .accessibilityLabel("Connect to " + node.name)
        .accessibilityValue(selected ? "Current server" : "")
    }
}

private struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: VPNController
    @ObservedObject var speedMonitor: SpeedMonitor
    @Environment(\.openWindow) private var openWindow

    private var primaryActionTitle: String {
        if controller.state.subscription.isEmpty { return "Add subscription" }
        if !controller.isInstalled || controller.state.selectedNodeID == nil { return "Install and set up" }
        return controller.state.desiredOn ? "Disconnect" : "Connect"
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("matveevVpn")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("v\(VPNController.releaseVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle(controller.state.rules.mode == .selective ? "Selective" : "All traffic", isOn: Binding(
                        get: { controller.state.rules.mode == .selective },
                        set: { controller.changeMode($0 ? .selective : .all) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!controller.isInstalled || controller.isBusy || controller.state.selectedNodeID == nil)
                    .help("On uses selective routing rules. Off sends all traffic through the VPN.")
                    .modifier(InteractiveHover())
                }

                if controller.needsUpgrade {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("A system component update is required")
                        Spacer()
                        Button("Update") { controller.repair() }
                    }
                    .padding(11)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                }

                if controller.isBusy {
                    Text(controller.message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                NodeListView(controller: controller)

                TrafficSummaryView(
                    monitor: speedMonitor,
                    controller: controller
                )

                if controller.isRecovering {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Automatic recovery is running")
                            .font(.caption)
                        Spacer()
                        Button(controller.isStoppingRecovery ? "Stopping…" : "Stop Recovery") { controller.cancelAutomaticRecovery() }
                            .buttonStyle(HoverButtonStyle(prominent: true))
                            .disabled(controller.isStoppingRecovery)
                    }
                    .padding(9)
                    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    ActionIconButton(systemName: "power", title: primaryActionTitle, active: controller.isRunning, loading: controller.isBusy) {
                        if !controller.isInstalled || controller.state.selectedNodeID == nil {
                            controller.openSetup()
                            openWindow(id: "connection")
                        } else {
                            controller.run(controller.state.desiredOn ? "off" : "on")
                        }
                    }
                    .disabled(controller.isBusy)
                    .accessibilityValue(controller.isRunning ? "Connected" : "Disconnected")

                    ActionIconButton(systemName: "arrow.clockwise", title: "Restart VPN") { controller.run("restart") }
                    .disabled(!controller.isInstalled || controller.state.selectedNodeID == nil || controller.isBusy)

                    ActionIconButton(systemName: "arrow.triangle.branch", title: "Routing rules") {
                        if controller.needsUpgrade { controller.repair() }
                        else { openWindow(id: "routing") }
                    }
                    .disabled(!controller.isInstalled || controller.state.selectedNodeID == nil || controller.isBusy)

                    ActionIconButton(systemName: "gearshape", title: "Settings and diagnostics") { openWindow(id: "settings") }
                    .disabled(controller.isBusy)
                }
                .padding(6)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .center)

                if !controller.failureReport.isEmpty {
                    HStack {
                        Label(controller.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer()
                        Button { controller.exportLog() } label: { Image(systemName: "square.and.arrow.up") }
                            .help("Export unfiltered application log")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .buttonStyle(HoverButtonStyle())
        .onAppear {
            if controller.showConnection { openWindow(id: "connection") }
        }
        .onChange(of: controller.showConnection) { presented in
            if presented { openWindow(id: "connection") }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.refresh()
            }
        }
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openMainWindow else { return true }
        openMainWindow()
        sender.activate(ignoringOtherApps: true)
        return false
    }
}

private struct MainWindowContent: View {
    let appDelegate: AppDelegate
    @ObservedObject var controller: VPNController
    @ObservedObject var speedMonitor: SpeedMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainView(controller: controller, speedMonitor: speedMonitor)
            .onAppear {
                appDelegate.openMainWindow = { openWindow(id: "main") }
            }
    }
}

@main
struct MatveevVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = VPNController()
    @StateObject private var speedMonitor = SpeedMonitor()
    var body: some Scene {
        Window("matveevVpn", id: "main") {
            MainWindowContent(appDelegate: appDelegate, controller: controller, speedMonitor: speedMonitor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        Window("Subscription", id: "connection") {
            ConnectionView(controller: controller)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        Window("Settings & Diagnostics", id: "settings") {
            SettingsView(controller: controller)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        Window("Routing rules", id: "routing") {
            RoutingRulesView(controller: controller)
                .background(WindowCloseControl(isBusy: controller.isBusy))
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        MenuBarExtra("matveevVpn", systemImage: controller.isRunning ? "network.badge.shield.half.filled" : "network") {
            MenuContent(controller: controller)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: VPNController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
            Text(controller.isRunning ? "Connected" : "Disconnected")
            Text(controller.selectedNode?.name ?? "Not selected")
            Button(controller.state.desiredOn ? "Turn Off" : "Turn On") { controller.run(controller.state.desiredOn ? "off" : "on") }
                .disabled(controller.isBusy || !controller.isInstalled || controller.state.selectedNodeID == nil)
            if controller.isRecovering {
                Button(controller.isStoppingRecovery ? "Stopping Automatic Recovery…" : "Stop Automatic Recovery") { controller.cancelAutomaticRecovery() }
                    .disabled(controller.isStoppingRecovery)
            }
            Button("Open matveevVpn") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
    }
}

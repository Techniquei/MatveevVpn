import SwiftUI
import AppKit
import Charts
import Darwin

struct TrafficPoint: Identifiable {
    let slot: Int
    let download: Double
    let upload: Double

    var id: Int { slot }
}

@MainActor
final class SpeedMonitor: ObservableObject {
    @Published var downloadSpeed: Double = 0
    @Published var uploadSpeed: Double = 0
    @Published var samples: [TrafficPoint] = (0..<60).map {
        TrafficPoint(slot: $0, download: 0, upload: 0)
    }

    private var previous: (received: UInt64, sent: UInt64, time: Date)?
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
            append(download: 0, upload: 0)
            return
        }

        guard let old = previous else {
            previous = (totals.received, totals.sent, now)
            append(download: 0, upload: 0)
            return
        }
        let elapsed = max(now.timeIntervalSince(old.time), 0.1)
        let receivedDelta = totals.received >= old.received ? totals.received - old.received : 0
        let sentDelta = totals.sent >= old.sent ? totals.sent - old.sent : 0
        previous = (totals.received, totals.sent, now)
        append(download: Double(receivedDelta) / elapsed, upload: Double(sentDelta) / elapsed)
    }

    private func append(download: Double, upload: Double) {
        downloadSpeed = download
        uploadSpeed = upload
        let previous = samples.suffix(59)
        samples = previous.enumerated().map {
            TrafficPoint(slot: $0.offset, download: $0.element.download, upload: $0.element.upload)
        }
        samples.append(TrafficPoint(slot: 59, download: download, upload: upload))
    }

    private nonisolated static func tunnelTotals() -> (received: UInt64, sent: UInt64)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var tunnelName: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
                   String(cString: buffer) == "198.18.0.1" {
                    tunnelName = String(cString: interface.ifa_name)
                    break
                }
            }
            cursor = interface.ifa_next
        }

        guard let tunnelName else { return nil }
        cursor = firstAddress
        while let current = cursor {
            let interface = current.pointee
            if String(cString: interface.ifa_name) == tunnelName,
               let dataPointer = interface.ifa_data {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
            }
            cursor = interface.ifa_next
        }
        return nil
    }
}

private struct BrandIcon: View {
    var size: CGFloat = 52

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .cyan.opacity(0.28), radius: 18, y: 6)
    }
}

private struct ActionIconButton: View {
    let systemName: String
    let title: String
    var primary = false
    var active = false
    var loading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: systemName).font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.white : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(primary && active ? Color.accentColor.opacity(hovering ? 1 : 0.88) : Color.white.opacity(hovering ? 0.14 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(hovering && isEnabled ? 0.22 : 0), lineWidth: 1)
        }
        .scaleEffect(hovering && isEnabled ? 1.045 : 1)
        .opacity(isEnabled ? 1 : 0.42)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .allowsHitTesting(!loading)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ConnectionOverviewCard: View {
    @ObservedObject var monitor: SpeedMonitor
    @ObservedObject var controller: VPNController

    private var chartMaximum: Double {
        let measured = monitor.samples.reduce(0) { maximum, point in
            max(maximum, point.download + point.upload)
        }
        return max(1024, measured * 1.1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Chart(monitor.samples) { point in
                LineMark(
                    x: .value("Second", point.slot),
                    y: .value("Traffic", point.download + point.upload)
                )
                .foregroundStyle(LinearGradient(colors: [.cyan, .pink], startPoint: .leading, endPoint: .trailing))
                .lineStyle(StrokeStyle(lineWidth: 2.2))
                .interpolationMethod(.stepStart)
            }
            .chartXScale(domain: 0...59)
            .chartYScale(domain: 0...chartMaximum)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .transaction { transaction in
                transaction.animation = nil
            }
            .frame(height: 54)
            .padding(.top, 34)
            .opacity(controller.isRunning ? 0.62 : 0.16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Current node")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        speedMetric(monitor.downloadSpeed, icon: "arrow.down", activeColor: .cyan)
                        speedMetric(monitor.uploadSpeed, icon: "arrow.up", activeColor: .pink)
                    }
                }

                Picker("Current node", selection: Binding(
                    get: { controller.state.selectedNodeID },
                    set: { if let id = $0 { controller.selectNode(id) } }
                )) {
                    Text("Not selected").tag(Optional<String>.none)
                    ForEach(controller.availableNodes) { node in
                        Text(node.name).tag(Optional(node.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 230, alignment: .leading)
                .disabled(controller.isBusy || controller.availableNodes.isEmpty)
            }
        }
        .padding(10)
        .frame(height: 94)
        .background(.white.opacity(controller.isRunning ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if !controller.isRunning {
                RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.08)).allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: controller.isRunning)
    }

    private func speedText(_ value: Double) -> String {
        if value < 1 { return "0 B/s" }
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1_048_576 { return String(format: "%.1f KB/s", value / 1024) }
        if value < 1_073_741_824 { return String(format: "%.1f MB/s", value / 1_048_576) }
        return String(format: "%.1f GB/s", value / 1_073_741_824)
    }

    private func speedMetric(_ value: Double, icon: String, activeColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(speedText(value))
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(controller.isRunning ? activeColor : Color.secondary)
        .frame(width: 92, alignment: .trailing)
    }

}

private struct RoutingRulesView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var domainsText = ""
    @State private var applicationsText = ""
    @State private var pathsText = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Routing rules").font(.title2.bold())
                    Text("One entry per line. Unmatched traffic uses the direct connection.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(alignment: .top, spacing: 14) {
                editor(title: "Domains", hint: "example.com or *.example.com", text: $domainsText)
                editor(title: "Application process names", hint: "Example App", text: $applicationsText)
            }
            editor(title: "Application paths (regular expressions)", hint: "Use Add Application to include its helpers", text: $pathsText)
            Button("Add Application…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.applicationBundle]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                if panel.runModal() == .OK, let url = panel.url {
                    let pattern = "^.*/" + NSRegularExpression.escapedPattern(for: url.lastPathComponent) + "/Contents/.*"
                    pathsText += (pathsText.isEmpty ? "" : "\n") + pattern
                }
            }

            HStack {
                Text(controller.rulesMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Revert Changes") { load(controller.currentRoutingRules()) }
                Button("Clear All…") { confirmClear = true }
                Button("Save and Apply") {
                    controller.applyRoutingRules(
                        domains: lines(domainsText),
                        applications: lines(applicationsText),
                        paths: lines(pathsText)
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy)
            }
        }
        .padding(16)
        .frame(width: 620, height: 580)
        .confirmationDialog("Clear all routing rules?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { domainsText = ""; applicationsText = ""; pathsText = "" }
        } message: { Text("Changes take effect after Save and Apply.") }
        .preferredColorScheme(.dark)
        .onAppear {
            controller.rulesMessage = ""
            load(controller.currentRoutingRules())
        }
    }

    private func editor(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text("For example: \(hint)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity)
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private func load(_ rules: RoutingRules) {
        domainsText = rules.domains.joined(separator: "\n")
        applicationsText = rules.applications.joined(separator: "\n")
        pathsText = rules.processPathRegexes.joined(separator: "\n")
    }
}

private struct NodeSelectionView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose node").font(.title2.bold())
                    Text("Nodes are loaded from your saved subscription.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            Picker("Node", selection: $selectedIndex) {
                ForEach(controller.availableNodes) { node in
                    Text(node.name + (controller.probeResults[node.id].map { " — " + $0 } ?? "")).tag(Optional(node.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text(controller.nodeMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(minHeight: 16)

            HStack(spacing: 10) {
                if controller.testingNodes {
                    Button { controller.cancelNodeTests() } label: {
                        Text("Cancel Test").frame(maxWidth: .infinity)
                    }
                } else {
                    Button { controller.testNodes() } label: {
                        Text("Test Nodes").frame(maxWidth: .infinity)
                    }
                    .disabled(controller.isBusy)
                }
                Button {
                    if let selectedIndex { controller.selectNode(selectedIndex) }
                } label: {
                    Text("Switch Node").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIndex == nil || controller.isBusy || controller.availableNodes.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(width: 450, height: 210)
        .preferredColorScheme(.dark)
        .onAppear {
            selectedIndex = controller.currentNodeIndex
            controller.nodeMessage = ""
            controller.loadAvailableNodes()
        }
        .onChange(of: controller.availableNodes) { nodes in
            if selectedIndex == nil {
                selectedIndex = controller.currentNodeIndex ?? nodes.first?.id
            }
        }
    }
}

private struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: VPNController
    @ObservedObject var speedMonitor: SpeedMonitor
    @State private var showRoutingRules = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.16),
                                    Color(red: 0.06, green: 0.04, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    BrandIcon()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("matveevVpn")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            Text("v\(VPNController.releaseVersion)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text("Your connection · Your rules")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("Routing", isOn: Binding(
                        get: { controller.state.rules.mode == .selective },
                        set: { controller.changeMode($0 ? .selective : .all) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!controller.isInstalled || controller.isBusy || controller.state.selectedNodeID == nil)
                    .help("On uses selective routing rules. Off sends all traffic through the VPN.")
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

                ConnectionOverviewCard(
                    monitor: speedMonitor,
                    controller: controller
                )

                HStack(spacing: 12) {
                    ActionIconButton(systemName: "power", title: !controller.isInstalled || controller.state.selectedNodeID == nil ? "Install and set up" : (controller.isRunning ? "Turn off" : "Turn on"), primary: true, active: controller.isRunning, loading: controller.isBusy) {
                        if !controller.isInstalled || controller.state.selectedNodeID == nil {
                            controller.openSetup()
                        } else {
                            controller.run(controller.isRunning ? "off" : "on")
                        }
                    }

                    ActionIconButton(systemName: "arrow.clockwise", title: "Restart VPN") { controller.run("restart") }
                    .disabled(!controller.isInstalled || controller.state.selectedNodeID == nil || controller.isBusy)

                    ActionIconButton(systemName: "arrow.triangle.branch", title: "Routing rules") {
                        if controller.needsUpgrade { controller.repair() }
                        else { showRoutingRules = true }
                    }
                    .disabled(!controller.isInstalled || controller.state.selectedNodeID == nil || controller.isBusy)

                    ActionIconButton(systemName: "gearshape", title: "Settings and diagnostics") { showSettings = true }
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
                        Button { controller.copyFailureReport() } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy error report")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showRoutingRules) {
            RoutingRulesView(controller: controller)
        }
        .sheet(isPresented: Binding(get: { controller.showConnection && !showSettings }, set: { controller.showConnection = $0 })) { ConnectionView(controller: controller) }
        .sheet(isPresented: $showSettings) { SettingsView(controller: controller) }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.refreshWhenActive()
            }
        }
    }

}

@main
struct MatveevVPNApp: App {
    @StateObject private var controller = VPNController()
    @StateObject private var speedMonitor = SpeedMonitor()
    var body: some Scene {
        Window("matveevVpn", id: "main") {
            MainView(controller: controller, speedMonitor: speedMonitor)
        }
        .windowStyle(.hiddenTitleBar)
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
            Text(controller.node)
            Button(controller.isRunning ? "Turn Off" : "Turn On") { controller.run(controller.isRunning ? "off" : "on") }
                .disabled(controller.isBusy || !controller.isInstalled || controller.state.selectedNodeID == nil)
            Button("Open matveevVpn") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
    }
}

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
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .cyan.opacity(0.28), radius: 18, y: 6)
    }
}

private struct SpeedChartCard: View {
    @ObservedObject var monitor: SpeedMonitor

    private var chartMaximum: Double {
        let measured = monitor.samples.reduce(0) { maximum, point in
            max(maximum, point.download, point.upload)
        }
        return max(1024, measured * 1.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tunnel traffic").font(.headline)
                Spacer()
                Label(speedText(monitor.downloadSpeed), systemImage: "arrow.down")
                    .foregroundStyle(.cyan)
                Label(speedText(monitor.uploadSpeed), systemImage: "arrow.up")
                    .foregroundStyle(.pink)
            }

            Chart(monitor.samples) { point in
                LineMark(
                    x: .value("Second", point.slot),
                    y: .value("Download", point.download),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepStart)

                LineMark(
                    x: .value("Second", point.slot),
                    y: .value("Upload", point.upload),
                    series: .value("Direction", "Upload")
                )
                .foregroundStyle(.pink)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepStart)
            }
            .chartXScale(domain: 0...59)
            .chartYScale(domain: 0...chartMaximum)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let speed = value.as(Double.self) { Text(shortSpeed(speed)) }
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .frame(height: 105)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func speedText(_ value: Double) -> String {
        if value < 1 { return "0 B/s" }
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1_048_576 { return String(format: "%.1f KB/s", value / 1024) }
        if value < 1_073_741_824 { return String(format: "%.1f MB/s", value / 1_048_576) }
        return String(format: "%.1f GB/s", value / 1_073_741_824)
    }

    private func shortSpeed(_ value: Double) -> String {
        if value >= 1_048_576 { return String(format: "%.1fM", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0fK", value / 1024) }
        return "0"
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
        VStack(alignment: .leading, spacing: 16) {
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
        .padding(22)
        .frame(width: 760, height: 640)
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

            HStack {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text(controller.nodeMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if controller.testingNodes {
                    Button("Cancel Test") { controller.cancelNodeTests() }
                } else {
                    Button("Test Nodes") { controller.testNodes() }.disabled(controller.isBusy)
                }
                Button("Switch Node") {
                    if let selectedIndex { controller.selectNode(selectedIndex) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIndex == nil || controller.isBusy || controller.availableNodes.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520, height: 210)
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
    @State private var confirmRemoval = false
    @State private var showRoutingRules = false
    @State private var showNodeSelection = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.16),
                                    Color(red: 0.06, green: 0.04, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    BrandIcon()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("matveevVpn").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Your connection · Your rules").foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge
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

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Current node").font(.caption).foregroundStyle(.secondary)
                        Text(controller.node).font(.headline).lineLimit(1)
                    }
                    Spacer()
                    if controller.isInstalled {
                        Button("Change…") { showNodeSelection = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                Picker("VPN mode", selection: Binding(get: { controller.state.rules.mode }, set: { controller.changeMode($0) })) {
                    Text("Selective").tag(RoutingMode.selective)
                    Text("All Traffic").tag(RoutingMode.all)
                }
                .pickerStyle(.segmented)
                .disabled(!controller.isInstalled || controller.isBusy || controller.state.selectedNodeID == nil)

                SpeedChartCard(monitor: speedMonitor)

                HStack(spacing: 10) {
                    if !controller.isInstalled || controller.state.selectedNodeID == nil {
                        Button("Install and set up") { controller.openSetup() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(controller.isRunning ? "Turn off" : "Turn on") {
                            controller.run(controller.isRunning ? "off" : "on")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Restart") { controller.run("restart") }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Routing rules…") {
                        if controller.needsUpgrade { controller.repair() }
                        else { showRoutingRules = true }
                    }
                        .buttonStyle(.bordered)
                        .disabled(!controller.isInstalled || controller.state.selectedNodeID == nil)
                }
                .controlSize(.large)

                HStack(spacing: 8) {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(controller.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Text("v\(VPNController.releaseVersion)").font(.caption2).foregroundStyle(.tertiary)
                }

                HStack {
                    Button("Settings & Diagnostics…") { showSettings = true }
                    Spacer()
                    Button("Uninstall…", role: .destructive) { confirmRemoval = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(controller.isBusy)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 700)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showRoutingRules) {
            RoutingRulesView(controller: controller)
        }
        .sheet(isPresented: $showNodeSelection) {
            NodeSelectionView(controller: controller)
        }
        .sheet(isPresented: Binding(get: { controller.showConnection && !showSettings }, set: { controller.showConnection = $0 })) { ConnectionView(controller: controller) }
        .sheet(isPresented: $showSettings) { SettingsView(controller: controller) }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.refreshWhenActive()
            }
        }
        .confirmationDialog("Uninstall matveevVpn?", isPresented: $confirmRemoval) {
            Button("Uninstall and Move to Trash", role: .destructive) { controller.runUninstall() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The system service will be removed. Your settings will be kept for reinstalling.")
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(controller.isRunning ? .green : .gray).frame(width: 8, height: 8)
            Text(controller.isRunning ? "On" : "Off").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(.white.opacity(0.07), in: Capsule())
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
            MenuContent(controller: controller, speedMonitor: speedMonitor)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: VPNController
    @ObservedObject var speedMonitor: SpeedMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
            Text(controller.isRunning ? "Connected" : "Disconnected")
            Text(controller.node)
            Text("↓ \(Int(speedMonitor.downloadSpeed / 1024)) KB/s · ↑ \(Int(speedMonitor.uploadSpeed / 1024)) KB/s")
            Button(controller.isRunning ? "Turn Off" : "Turn On") { controller.run(controller.isRunning ? "off" : "on") }
                .disabled(controller.isBusy || !controller.isInstalled || controller.state.selectedNodeID == nil)
            Button("Open matveevVpn") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
    }
}

import SwiftUI
import AppKit
import Charts
import Darwin

private struct CommandResult {
    let status: Int32
    let output: String
}

struct RoutingRules: Codable {
    var domains: [String]
    var applications: [String]
}

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

@MainActor
final class VPNController: ObservableObject {
    static let releaseVersion = "1.0.0"

    @Published var isBusy = false
    @Published var isInstalled = false
    @Published var isRunning = false
    @Published var needsUpgrade = false
    @Published var node = "—"
    @Published var directIP = "—"
    @Published var serviceIP = "—"
    @Published var message = "Checking status…"
    @Published var rulesMessage = ""

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private var commandPath: String { "\(home)/VPN/.service/vpn-control.sh" }
    private var versionPath: String { "\(home)/VPN/.service/package-version.txt" }
    private var rulesPath: String { "\(home)/VPN/routing-rules.json" }

    init() {
        refresh()
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            isInstalled = FileManager.default.fileExists(atPath: commandPath)
            let installedVersion = (try? String(contentsOfFile: versionPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            needsUpgrade = isInstalled && installedVersion != Self.releaseVersion

            guard isInstalled else {
                isRunning = false
                message = "Initial setup is required"
                isBusy = false
                return
            }

            let result = await Self.execute("/bin/bash", [commandPath, "status"])
            applyStatus(result.output)
            if result.status != 0 {
                message = result.output.isEmpty ? "Could not read VPN status" : result.output
            } else if needsUpgrade {
                message = "Configuration update 1.0.0 is available"
            } else {
                message = isRunning ? "Selected traffic is routed through the VPN" : "VPN is currently off"
            }
            isBusy = false
        }
    }

    func run(_ action: String) {
        guard !isBusy else { return }
        isBusy = true
        message = "Running…"
        Task {
            let result = await Self.execute("/bin/bash", [commandPath, action])
            message = result.output.isEmpty
                ? (result.status == 0 ? "Done" : "The operation failed")
                : result.output
            isBusy = false
            refresh()
        }
    }

    func openSetup() {
        guard let setup = Bundle.main.path(forResource: "setup", ofType: "command") else {
            message = "Setup file was not found"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: setup))
        message = "Setup opened"
    }

    func currentRoutingRules() -> RoutingRules {
        if let data = FileManager.default.contents(atPath: rulesPath),
           let rules = try? JSONDecoder().decode(RoutingRules.self, from: data) {
            return rules
        }
        return defaultRoutingRules()
    }

    func defaultRoutingRules() -> RoutingRules {
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(".payload/default-rules.json"),
              let data = try? Data(contentsOf: resourceURL),
              let rules = try? JSONDecoder().decode(RoutingRules.self, from: data) else {
            return RoutingRules(domains: [], applications: [])
        }
        return rules
    }

    func applyRoutingRules(domains: [String], applications: [String]) {
        guard !isBusy, isInstalled else {
            rulesMessage = "Complete initial setup first."
            return
        }
        let normalized = RoutingRules(
            domains: normalize(domains, lowercase: true),
            applications: normalize(applications, lowercase: false)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(normalized)
            try data.write(to: URL(fileURLWithPath: rulesPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesPath)
        } catch {
            rulesMessage = "Could not save rules: \(error.localizedDescription)"
            return
        }

        isBusy = true
        rulesMessage = "Validating and applying…"
        Task {
            let result = await Self.execute("/bin/bash", [commandPath, "apply-rules"])
            rulesMessage = result.status == 0
                ? "Rules applied successfully."
                : (result.output.isEmpty ? "Could not apply the rules." : result.output)
            isBusy = false
            refresh()
        }
    }

    private func normalize(_ values: [String], lowercase: Bool) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let result = lowercase ? trimmed.lowercased() : trimmed
            return seen.insert(result).inserted ? result : nil
        }
    }

    func runUninstall() {
        guard !isBusy,
              let script = Bundle.main.path(forResource: "uninstall", ofType: "command") else { return }
        isBusy = true
        message = "Removing the system service…"
        Task {
            let result = await Self.execute("/bin/bash", [script, "--yes"])
            guard result.status == 0 else {
                message = result.output.isEmpty ? "Uninstall failed" : result.output
                isBusy = false
                return
            }

            message = "Moving matveevVpn to Trash…"
            let appURL = Bundle.main.bundleURL
            NSWorkspace.shared.recycle([appURL]) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.message = "The service was removed, but the app could not be moved to Trash: \(error.localizedDescription)"
                        self.isBusy = false
                    } else {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    private func applyStatus(_ text: String) {
        isRunning = text.contains("Service: running") || text.contains("Служба: работает")
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Node:") || line.hasPrefix("Нода:") { node = value(after: ":", in: line) }
            if line.hasPrefix("Direct IP:") || line.hasPrefix("Обычный IP:") { directIP = value(after: ":", in: line) }
            if line.hasPrefix("Routed IP:") || line.hasPrefix("OpenAI IP:") { serviceIP = value(after: ":", in: line) }
        }
    }

    private func value(after separator: Character, in line: String) -> String {
        guard let index = line.firstIndex(of: separator) else { return "—" }
        return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func execute(_ executable: String, _ arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: output))
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                }
            }
        }
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

private struct InfoCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
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
                    .foregroundStyle(.purple)
            }

            Chart(monitor.samples) { point in
                LineMark(
                    x: .value("Second", point.slot),
                    y: .value("Download", point.download)
                )
                .foregroundStyle(.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Second", point.slot),
                    y: .value("Upload", point.upload)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
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
                editor(title: "Domain suffixes", hint: "example.com", text: $domainsText)
                editor(title: "Application process names", hint: "Example App", text: $applicationsText)
            }

            HStack {
                Text(controller.rulesMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Reset to Defaults") { load(controller.defaultRoutingRules()) }
                Button("Save and Apply") {
                    controller.applyRoutingRules(
                        domains: lines(domainsText),
                        applications: lines(applicationsText)
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy)
            }
        }
        .padding(22)
        .frame(width: 720, height: 520)
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
    }
}

private struct MainView: View {
    @StateObject private var controller = VPNController()
    @StateObject private var speedMonitor = SpeedMonitor()
    @State private var confirmRemoval = false
    @State private var showRoutingRules = false

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
                        Text("Selective routing · Your rules").foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge
                }

                if controller.needsUpgrade {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Configuration 1.0.0 needs to be applied")
                        Spacer()
                        Button("Update") { controller.openSetup() }
                    }
                    .padding(11)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Current node").font(.caption).foregroundStyle(.secondary)
                    Text(controller.node).font(.headline).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 10) {
                    InfoCard(title: "Direct IP", value: controller.directIP)
                    InfoCard(title: "Routed IP", value: controller.serviceIP)
                }

                SpeedChartCard(monitor: speedMonitor)

                HStack(spacing: 10) {
                    if !controller.isInstalled {
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
                    Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .help("Refresh status")
                    Spacer()
                    Button("Routing rules…") {
                        if controller.needsUpgrade { controller.openSetup() }
                        else { showRoutingRules = true }
                    }
                        .buttonStyle(.bordered)
                        .disabled(!controller.isInstalled)
                }
                .controlSize(.large)

                HStack(spacing: 8) {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(controller.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Text("v\(VPNController.releaseVersion)").font(.caption2).foregroundStyle(.tertiary)
                }

                HStack {
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
        .confirmationDialog("Uninstall matveevVpn?", isPresented: $confirmRemoval) {
            Button("Uninstall and Move to Trash", role: .destructive) { controller.runUninstall() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The system service and bundled sing-box will be removed. Your ~/VPN folder will be kept as a backup.")
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
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

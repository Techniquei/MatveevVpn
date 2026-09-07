import SwiftUI
import AppKit
import ServiceManagement
import Network
import UserNotifications

@MainActor
final class VPNController: ObservableObject {
    static let releaseVersion = "1.1.1"
    @Published var isBusy = false
    @Published var isInstalled = false
    @Published var isRunning = false
    @Published var needsUpgrade = false
    @Published var node = "—"
    @Published var message = "Checking status…"
    @Published var rulesMessage = ""
    @Published var nodeMessage = ""
    @Published var availableNodes: [VPNNode] = []
    @Published var currentNodeIndex: String?
    @Published var state = SavedState()
    @Published var showConnection = false
    @Published var diagnostics = ""
    @Published var candidateURL = ""
    @Published var candidateNodes: [VPNNode] = []
    @Published var candidateID: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var probeResults: [String: String] = [:]
    @Published var testingNodes = false
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "failureNotifications")
    private var candidateSubscription = ""
    private var loadedURL = ""
    private let store = StateStore()
    private let service = SystemService()
    private let coordinator = ConfigurationCoordinator()
    private var timer: Timer?
    private var loadFailed = false
    private var previouslyRunning: Bool?
    private var connectionCheck: Task<Void, Never>?
    private var nodeTest: Task<Void, Never>?

    init() {
        _ = AppUpdater.shared
        do { state = try store.load() }
        catch { message = "Could not load settings: \(error.localizedDescription)"; loadFailed = true }
        refresh()
        reconcileInstalledConfiguration()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.refresh() }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        isInstalled = service.installed
        isRunning = service.running
        if previouslyRunning == true && !isRunning && state.desiredOn && notificationsEnabled {
            notify("VPN connection interrupted", "Open matveevVpn to check the service.")
        }
        previouslyRunning = isRunning
        needsUpgrade = isInstalled && service.currentVersion != SystemService.version
        availableNodes = (try? Subscription.nodes(state.subscription)) ?? []
        currentNodeIndex = state.selectedNodeID
        node = availableNodes.first { $0.id == state.selectedNodeID }?.name ?? "Not selected"
        if message == "Checking status…" {
            message = isInstalled ? "Ready" : "Add a subscription to get started."
        }
    }
    func refreshWhenActive() { refresh() }
    func openSetup() { prepareConnection(); showConnection = true }
    func currentRoutingRules() -> RoutingRules { state.rules }
    func loadAvailableNodes() { refresh() }

    private func perform(allowRecovery: Bool = false, _ operation: @escaping () async throws -> Void) {
        guard !isBusy, !loadFailed || allowRecovery else { return }
        isBusy = true
        message = "Applying changes…"
        Task {
            do { try await operation(); message = "Done" }
            catch {
                if let recovered = try? store.load() { state = recovered }
                message = error.localizedDescription; rulesMessage = message; nodeMessage = message
            }
            isBusy = false
            refresh()
        }
    }

    private func commit(_ next: SavedState) async throws {
        state = try await coordinator.apply(next, previous: state)
        checkConnection()
    }

    private func reconcileInstalledConfiguration() {
        guard !loadFailed, service.installed, service.currentVersion == SystemService.version,
              state.selectedNodeID != nil, !state.subscription.isEmpty else { return }
        let snapshot = state
        Task {
            do {
                let stage = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: stage) }
                let config = try await self.service.generate(snapshot, at: stage)
                guard !self.service.configurationMatches(config), !self.isBusy else { return }
                self.isBusy = true
                self.message = "Updating the installed configuration…"
                defer { self.isBusy = false; self.refresh() }
                try await self.service.deploy(config)
                self.message = "Configuration updated."
                self.checkConnection()
            } catch {
                self.message = "Could not update the installed configuration: \(error.localizedDescription)"
            }
        }
    }

    func run(_ action: String) {
        perform {
            let wasRunning = self.service.running
            try await self.service.send(action)
            var next = self.state
            next.desiredOn = action != "off"
            do { try self.store.save(next) }
            catch { try? await self.service.send(wasRunning ? "on" : "off"); throw error }
            self.state = next
            self.checkConnection()
        }
    }
    func changeMode(_ mode: RoutingMode) {
        var next = state; next.rules.mode = mode
        perform { try await self.commit(next) }
    }
    func applyRoutingRules(domains: [String], applications: [String], paths: [String]) {
        var next = state
        func clean(_ lines: [String]) -> [String] {
            var seen = Set<String>()
            return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
        }
        next.rules.domains = clean(domains).map { $0.lowercased() }
        next.rules.applications = clean(applications)
        next.rules.processPathRegexes = clean(paths)
        perform { try await self.commit(next); self.rulesMessage = "Rules applied." }
    }
    func selectNode(_ id: String) {
        var next = state; next.selectedNodeID = id
        perform { try await self.commit(next); self.nodeMessage = "Node changed." }
    }
    func prepareConnection() {
        candidateURL = state.subscriptionURL
        loadedURL = state.subscriptionURL
        candidateSubscription = state.subscription
        candidateNodes = availableNodes
        candidateID = state.selectedNodeID
    }
    func fetchSubscription() {
        let input = candidateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            guard let url = URL(string: input), url.scheme == "https", url.host != nil else {
                throw VPNError.message("Enter an HTTPS subscription URL.")
            }
            let data = try await SubscriptionFetcher.fetch(url)
            let decoded = try Subscription.decode(data)
            let nodes = try Subscription.nodes(decoded)
            let old = self.availableNodes.first { $0.id == self.state.selectedNodeID }
            let fallback = nodes.filter { $0.name == old?.name && $0.host == old?.host && $0.port == old?.port }
            let matched = nodes.first { $0.id == old?.id } ?? (fallback.count == 1 ? fallback.first : nil)
            self.candidateSubscription = decoded
            self.candidateNodes = nodes
            self.candidateID = matched?.id ?? (old == nil ? nodes.first?.id : nil)
            self.candidateURL = input
            self.loadedURL = input
            self.nodeMessage = self.candidateID == nil ? "Your previous node is missing. Choose a replacement." : "Subscription loaded. Choose a node and apply."
        }
    }
    func applySubscription() {
        guard candidateURL.trimmingCharacters(in: .whitespacesAndNewlines) == loadedURL else {
            message = "Load the edited URL before applying it."
            return
        }
        var next = state
        next.subscriptionURL = candidateURL
        next.subscription = candidateSubscription
        next.selectedNodeID = candidateID
        next.lastRefresh = Date()
        if !isInstalled || state.selectedNodeID == nil { next.desiredOn = true }
        perform { try await self.commit(next); self.showConnection = false }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { message = "Could not change launch at login: \(error.localizedDescription)" }
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { notificationsEnabled = false; UserDefaults.standard.set(false, forKey: "failureNotifications"); return }
        Task {
            let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "failureNotifications")
        }
    }
    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vpn-failure", content: content, trigger: nil))
    }
    func testNodes() {
        guard !testingNodes else { return }
        testingNodes = true
        nodeMessage = "Testing TCP reachability…"
        nodeTest = Task {
            self.probeResults = [:]
            let nodes = self.availableNodes
            await withTaskGroup(of: (String, String).self) { group in
                var iterator = nodes.makeIterator()
                for _ in 0..<4 {
                    if let node = iterator.next() { group.addTask { (node.id, await NodeProbe.measure(node)) } }
                }
                for await (id, result) in group {
                    self.probeResults[id] = result
                    if Task.isCancelled { group.cancelAll() }
                    else if let node = iterator.next() { group.addTask { (node.id, await NodeProbe.measure(node)) } }
                }
            }
            self.nodeMessage = Task.isCancelled ? "Node test cancelled." : "TCP reachability checked using the current connection. This is not a throughput test."
            self.testingNodes = false
        }
    }
    func cancelNodeTests() { nodeTest?.cancel() }
    func checkConnection() {
        connectionCheck?.cancel()
        let snapshot = state
        diagnostics = "Checking connection…"
        connectionCheck = Task {
            async let ipv4 = Self.publicIP("-4", endpoint: "https://api4.ipify.org")
            async let ipv6 = Self.publicIP("-6", endpoint: "https://api6.ipify.org")
            let (v4, v6) = await (ipv4, ipv6)
            guard !Task.isCancelled else { return }
            self.diagnostics = "Checked: \(Date().formatted())\nApp: \(Self.releaseVersion)\nController: \(self.service.currentVersion)\nSettings schema: \(snapshot.schemaVersion)\nMode: \(snapshot.rules.mode.rawValue)\nTunnel: \(self.service.running ? "running" : "stopped")\nVPN egress IPv4: \(v4)\nVPN egress IPv6: \(v6)\nDomain rules: \(snapshot.rules.domains.count)\nApplication rules: \(snapshot.rules.applications.count + snapshot.rules.processPathRegexes.count)\nThe diagnostic endpoints are always routed through the selected VPN node. IPv6 may be unavailable on some nodes."
        }
    }
    private nonisolated static func publicIP(_ family: String, endpoint: String) async -> String {
        let result = await Command.run("/usr/bin/curl", [family, "-fsS", "--connect-timeout", "5", "--max-time", "12", "--max-filesize", "4096", endpoint])
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        return result.status == 0 && !value.isEmpty && value.count < 64 && value.unicodeScalars.allSatisfy { allowed.contains($0) } ? value : "unavailable"
    }
    func copyDiagnostics() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics, forType: .string) }
    func repair() {
        perform {
            let stage = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: stage) }
            let config = try await self.service.generate(self.state, at: stage)
            try await self.service.install(config, desiredOn: self.state.desiredOn)
        }
    }
    func exportRules() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "matveevVpn-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try privateWrite(JSONEncoder().encode(state.rules), to: url) }
        catch { message = "Could not export routing rules." }
    }
    func importRules() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rules = try JSONDecoder().decode(RoutingRules.self, from: Data(contentsOf: url))
            var next = state; next.rules = rules
            perform { try await self.commit(next) }
        } catch { message = "The file is not a valid routing configuration." }
    }
    func resetSettings() {
        perform(allowRecovery: true) {
            if self.service.installed { try await self.service.send("reset") }
            let next = SavedState(); try self.store.save(next); self.state = next
            self.loadFailed = false
            try self.store.finishTransaction()
            self.setLogin(false)
            self.setNotifications(false)
            self.prepareConnection(); self.showConnection = true
        }
    }
    func runUninstall() {
        perform {
            let script = self.service.payload.appendingPathComponent("uninstall-service.sh")
            let result = await Command.run("/bin/bash", [script.path, "--yes"])
            guard result.status == 0 else { throw VPNError.message("Uninstall was cancelled or failed.") }
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                if error == nil { DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
            }
        }
    }
}

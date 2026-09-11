import SwiftUI
import AppKit
import ServiceManagement
import Network
import UserNotifications

@MainActor
final class VPNController: ObservableObject {
    static let releaseVersion = "1.2.1"
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
    @Published var failureReport = ""
    @Published var candidateURL = ""
    @Published var candidateNodes: [VPNNode] = []
    @Published var candidateID: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var probeResults: [String: NodeProbeResult] = [:]
    @Published var testingNodes = false
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "failureNotifications")
    @Published var autoFailoverEnabled = true
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
    private var healthCheck: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var lastHealthCheck = Date.distantPast
    private var consecutiveHealthFailures = 0

    private static let healthCheckInterval: TimeInterval = 15
    private static let healthFailureThreshold = 3
    private static let currentNodeRestartAttempts = 2
    private static let maximumNodeSwitchesPerWindow = 3
    private static let failoverWindow: TimeInterval = 10 * 60

    init() {
        _ = AppUpdater.shared
        UserDefaults.standard.register(defaults: ["automaticFailover": true])
        autoFailoverEnabled = UserDefaults.standard.bool(forKey: "automaticFailover")
        do { state = try store.load() }
        catch {
            message = "Could not load settings: \(error.localizedDescription)"
            AppLogger.shared.write("settings load failed: \(error.localizedDescription)")
            loadFailed = true
        }
        syncNotificationPreference()
        refresh()
        testNodes(automatic: true)
        reconcileInstalledConfiguration()
        AppLogger.shared.write("app started; automatic failover \(autoFailoverEnabled ? "enabled" : "disabled")")
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.refresh() }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        isInstalled = service.installed
        isRunning = service.running
        let wasRunning = previouslyRunning
        if wasRunning == true && !isRunning && state.desiredOn {
            AppLogger.shared.write("VPN runtime stopped unexpectedly")
            message = autoFailoverEnabled ? "Connection interrupted. Starting safe recovery…" : "VPN connection interrupted."
            if notificationsEnabled {
                notify("VPN connection interrupted", autoFailoverEnabled ? "Trying to restore the connection safely." : "Open matveevVpn to check the service.")
            }
        }
        previouslyRunning = isRunning
        needsUpgrade = isInstalled && service.currentVersion != SystemService.version
        availableNodes = (try? Subscription.nodes(state.subscription)) ?? []
        currentNodeIndex = state.selectedNodeID
        node = availableNodes.first { $0.id == state.selectedNodeID }?.name ?? "Not selected"
        if message == "Checking status…" {
            message = isInstalled && state.selectedNodeID != nil ? "" : "Add a subscription to get started."
        }
        if !isRunning && state.desiredOn && isInstalled && !needsUpgrade && (wasRunning == true || wasRunning == nil) {
            beginAutomaticRecovery(reason: "the VPN runtime stopped")
        } else if isRunning {
            scheduleHealthCheckIfNeeded()
        }
    }
    func refreshWhenActive() { refresh() }
    func openSetup() { prepareConnection(); showConnection = true }
    func currentRoutingRules() -> RoutingRules { state.rules }
    func loadAvailableNodes() { refresh() }

    private func perform(_ operationName: String = "Apply changes", allowRecovery: Bool = false, _ operation: @escaping () async throws -> Void) {
        guard !isBusy, !loadFailed || allowRecovery else { return }
        isBusy = true
        failureReport = ""
        message = "Applying changes…"
        AppLogger.shared.write("operation started: \(operationName)")
        Task {
            do {
                try await operation()
                message = ""
                AppLogger.shared.write("operation completed: \(operationName)")
            }
            catch {
                if let recovered = try? store.load() { state = recovered }
                message = error.localizedDescription; rulesMessage = message; nodeMessage = message
                failureReport = error.localizedDescription
                let context = await connectionContext()
                AppLogger.shared.write(makeLogReport(operation: operationName, error: error) + "\n" + context)
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
        perform(action == "off" ? "Disconnect VPN" : "Connect VPN") {
            let wasRunning = self.service.running
            try await self.service.send(action)
            var next = self.state
            next.desiredOn = action != "off"
            do { try self.store.save(next) }
            catch { try? await self.service.send(wasRunning ? "on" : "off"); throw error }
            self.state = next
            if action == "off" { self.consecutiveHealthFailures = 0 }
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
        perform("Switch node") {
            try await self.commit(next)
            let result = await self.probeNode(id)
            self.nodeMessage = "Node changed — \(result.displayText)."
        }
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
        perform("Load subscription") {
            let data: Data
            if input.hasPrefix("vless://") {
                data = Data(input.utf8)
            } else {
                guard let url = URL(string: input), url.scheme == "https", url.host != nil else {
                    throw VPNError.message("Enter an HTTPS subscription URL or a VLESS link.")
                }
                data = try await SubscriptionFetcher.fetch(url)
            }
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
        perform {
            try await self.commit(next)
            if let id = next.selectedNodeID { _ = await self.probeNode(id) }
            self.showConnection = false
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { message = "Could not change launch at login: \(error.localizedDescription)" }
    }
    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "failureNotifications")
        guard enabled else { return }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            let allowed: Bool
            if status == .authorized || status == .provisional {
                allowed = true
            } else if status == .notDetermined {
                allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            } else {
                allowed = false
            }
            guard UserDefaults.standard.bool(forKey: "failureNotifications") else { return }
            notificationsEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "failureNotifications")
            if !allowed {
                message = "Notifications are disabled for matveevVpn in System Settings."
            }
        }
    }

    func setAutoFailover(_ enabled: Bool) {
        autoFailoverEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticFailover")
        consecutiveHealthFailures = 0
        AppLogger.shared.write("automatic failover \(enabled ? "enabled" : "disabled")")
    }

    private func syncNotificationPreference() {
        guard notificationsEnabled else { return }
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard UserDefaults.standard.bool(forKey: "failureNotifications") else { return }
            let allowed = status == .authorized || status == .provisional || status == .notDetermined
            notificationsEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "failureNotifications")
        }
    }
    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vpn-failure", content: content, trigger: nil))
    }
    func testNodes(automatic: Bool = false) {
        startNodeTest(availableNodes, automatic: automatic)
    }

    func testCandidateNodes() {
        startNodeTest(candidateNodes, automatic: true)
    }

    private func startNodeTest(_ nodes: [VPNNode], automatic: Bool) {
        guard !testingNodes else { return }
        guard !nodes.isEmpty else { return }
        testingNodes = true
        nodeMessage = automatic ? "Checking direct node latency…" : "Measuring direct node latency…"
        AppLogger.shared.write("node latency check started; count=\(nodes.count)")
        nodeTest = Task {
            for node in nodes { self.probeResults.removeValue(forKey: node.id) }
            await withTaskGroup(of: (String, NodeProbeResult).self) { group in
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
            let reachable = self.probeResults.values.filter(\.isReachable).count
            self.nodeMessage = Task.isCancelled ? "Node test cancelled." : "Direct node latency checked: \(reachable) of \(nodes.count) reachable."
            AppLogger.shared.write("node latency check completed; reachable=\(reachable)/\(nodes.count)")
            self.testingNodes = false
            self.nodeTest = nil
        }
    }
    func cancelNodeTests() { nodeTest?.cancel() }

    @discardableResult
    func probeNode(_ id: String) async -> NodeProbeResult {
        guard let node = (availableNodes + candidateNodes).first(where: { $0.id == id }) else {
            return NodeProbeResult(outcome: .unreachable, latencyMilliseconds: nil, method: nil)
        }
        let result = await NodeProbe.measure(node)
        guard !Task.isCancelled else { return result }
        probeResults[id] = result
        AppLogger.shared.write("node probe \(id.prefix(8)): \(result.displayText)")
        return result
    }

    func probeCandidateNode(_ id: String?) {
        guard let id else { return }
        Task { _ = await probeNode(id) }
    }

    private func scheduleHealthCheckIfNeeded() {
        guard healthCheck == nil, recoveryTask == nil, state.desiredOn, isInstalled, isRunning,
              Date().timeIntervalSince(lastHealthCheck) >= Self.healthCheckInterval else { return }
        lastHealthCheck = Date()
        healthCheck = Task {
            let healthy = await Self.tunnelDNSReachable()
            guard !Task.isCancelled else { return }
            self.healthCheck = nil
            guard self.state.desiredOn, self.service.running else { return }
            if healthy {
                if self.consecutiveHealthFailures > 0 {
                    AppLogger.shared.write("tunnel health restored after \(self.consecutiveHealthFailures) failed checks")
                }
                self.consecutiveHealthFailures = 0
            } else {
                self.consecutiveHealthFailures += 1
                AppLogger.shared.write("tunnel health check failed; consecutive=\(self.consecutiveHealthFailures)")
                if self.consecutiveHealthFailures >= Self.healthFailureThreshold {
                    self.beginAutomaticRecovery(reason: "three tunnel health checks failed")
                }
            }
        }
    }

    private func beginAutomaticRecovery(reason: String) {
        guard autoFailoverEnabled, recoveryTask == nil, !isBusy, state.desiredOn,
              isInstalled, !needsUpgrade, state.selectedNodeID != nil else { return }
        healthCheck?.cancel()
        healthCheck = nil
        recoveryTask = Task {
            self.isBusy = true
            self.message = "Connection problem detected. Trying to recover…"
            AppLogger.shared.write("automatic recovery started: \(reason)")
            do {
                try await self.recoverConnection()
                self.failureReport = ""
            } catch {
                await self.disableAfterRecoveryFailure(error)
            }
            self.consecutiveHealthFailures = 0
            self.lastHealthCheck = Date()
            self.isBusy = false
            self.recoveryTask = nil
            self.refresh()
        }
    }

    private func recoverConnection() async throws {
        for attempt in 1...Self.currentNodeRestartAttempts {
            try Task.checkCancellation()
            AppLogger.shared.write("automatic recovery: restart current node attempt \(attempt)/\(Self.currentNodeRestartAttempts)")
            do { try await service.send("restart") }
            catch {
                AppLogger.shared.write("automatic restart \(attempt) was rejected: \(error.localizedDescription)\nDetails:\n\(rawErrorDetails(error))")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let tunnelHealthy = await Self.tunnelDNSReachable()
            if service.running && tunnelHealthy {
                message = "Connection restored on the current node."
                AppLogger.shared.write("automatic recovery succeeded on the current node")
                return
            }
        }

        let currentID = state.selectedNodeID
        let alternatives = availableNodes.filter { $0.id != currentID }.sorted { lhs, rhs in
            let left = probeResults[lhs.id]
            let right = probeResults[rhs.id]
            if left?.isReachable != right?.isReachable { return left?.isReachable == true }
            return (left?.latencyMilliseconds ?? Int.max) < (right?.latencyMilliseconds ?? Int.max)
        }

        var checked = 0
        for candidate in alternatives {
            guard checked < Self.maximumNodeSwitchesPerWindow else { break }
            checked += 1
            try Task.checkCancellation()

            let probe = await NodeProbe.measure(candidate, timeout: 3)
            probeResults[candidate.id] = probe
            AppLogger.shared.write("failover candidate \(candidate.id.prefix(8)) probe: \(probe.displayText)")
            guard probe.isReachable else { continue }
            guard consumeNodeSwitchBudget() else {
                throw VPNError.message("Automatic failover stopped: the limit of three node switches in 10 minutes was reached.")
            }

            var next = state
            next.selectedNodeID = candidate.id
            next.desiredOn = true
            AppLogger.shared.write("automatic failover switching to node \(candidate.id.prefix(8))")
            do {
                state = try await coordinator.apply(next, previous: state)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let tunnelHealthy = await Self.tunnelDNSReachable()
                if service.running && tunnelHealthy {
                    node = candidate.name
                    currentNodeIndex = candidate.id
                    message = "Automatically switched to \(candidate.name)."
                    AppLogger.shared.write("automatic failover succeeded on node \(candidate.id.prefix(8))")
                    if notificationsEnabled { notify("VPN node changed", "Connected to \(candidate.name).") }
                    return
                }
            } catch {
                AppLogger.shared.write("automatic failover node \(candidate.id.prefix(8)) failed: \(error.localizedDescription)")
            }
        }

        throw VPNError.message("Automatic recovery failed after two restarts and \(checked) alternate-node attempts.")
    }

    private func consumeNodeSwitchBudget() -> Bool {
        let key = "automaticFailoverSwitchTimestamps"
        let now = Date().timeIntervalSince1970
        var timestamps = (UserDefaults.standard.array(forKey: key) as? [Double] ?? [])
            .filter { now - $0 < Self.failoverWindow }
        guard timestamps.count < Self.maximumNodeSwitchesPerWindow else {
            UserDefaults.standard.set(timestamps, forKey: key)
            return false
        }
        timestamps.append(now)
        UserDefaults.standard.set(timestamps, forKey: key)
        return true
    }

    private func disableAfterRecoveryFailure(_ error: Error) async {
        try? await service.send("off")
        var next = state
        next.desiredOn = false
        do {
            try store.save(next)
            state = next
        } catch {
            AppLogger.shared.write("failed to save disabled state after recovery failure")
        }
        let recoveryError = VPNError.message("VPN was turned off to prevent uncontrolled switching. \(error.localizedDescription)")
        message = recoveryError.localizedDescription
        nodeMessage = message
        failureReport = recoveryError.localizedDescription
        let context = await connectionContext()
        AppLogger.shared.write(makeLogReport(operation: "Automatic connection recovery", error: recoveryError) + "\n" + context)
        if notificationsEnabled { notify("VPN turned off", "Automatic recovery reached its safety limit.") }
    }

    func checkConnection() {
        connectionCheck?.cancel()
        let snapshot = state
        diagnostics = "Checking connection…"
        connectionCheck = Task {
            async let directIPv4 = Self.publicIP(endpoint: "https://api64.ipify.org")
            async let vpnIPv4 = Self.publicIP(endpoint: "https://api4.ipify.org")
            async let resolver = Self.systemDNS()
            async let tunnelResolver = Self.tunnelDNS()
            let (direct, vpn, dns, tunnelDNS) = await (directIPv4, vpnIPv4, resolver, tunnelResolver)
            guard !Task.isCancelled else { return }
            let path = direct != "unavailable" && vpn != "unavailable" ? (direct == vpn ? "same" : "different") : "unavailable"
            self.diagnostics = "Checked: \(Date().formatted())\nApp: \(Self.releaseVersion)\nController: \(self.service.currentVersion)\nSettings schema: \(snapshot.schemaVersion)\nMode: \(snapshot.rules.mode.rawValue)\nTunnel: \(self.service.running ? "running" : "stopped")\nSystem DNS: \(dns)\nTunnel DNS: \(tunnelDNS)\nDirect IPv4: \(direct)\nVPN IPv4: \(vpn)\nVPN path: \(path)\nIPv6: disabled for compatibility\nDomain rules: \(snapshot.rules.domains.count)\nApplication rules: \(snapshot.rules.applications.count + snapshot.rules.processPathRegexes.count)\nWhile connected, Tunnel DNS should be reachable. The two IPv4 probes are explicitly routed through different outbounds and should normally report different addresses."
        }
    }
    private nonisolated static func publicIP(endpoint: String) async -> String {
        let result = await Command.run("/usr/bin/curl", ["-4", "-fsS", "--connect-timeout", "5", "--max-time", "12", "--max-filesize", "4096", endpoint])
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        return result.status == 0 && !value.isEmpty && value.count < 64 && value.unicodeScalars.allSatisfy { allowed.contains($0) } ? value : "unavailable"
    }
    private nonisolated static func systemDNS() async -> String {
        let result = await Command.run("/usr/sbin/scutil", ["--dns"])
        guard result.status == 0 else { return "unavailable" }
        var servers: [String] = []
        for line in result.output.split(separator: "\n") where line.contains("nameserver[") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty && !servers.contains(value) { servers.append(value) }
            if servers.count == 4 { break }
        }
        return servers.isEmpty ? "unavailable" : servers.joined(separator: ", ")
    }
    private nonisolated static func tunnelDNS() async -> String {
        let result = await Command.run("/usr/bin/dig", ["+time=3", "+tries=1", "+short", "@198.18.0.2", "api4.ipify.org", "A"])
        let addresses = result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return result.status == 0 && !addresses.isEmpty ? "reachable" : "unavailable"
    }
    private nonisolated static func tunnelDNSReachable() async -> Bool {
        await tunnelDNS() == "reachable"
    }
    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "matveevVpn.log"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: AppLogger.shared.file)
            try data.write(to: destination, options: .atomic)
            message = "Application log exported."
            AppLogger.shared.write("application log exported")
        } catch {
            message = "Could not export the application log: \(error.localizedDescription)"
        }
    }

    private func makeLogReport(operation: String, error: Error) -> String {
        return "operation failed\nApp: \(Self.releaseVersion)\nOperation: \(operation)\nError: \(error.localizedDescription)\nController: \(service.currentVersion)\nRuntime status: \(service.runtimeStatus)\nTunnel: \(service.running ? "running" : "stopped")\nDetails:\n\(rawErrorDetails(error))"
    }

    private func rawErrorDetails(_ error: Error) -> String {
        (error as? VPNError)?.diagnosticDetails ?? "No additional error details were provided."
    }

    private func connectionContext() async -> String {
        async let networkInformation = Command.run("/usr/sbin/scutil", ["--nwi"])
        async let hardwarePorts = Command.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        async let defaultRoute = Command.run("/sbin/route", ["-n", "get", "default"])
        let (network, hardware, route) = await (networkInformation, hardwarePorts, defaultRoute)
        let wifiDevice = Self.wifiDevice(from: hardware.output)
        let wifiPower: String
        if let wifiDevice {
            wifiPower = (await Command.run("/usr/sbin/networksetup", ["-getairportpower", wifiDevice])).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            wifiPower = "Wi-Fi device not found"
        }
        let connectivity = Self.hasPhysicalNetwork(in: network.output) ? "physical interface available" : "offline or no physical interface"
        return """
        Connection context:
        Connectivity: \(connectivity)
        Wi-Fi: \(wifiPower)
        Routing mode: \(state.rules.mode.rawValue)
        Desired VPN state: \(state.desiredOn ? "on" : "off")
        \(selectedNodeContext())
        scutil --nwi:
        \(network.output.trimmingCharacters(in: .whitespacesAndNewlines))
        Default route:
        \(route.output.trimmingCharacters(in: .whitespacesAndNewlines))
        Hardware ports:
        \(hardware.output.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private func selectedNodeContext() -> String {
        guard let id = state.selectedNodeID,
              let node = availableNodes.first(where: { $0.id == id }) else { return "Selected node: unavailable" }
        let lines = state.subscription.split(whereSeparator: \.isNewline)
        guard node.index > 0, node.index <= lines.count else { return "Selected node: \(node.name)" }
        let raw = String(lines[node.index - 1])
        let components = URLComponents(string: raw)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let transportValue = query["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "raw"
        let transport = transportValue == "splithttp" ? "xhttp" : transportValue
        let security = query["security"].flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        let core = security == "reality" || transport == "xhttp" ? "Xray" : "sing-box"
        return """
        Selected node: \(node.name)
        Endpoint: \(node.host):\(node.port)
        Protocol: VLESS
        Transport: \(transport)
        Security: \(security)
        Flow: \(query["flow"] ?? "none")
        Runtime core: \(core)
        VLESS URI: \(raw)
        """
    }

    private nonisolated static func wifiDevice(from output: String) -> String? {
        var wifiPort = false
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces).lowercased()
                wifiPort = name.contains("wi-fi") || name.contains("airport")
            } else if wifiPort, line.hasPrefix("Device:") {
                return line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private nonisolated static func hasPhysicalNetwork(in output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 3, fields[1] == ":", fields[2] == "flags" else { return false }
            return !fields[0].hasPrefix("utun") && fields[0] != "lo0"
        }
    }
    func repair() {
        perform {
            let stage = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: stage) }
            let config = try await self.service.generate(self.state, at: stage)
            try await self.service.install(config, desiredOn: self.state.desiredOn)
            self.checkConnection()
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
            let next = try self.store.freshState(); try self.store.save(next); self.state = next
            self.loadFailed = false
            try self.store.finishTransaction()
            UserDefaults.standard.removeObject(forKey: "automaticFailoverSwitchTimestamps")
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

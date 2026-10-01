import SwiftUI
import AppKit
import ServiceManagement
import Network
import UserNotifications
import CryptoKit

@MainActor
final class VPNController: ObservableObject {
    static let releaseVersion = "1.4.0-beta.3"
    @Published var isBusy = false
    @Published private(set) var isRecovering = false
    @Published private(set) var isStoppingRecovery = false
    @Published var isInstalled = false
    @Published var isRunning = false
    @Published var needsUpgrade = false
    @Published var message = "Checking status…"
    @Published var rulesMessage = ""
    @Published private(set) var automaticRoutingLastUpdate: Date?
    @Published var availableNodes: [VPNNode] = []
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
    @Published var happCompatibilityEnabled = false
    private var candidateSubscription = ""
    private var loadedURL = ""
    private let store: StateStore
    private let service = SystemService()
    private let coordinator: ConfigurationCoordinator
    private let adBlockRuleStore = AdBlockRuleStore()
    private var timer: Timer?
    private var loadFailed = false
    private var previouslyRunning: Bool?
    private var connectionCheck: Task<Void, Never>?
    private var nodeProbe: Task<Void, Never>?
    private var healthCheck: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var adBlockRefresh: Task<Void, Never>?
    private var adBlockRulesNeedApply = false
    private var recoverySuppressedUntil = Date.distantPast
    private var nextRecoveryAttempt = Date.distantPast
    private var recoveryFailureNotified = false
    private var lastHealthCheck = Date.distantPast
    private var consecutiveHealthFailures = 0

    private static let healthCheckInterval: TimeInterval = 15
    private static let healthFailureThreshold = 3
    private static let currentNodeRestartAttempts = 2
    private static let maximumNodeSwitchesPerWindow = 3
    private static let failoverWindow: TimeInterval = 10 * 60
    private static let recoveryRetryInterval: TimeInterval = 30

    init(store: StateStore = StateStore()) {
        self.store = store
        coordinator = ConfigurationCoordinator(store: store)
        _ = AppUpdater.shared
        UserDefaults.standard.register(defaults: ["automaticFailover": true, "happSubscriptionCompatibility": false])
        autoFailoverEnabled = UserDefaults.standard.bool(forKey: "automaticFailover")
        happCompatibilityEnabled = UserDefaults.standard.bool(forKey: "happSubscriptionCompatibility")
        do { state = try store.load() }
        catch {
            message = "Could not load settings: \(error.localizedDescription)"
            AppLogger.shared.write("settings load failed: \(error.localizedDescription)")
            loadFailed = true
        }
        syncNotificationPreference()
        refresh()
        if !loadFailed && state.subscription.isEmpty {
            prepareConnection()
            showConnection = true
        }
        testNodes()
        reconcileInstalledConfiguration()
        AppLogger.shared.write("app \(Self.releaseVersion) started; automatic failover \(autoFailoverEnabled ? "enabled" : "disabled")")
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
        // launchd may not have published its first status yet when the UI opens.
        if wasRunning == nil && !isRunning && state.desiredOn {
            nextRecoveryAttempt = Date().addingTimeInterval(SystemService.operationTimeout)
            message = "Connecting…"
        }
        let recoverySuppressed = Date() < recoverySuppressedUntil
        if wasRunning == true && !isRunning && state.desiredOn && !recoverySuppressed && !service.isConnecting {
            AppLogger.shared.write("VPN runtime stopped unexpectedly")
            message = autoFailoverEnabled ? "Connection interrupted. Starting safe recovery…" : "VPN connection interrupted."
            if notificationsEnabled {
                notify("VPN connection interrupted", autoFailoverEnabled ? "Trying to restore the connection safely." : "Open matveevVpn to check the service.")
            }
        }
        if wasRunning == false && isRunning {
            lastHealthCheck = .distantPast
            if failureReport.isEmpty { message = "" }
        }
        previouslyRunning = isRunning
        needsUpgrade = isInstalled && service.currentVersion != SystemService.version
        availableNodes = (try? Subscription.nodes(state.subscription)) ?? []
        if message == "Checking status…" {
            message = isInstalled && state.selectedNodeID != nil ? "" : "Add a subscription to get started."
        }
        if !recoverySuppressed && !isRunning && state.desiredOn && isInstalled && !needsUpgrade {
            if service.isConnecting {
                message = service.runtimeStatus == "waiting for network" ? "Waiting for network…" : "Connecting…"
            } else {
                beginAutomaticRecovery(reason: "the VPN runtime stopped")
            }
        } else if isRunning && !needsUpgrade {
            scheduleHealthCheckIfNeeded()
            scheduleAdBlockRefreshIfNeeded()
        }
    }
    func openSetup() {
        if !showConnection { prepareConnection() }
        showConnection = true
    }
    var selectedNode: VPNNode? {
        availableNodes.first { $0.id == state.selectedNodeID }
    }
    var unselectedNodes: [VPNNode] {
        availableNodes.filter { $0.id != state.selectedNodeID }
    }
    func loadAutomaticRoutingUpdate() {
        automaticRoutingLastUpdate = service.automaticRoutingLastUpdate
    }

    private func perform(_ operationName: String = "Apply changes", allowRecovery: Bool = false, _ operation: @escaping (Date) async throws -> Void) {
        guard !isBusy, !loadFailed || allowRecovery else { return }
        let deadline = Date().addingTimeInterval(SystemService.operationTimeout)
        isBusy = true
        nextRecoveryAttempt = .distantPast
        recoveryFailureNotified = false
        failureReport = ""
        message = "Applying changes…"
        AppLogger.shared.write("operation started: \(operationName)")
        Task {
            do {
                try await operation(deadline)
                message = ""
                AppLogger.shared.write("operation completed: \(operationName)")
            }
            catch {
                if let recovered = try? store.load() { state = recovered }
                recoverySuppressedUntil = Date().addingTimeInterval(30)
                AppLogger.shared.write("automatic recovery suppressed for 30 seconds after failed operation: \(operationName)")
                message = error.localizedDescription; rulesMessage = message
                failureReport = error.localizedDescription
                let report = makeLogReport(operation: operationName, error: error)
                Task { AppLogger.shared.write(report + "\n" + (await connectionContext())) }
            }
            isBusy = false
            refresh()
        }
    }

    private func commit(_ next: SavedState, until deadline: Date) async throws {
        state = try await coordinator.apply(next, previous: state, until: deadline)
        checkConnection()
    }

    private func reconcileInstalledConfiguration() {
        guard !loadFailed, service.installed, service.currentVersion == SystemService.version,
              state.selectedNodeID != nil, !state.subscription.isEmpty else { return }
        let snapshot = state
        Task {
            do {
                let deadline = Date().addingTimeInterval(SystemService.operationTimeout)
                let stage = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: stage) }
                let config = try await self.service.generate(snapshot, at: stage, until: deadline)
                guard !self.service.configurationMatches(config), !self.isBusy, !self.service.isConnecting else { return }
                self.isBusy = true
                self.message = "Updating the installed configuration…"
                defer { self.isBusy = false; self.refresh() }
                try await self.service.deploy(config, until: deadline)
                self.message = "Configuration updated."
                self.checkConnection()
            } catch {
                self.recoverySuppressedUntil = Date().addingTimeInterval(30)
                AppLogger.shared.write("automatic recovery suppressed for 30 seconds after installed-configuration reconciliation failed")
                self.message = "Could not update the installed configuration: \(error.localizedDescription)"
            }
        }
    }

    func run(_ action: String) {
        perform(action == "off" ? "Disconnect VPN" : "Connect VPN") { deadline in
            let wasRunning = self.service.running
            var next = self.state
            next.desiredOn = action != "off"
            if action != "off" && self.needsUpgrade {
                try await self.commit(next, until: deadline)
                return
            }
            if action != "off" {
                try self.store.save(next)
                self.state = next
            }
            do { try await self.service.send(action, until: deadline) }
            catch {
                if action == "off" { try? await self.service.send(wasRunning ? "on" : "off", until: deadline) }
                throw error
            }
            if action == "off" {
                do { try self.store.save(next) }
                catch { try? await self.service.send(wasRunning ? "on" : "off", until: deadline); throw error }
            }
            self.state = next
            if action == "off" {
                self.consecutiveHealthFailures = 0
                self.nextRecoveryAttempt = .distantPast
                self.recoveryFailureNotified = false
            }
            self.checkConnection()
        }
    }
    func changeMode(_ mode: RoutingMode) {
        var next = state; next.rules.mode = mode
        perform { deadline in try await self.commit(next, until: deadline) }
    }
    func applyRoutingRules(automaticRoutingEnabled: Bool, automaticServices: Set<String>, adBlockingEnabled: Bool, domains: [String], applications: [String], paths: [String]) {
        var next = state
        func clean(_ lines: [String]) -> [String] {
            var seen = Set<String>()
            return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
        }
        next.rules.domains = clean(domains).map { $0.lowercased() }
        next.rules.applications = clean(applications)
        next.rules.processPathRegexes = clean(paths)
        next.rules.automaticRoutingEnabled = automaticRoutingEnabled
        next.rules.automaticServices = AutomaticRoutingCatalog.services.filter(automaticServices.contains)
        next.rules.adBlockingEnabled = adBlockingEnabled
        perform { deadline in try await self.commit(next, until: deadline); self.rulesMessage = "Rules applied." }
    }
    func selectNode(_ id: String) {
        guard state.selectedNodeID != id || !state.desiredOn || !isRunning else { return }
        var next = state
        next.selectedNodeID = id
        next.desiredOn = true
        perform("Connect to server") { deadline in
            try await self.commit(next, until: deadline)
            self.probeCandidateNode(id)
        }
    }
    private func prepareConnection() {
        candidateURL = state.subscriptionURL
        loadedURL = state.subscriptionURL
        candidateSubscription = state.subscription
        candidateNodes = availableNodes
        candidateID = state.selectedNodeID
    }
    var isInitialSetup: Bool { state.subscription.isEmpty }

    func installInitialComponent() {
        guard isInitialSetup, !service.installed else { return }
        var next = state
        next.selectedNodeID = nil
        next.desiredOn = false
        perform("Install system component") { deadline in
            self.message = "Waiting for administrator approval and installing the system component…"
            self.state = try await self.coordinator.apply(next, previous: self.state, until: deadline)
        }
    }

    var canApplySubscription: Bool {
        let input = candidateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !input.isEmpty && (input != loadedURL || candidateID != nil)
    }

    func fetchSubscription() {
        let input = candidateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let useHappCompatibility = happCompatibilityEnabled
        perform("Load subscription") { _ in
            try await self.loadCandidateSubscription(input, useHappCompatibility: useHappCompatibility)
        }
    }

    private func loadCandidateSubscription(_ input: String, useHappCompatibility: Bool) async throws {
        message = "Loading subscription…"
        let data: Data
        if input.hasPrefix("vless://") {
            data = Data(input.utf8)
        } else {
            guard let url = URL(string: input), url.scheme == "https", url.host != nil else {
                throw VPNError.message("Enter an HTTPS subscription URL or a VLESS link.")
            }
            let deviceID = useHappCompatibility ? Self.happDeviceID(for: url) : nil
            data = try await SubscriptionFetcher.fetch(
                url,
                as: useHappCompatibility ? .happ : .matveevVpn,
                deviceID: deviceID
            )
        }
        let decoded = try Subscription.decode(data, allowHappJSON: useHappCompatibility)
        let nodes = try Subscription.nodes(decoded)
        if nodes.allSatisfy({ $0.port == 1 && $0.name.localizedCaseInsensitiveContains("not supported") }) {
            let message = useHappCompatibility
                ? "The provider rejected the Happ-compatible request or device identifier. Check the subscription's device limit."
                : "This provider requires Happ subscription compatibility. Enable it and reload the subscription."
            throw VPNError.message(message)
        }
        let old = self.availableNodes.first { $0.id == self.state.selectedNodeID }
        let fallback = nodes.filter { $0.name == old?.name && $0.host == old?.host && $0.port == old?.port }
        let matched = nodes.first { $0.id == old?.id } ?? (fallback.count == 1 ? fallback.first : nil)
        self.candidateSubscription = decoded
        self.candidateNodes = nodes
        self.candidateID = matched?.id ?? (old == nil ? nodes.first?.id : nil)
        self.candidateURL = input
        self.loadedURL = input
    }
    func setHappCompatibility(_ enabled: Bool) {
        happCompatibilityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "happSubscriptionCompatibility")
        loadedURL = ""
    }

    private static func happDeviceID(for url: URL) -> String {
        let defaults = UserDefaults.standard
        let scope = (url.host ?? url.absoluteString).lowercased()
        let scopeKey = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        var identifiers = defaults.dictionary(forKey: "happSubscriptionDeviceIDs") as? [String: String] ?? [:]
        if let existing = identifiers[scopeKey],
           existing.range(of: "^[A-Za-z0-9=-]{10,64}$", options: .regularExpression) != nil {
            return existing
        }
        let generated = "mvp-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        identifiers[scopeKey] = generated
        defaults.set(identifiers, forKey: "happSubscriptionDeviceIDs")
        return generated
    }
    func applySubscription() {
        let input = candidateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let useHappCompatibility = happCompatibilityEnabled
        perform(isInstalled ? "Apply subscription" : "Install and connect") { deadline in
            if input != self.loadedURL || self.candidateSubscription.isEmpty {
                try await self.loadCandidateSubscription(input, useHappCompatibility: useHappCompatibility)
            }
            guard let selectedID = self.candidateID else {
                throw VPNError.message("Your previous node is missing. Choose a replacement.")
            }
            var next = self.state
            next.subscriptionURL = input
            next.subscription = self.candidateSubscription
            next.selectedNodeID = selectedID
            next.lastRefresh = Date()
            if !self.isInstalled || self.state.selectedNodeID == nil { next.desiredOn = true }
            self.message = self.isInstalled ? "Applying subscription…" : "Installing the system component…"
            try await self.commit(next, until: deadline)
            self.showConnection = false
            self.probeCandidateNode(selectedID)
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

    private func scheduleAdBlockRefreshIfNeeded() {
        guard adBlockRefresh == nil, !isBusy, state.rules.adBlockingEnabled,
              adBlockRuleStore.needsRefresh || adBlockRulesNeedApply else { return }
        adBlockRefresh = Task {
            defer { self.adBlockRefresh = nil }
            do {
                if self.adBlockRuleStore.needsRefresh {
                    let changed = try await self.adBlockRuleStore.refresh()
                    self.adBlockRulesNeedApply = self.adBlockRulesNeedApply || changed
                    AppLogger.shared.write("HaGeZi advertising rules refreshed\(changed ? " and changed" : "")")
                }
                guard self.adBlockRulesNeedApply, self.state.rules.adBlockingEnabled,
                      self.service.running, !self.isBusy else { return }

                self.isBusy = true
                let deadline = Date().addingTimeInterval(SystemService.operationTimeout)
                self.message = "Updating advertising rules…"
                defer {
                    self.isBusy = false
                    self.message = ""
                    self.refresh()
                }
                let snapshot = self.state
                let stage = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: stage) }
                let config = try await self.service.generate(snapshot, at: stage, until: deadline)
                if !self.service.configurationMatches(config) {
                    try await self.service.deploy(config, until: deadline)
                    self.checkConnection()
                }
                self.adBlockRulesNeedApply = false
            } catch {
                self.adBlockRulesNeedApply = false
                AppLogger.shared.write("HaGeZi advertising-rule refresh failed: \(error.localizedDescription)")
            }
        }
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
    func testNodes() {
        startNodeTest(availableNodes)
    }

    func testCandidateNodes() {
        startNodeTest(candidateNodes)
    }

    private func startNodeTest(_ nodes: [VPNNode]) {
        guard !testingNodes else { return }
        guard !nodes.isEmpty else { return }
        let deadline = Date().addingTimeInterval(SystemService.operationTimeout)
        testingNodes = true
        AppLogger.shared.write("node latency check started; count=\(nodes.count)")
        Task {
            for node in nodes { self.probeResults.removeValue(forKey: node.id) }
            await withTaskGroup(of: (String, NodeProbeResult).self) { group in
                var iterator = nodes.makeIterator()
                for _ in 0..<4 {
                    if let node = iterator.next() { group.addTask { (node.id, await NodeProbe.measure(node, timeout: min(5, deadline.timeIntervalSinceNow))) } }
                }
                for await (id, result) in group {
                    self.probeResults[id] = result
                    if Date() < deadline, let node = iterator.next() { group.addTask { (node.id, await NodeProbe.measure(node, timeout: min(5, deadline.timeIntervalSinceNow))) } }
                }
            }
            let reachable = nodes.filter { self.probeResults[$0.id]?.isReachable == true }.count
            AppLogger.shared.write("node latency check completed; reachable=\(reachable)/\(nodes.count)")
            self.testingNodes = false
        }
    }
    private func probeNode(_ id: String) async {
        guard let node = (availableNodes + candidateNodes).first(where: { $0.id == id }) else {
            return
        }
        let result = await NodeProbe.measure(node)
        guard !Task.isCancelled else { return }
        probeResults[id] = result
        AppLogger.shared.write("node probe \(id.prefix(8)): \(result.displayText)")
    }

    func probeCandidateNode(_ id: String?) {
        nodeProbe?.cancel()
        guard let id else { return }
        nodeProbe = Task { await probeNode(id) }
    }

    private func scheduleHealthCheckIfNeeded() {
        guard healthCheck == nil, recoveryTask == nil, state.desiredOn, isInstalled, isRunning,
              Date().timeIntervalSince(lastHealthCheck) >= Self.healthCheckInterval else { return }
        lastHealthCheck = Date()
        healthCheck = Task {
            let healthy = await Self.tunnelDNSReachable()
            guard !Task.isCancelled else { return }
            self.healthCheck = nil
            guard !self.isBusy, self.state.desiredOn, self.service.running else { return }
            if healthy {
                if self.consecutiveHealthFailures > 0 {
                    AppLogger.shared.write("tunnel health restored after \(self.consecutiveHealthFailures) failed checks")
                }
                self.consecutiveHealthFailures = 0
                if self.nextRecoveryAttempt != .distantPast {
                    self.nextRecoveryAttempt = .distantPast
                    self.recoveryFailureNotified = false
                    self.failureReport = ""
                    self.message = "Connection restored on the current node."
                    AppLogger.shared.write("tunnel health confirmed recovery by the controller")
                }
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
              Date() >= recoverySuppressedUntil, Date() >= nextRecoveryAttempt,
              isInstalled, !needsUpgrade, !service.isConnecting,
              state.selectedNodeID != nil else { return }
        healthCheck?.cancel()
        healthCheck = nil
        recoveryTask = Task {
            let deadline = Date().addingTimeInterval(SystemService.operationTimeout)
            self.isBusy = true
            self.isRecovering = true
            self.message = "Connection problem detected. Trying to recover…"
            AppLogger.shared.write("automatic recovery started: \(reason)")
            do {
                try await self.recoverConnection(until: deadline)
                try Task.checkCancellation()
                self.failureReport = ""
                self.nextRecoveryAttempt = .distantPast
                self.recoveryFailureNotified = false
            } catch is CancellationError {
                AppLogger.shared.write("automatic recovery cancelled by the user")
            } catch {
                if !Task.isCancelled && self.state.desiredOn {
                    self.scheduleRetryAfterRecoveryFailure(error)
                }
            }
            self.consecutiveHealthFailures = 0
            self.lastHealthCheck = Date()
            if !self.isStoppingRecovery {
                self.isBusy = false
                self.isRecovering = false
                self.recoveryTask = nil
                self.refresh()
            }
        }
    }

    func cancelAutomaticRecovery() {
        guard recoveryTask != nil, !isStoppingRecovery else { return }
        var next = state
        next.desiredOn = false
        state = next
        do { try store.save(next) }
        catch { AppLogger.shared.write("could not persist recovery cancellation: \(error.localizedDescription)") }
        recoverySuppressedUntil = Date().addingTimeInterval(30)
        nextRecoveryAttempt = .distantPast
        consecutiveHealthFailures = 0
        recoveryFailureNotified = false
        isStoppingRecovery = true
        recoveryTask?.cancel()
        message = "Stopping automatic recovery…"
        AppLogger.shared.write("user requested automatic recovery cancellation")
        Task {
            var stopped = false
            do {
                try await self.service.send("off")
                stopped = true
            }
            catch {
                AppLogger.shared.write("controller did not confirm recovery cancellation: \(error.localizedDescription)\nDetails:\n\(self.rawErrorDetails(error))")
                stopped = self.service.runtimeStatus == "stopped"
                if !stopped {
                    var restored = self.state
                    restored.desiredOn = true
                    self.state = restored
                    try? self.store.save(restored)
                    self.failureReport = error.localizedDescription
                }
            }
            self.message = stopped
                ? "Automatic recovery stopped. VPN is off."
                : "Automatic recovery was cancelled, but the controller did not confirm that the VPN stopped. Try Turn Off or Repair Service."
            self.isStoppingRecovery = false
            self.isBusy = false
            self.isRecovering = false
            self.recoveryTask = nil
            self.refresh()
        }
    }

    private func recoverConnection(until deadline: Date) async throws {
        for attempt in 1...Self.currentNodeRestartAttempts {
            try Task.checkCancellation()
            try SystemService.checkDeadline(deadline)
            if service.isConnecting { return }
            AppLogger.shared.write("automatic recovery: restart current node attempt \(attempt)/\(Self.currentNodeRestartAttempts)")
            do { try await service.send("restart", until: deadline) }
            catch {
                AppLogger.shared.write("automatic restart \(attempt) was rejected: \(error.localizedDescription)\nDetails:\n\(rawErrorDetails(error))")
                try Task.checkCancellation()
                continue
            }
            let tunnelHealthy = await Self.tunnelDNSReachable(until: deadline)
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
            try SystemService.checkDeadline(deadline)
            if service.isConnecting { return }

            let probe = await NodeProbe.measure(candidate, timeout: min(3, deadline.timeIntervalSinceNow))
            try Task.checkCancellation()
            try SystemService.checkDeadline(deadline)
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
                state = try await coordinator.apply(next, previous: state, until: deadline)
                let tunnelHealthy = await Self.tunnelDNSReachable(until: deadline)
                if service.running && tunnelHealthy {
                    message = "Automatically switched to \(candidate.name)."
                    AppLogger.shared.write("automatic failover succeeded on node \(candidate.id.prefix(8))")
                    if notificationsEnabled { notify("VPN node changed", "Connected to \(candidate.name).") }
                    return
                }
            } catch {
                AppLogger.shared.write("automatic failover node \(candidate.id.prefix(8)) failed: \(error.localizedDescription)")
            }
        }

        if service.isConnecting { return }
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

    private func scheduleRetryAfterRecoveryFailure(_ error: Error) {
        nextRecoveryAttempt = Date().addingTimeInterval(Self.recoveryRetryInterval)
        let seconds = Int(Self.recoveryRetryInterval)
        let recoveryError = VPNError.message("VPN is still unavailable. Automatic recovery will retry in \(seconds) seconds. \(error.localizedDescription)")
        message = recoveryError.localizedDescription
        failureReport = recoveryError.localizedDescription
        let report = makeLogReport(operation: "Automatic connection recovery", error: recoveryError)
        Task { AppLogger.shared.write(report + "\n" + (await connectionContext())) }
        if notificationsEnabled && !recoveryFailureNotified {
            recoveryFailureNotified = true
            notify("VPN connection unavailable", "Automatic recovery will keep retrying every \(seconds) seconds.")
        }
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
            self.diagnostics = "Checked: \(Date().formatted())\nApp: \(Self.releaseVersion)\nController: \(self.service.currentVersion)\nSettings schema: \(snapshot.schemaVersion)\nMode: \(snapshot.rules.mode.rawValue)\nTunnel: \(self.service.running ? "running" : "stopped")\nSystem DNS: \(dns)\nTunnel DNS: \(tunnelDNS)\nDirect IPv4: \(direct)\nVPN IPv4: \(vpn)\nVPN path: \(path)\nIPv6: disabled for compatibility\nService presets: \(snapshot.rules.automaticRoutingEnabled ? snapshot.rules.automaticServices.count : 0)\nAd blocking: \(snapshot.rules.adBlockingEnabled ? "on" : "off")\nDomain rules: \(snapshot.rules.domains.count)\nApplication rules: \(snapshot.rules.applications.count + snapshot.rules.processPathRegexes.count)\nWhile connected, Tunnel DNS should be reachable. The two IPv4 probes are explicitly routed through different outbounds and should normally report different addresses."
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
    private nonisolated static func tunnelDNS(until deadline: Date = Date().addingTimeInterval(3)) async -> String {
        let result = await Command.run("/usr/bin/dig", ["+time=3", "+tries=1", "+short", "@198.18.0.2", "api4.ipify.org", "A"], timeout: deadline.timeIntervalSinceNow)
        let addresses = result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return result.status == 0 && !addresses.isEmpty ? "reachable" : "unavailable"
    }
    private nonisolated static func tunnelDNSReachable(until deadline: Date = Date().addingTimeInterval(3)) async -> Bool {
        await tunnelDNS(until: deadline) == "reachable"
    }
    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AppLogger.exportFileName()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            var contents = AppLogger.shared.contents()
            if let runtime = service.recentRuntimeErrorDetails() {
                if !contents.hasSuffix("\n") { contents += "\n" }
                contents += "\nPrivileged VPN runtime diagnostics\n================================================\n\(runtime)\n"
            }
            let data = Data(contents.utf8)
            try data.write(to: destination, options: .atomic)
            message = "Diagnostic log exported."
            AppLogger.shared.write("diagnostic log exported as \(destination.lastPathComponent)")
        } catch {
            message = "Could not export the diagnostic log: \(error.localizedDescription)"
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
        let connectivity = NodeProbe.physicalInterface(in: network.output) != nil ? "physical interface available" : "offline or no physical interface"
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

    func repair() {
        perform { deadline in
            let stage = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: stage) }
            let config = try await self.service.generate(self.state, at: stage, until: deadline)
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
            perform { deadline in try await self.commit(next, until: deadline) }
        } catch { message = "The file is not a valid routing configuration." }
    }
    func resetSettings() {
        perform(allowRecovery: true) { deadline in
            if self.service.installed { try await self.service.send("reset", until: deadline) }
            let next = try self.store.freshState(); try self.store.save(next); self.state = next
            self.loadFailed = false
            try self.store.finishTransaction()
            UserDefaults.standard.removeObject(forKey: "automaticFailoverSwitchTimestamps")
            UserDefaults.standard.removeObject(forKey: "happSubscriptionCompatibility")
            self.happCompatibilityEnabled = false
            self.setLogin(false)
            self.setNotifications(false)
            self.prepareConnection(); self.showConnection = true
        }
    }
    func runUninstall() {
        perform { _ in
            let script = self.service.payload.appendingPathComponent("uninstall-service.sh")
            let result = await Command.run("/bin/bash", [script.path, "--yes"])
            guard result.status == 0 else { throw VPNError.message("Uninstall was cancelled or failed.") }
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                if error == nil { DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
            }
        }
    }
}

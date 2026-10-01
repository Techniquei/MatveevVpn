import Foundation

// Compile the real presentation model against inert external boundaries.
// These tests never run system tools, contact servers or touch the installed VPN.
struct CommandResult { let status: Int32; let output: String }
enum Command {
    static var tunnelDNSRequests = 0
    static var directInterfaceAvailable = false
    static var holdNextPing = false
    static var pendingPing: CheckedContinuation<CommandResult, Never>?
    static var heldPingCompleted = false
    static var pingDelay: TimeInterval = 0
    static var tunnelDNSAvailable = false
    static var holdNextContext = false
    static var pendingContext: CheckedContinuation<CommandResult, Never>?
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) async -> CommandResult {
        if holdNextContext && executable == "/usr/sbin/networksetup" && arguments == ["-listallhardwareports"] {
            holdNextContext = false
            return await withCheckedContinuation { pendingContext = $0 }
        }
        if executable == "/usr/bin/dig" {
            tunnelDNSRequests += 1
            if tunnelDNSAvailable { return CommandResult(status: 0, output: "192.0.2.1\n") }
        }
        if directInterfaceAvailable && executable == "/usr/sbin/scutil" && arguments == ["--nwi"] {
            return CommandResult(status: 0, output: "en0 : flags : 0x5 (IPv4)")
        }
        if directInterfaceAvailable && executable == "/sbin/ping" {
            if pingDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, min(pingDelay, timeout ?? pingDelay)) * 1_000_000_000))
                if (timeout ?? pingDelay) <= pingDelay { return CommandResult(status: 1, output: "") }
            }
            if holdNextPing {
                holdNextPing = false
                let result = await withCheckedContinuation { pendingPing = $0 }
                heldPingCompleted = true
                return result
            }
            return CommandResult(status: 0, output: "round-trip min/avg/max/stddev = 10.0/20.0/30.0/1.0 ms")
        }
        return CommandResult(status: 1, output: "")
    }
}

struct SystemService {
    static let version = "14"
    static var operationTimeout: TimeInterval = 15
    static func checkDeadline(_ deadline: Date) throws {
        guard Date() < deadline else { throw VPNError.message("The operation exceeded its 15-second limit.") }
    }
    static var installedValue = false
    static var runningValue = false
    static var cancelInstall = false
    static var installs = 0
    static var deployments = 0
    static var actions: [String] = []
    static var routingUpdateValue: Date?
    static var currentVersionValue = version
    static var runtimeStatusValue: String?
    static var rejectRestart = false
    static var waitForNetworkOnRestart = false
    static var restartDelay: TimeInterval = 0
    static var restartDeadlines: [Date] = []
    var installed: Bool { Self.installedValue }
    var running: Bool { Self.runningValue }
    var currentVersion: String { Self.currentVersionValue }
    var runtimeStatus: String { Self.runtimeStatusValue ?? (running ? "running" : "stopped") }
    var isConnecting: Bool { ["starting", "waiting for network"].contains(runtimeStatus) }
    var automaticRoutingLastUpdate: Date? { Self.routingUpdateValue }
    var payload: URL { FileManager.default.temporaryDirectory }
    func generate(_ state: SavedState, at stage: URL, until deadline: Date = Date().addingTimeInterval(15)) async throws -> URL {
        let nodes = try Subscription.nodes(state.subscription)
        let unconfigured = state.subscription.isEmpty && state.selectedNodeID == nil && !state.desiredOn
        guard unconfigured || nodes.contains(where: { $0.id == state.selectedNodeID }) else {
            throw VPNError.message("Choose a node before applying changes.")
        }
        let config = stage.appendingPathComponent("config.json")
        try privateWrite(Data(state.subscription.utf8), to: config)
        return config
    }
    func install(_ config: URL, desiredOn: Bool) async throws {
        Self.installs += 1
        if Self.cancelInstall { throw VPNError.message("System installation was cancelled. Your settings were preserved.") }
        Self.installedValue = true
        Self.currentVersionValue = Self.version
        Self.runningValue = desiredOn
    }
    func deploy(_ config: URL, until deadline: Date = Date().addingTimeInterval(15)) async throws { Self.deployments += 1 }
    func send(_ action: String, until deadline: Date = Date().addingTimeInterval(15)) async throws {
        try Self.checkDeadline(deadline)
        Self.actions.append(action)
        if action == "restart" {
            Self.restartDeadlines.append(deadline)
            try await Task.sleep(nanoseconds: UInt64(max(0, min(Self.restartDelay, deadline.timeIntervalSinceNow)) * 1_000_000_000))
            try Self.checkDeadline(deadline)
        }
        if action == "restart" && Self.rejectRestart {
            Self.runningValue = false
            Self.runtimeStatusValue = Self.waitForNetworkOnRestart ? "waiting for network" : "waiting to retry"
            throw VPNError.message("The controller rejected the change.")
        }
        Self.runningValue = action != "off"
        Self.runtimeStatusValue = nil
    }
    func configurationMatches(_ config: URL) -> Bool { true }
    func recentRuntimeErrors() -> String { "" }
    func recentRuntimeErrorDetails() -> String? { nil }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func reset() {
        installedValue = false; runningValue = false; cancelInstall = false
        installs = 0; deployments = 0; actions = []
        routingUpdateValue = nil
        currentVersionValue = version
        runtimeStatusValue = nil; rejectRestart = false; waitForNetworkOnRestart = false
        restartDelay = 0; restartDeadlines = []
        operationTimeout = 15
        Command.tunnelDNSRequests = 0
        Command.tunnelDNSAvailable = false
        SubscriptionFetcher.requests = 0
        SubscriptionFetcher.failure = false
    }
}

enum SubscriptionFetcher {
    enum ClientIdentity { case matveevVpn, happ }
    static var response = Data()
    static var requests = 0
    static var failure = false
    static func fetch(_ url: URL, as client: ClientIdentity = .matveevVpn, deviceID: String? = nil) async throws -> Data {
        requests += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        if failure { throw VPNError.message("Could not download the subscription. Check the URL and your connection.") }
        return response
    }
}

final class AppLogger {
    static let shared = AppLogger()
    private var entries: [String] = []
    func write(_ message: String) { entries.append(message) }
    func contents() -> String { entries.joined(separator: "\n") }
    static func exportFileName() -> String { "test.log" }
}

func privateWrite(_ data: Data, to file: URL) throws {
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("matveev-first-run-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

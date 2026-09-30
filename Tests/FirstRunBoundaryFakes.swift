import Foundation

// Compile the real presentation model against inert external boundaries.
// These tests never run system tools, contact servers or touch the installed VPN.
struct CommandResult { let status: Int32; let output: String }
enum Command {
    static var tunnelDNSRequests = 0
    static func run(_ executable: String, _ arguments: [String]) async -> CommandResult {
        if executable == "/usr/bin/dig" { tunnelDNSRequests += 1 }
        return CommandResult(status: 1, output: "")
    }
}

struct SystemService {
    static let version = "13"
    static var installedValue = false
    static var runningValue = false
    static var cancelInstall = false
    static var installs = 0
    static var deployments = 0
    static var actions: [String] = []
    static var routingUpdateValue: Date?
    static var currentVersionValue = version
    var installed: Bool { Self.installedValue }
    var running: Bool { Self.runningValue }
    var currentVersion: String { Self.currentVersionValue }
    var runtimeStatus: String { running ? "running" : "stopped" }
    var automaticRoutingLastUpdate: Date? { Self.routingUpdateValue }
    var payload: URL { FileManager.default.temporaryDirectory }
    func generate(_ state: SavedState, at stage: URL) async throws -> URL {
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
    func deploy(_ config: URL) async throws { Self.deployments += 1 }
    func send(_ action: String) async throws {
        Self.actions.append(action)
        Self.runningValue = action != "off"
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
        Command.tunnelDNSRequests = 0
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

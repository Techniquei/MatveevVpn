import Foundation
import CryptoKit
import Darwin

struct CommandResult { let status: Int32; let output: String }

enum Command {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) async -> CommandResult {
        if let timeout, timeout <= 0 { return CommandResult(status: 124, output: "Operation timed out.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let expiry = DispatchWorkItem {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry) }
                    defer { expiry.cancel() }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: "Could not launch a required system tool."))
                }
            }
        }
    }
}

struct SystemService {
    // Version 24 installs ifscope split routes so a socket bound to the
    // physical interface can reach public addresses while the tunnel owns
    // the unscoped 0/1 and 128/1 routes. Version 23 measures node latency
    // through that path. Older services cannot, so the app keeps the local
    // probe until this component is updated.
    static let version = "24"
    static let operationTimeout: TimeInterval = 15
    static func checkDeadline(_ deadline: Date) throws {
        guard Date() < deadline else { throw VPNError.message("The operation exceeded its 15-second limit.") }
    }
    static let base = URL(fileURLWithPath: "/Library/Application Support/matveevVpn")
    var baseDirectory = Self.base
    var payload: URL { Bundle.main.resourceURL!.appendingPathComponent(".payload") }
    var control: URL { baseDirectory.appendingPathComponent("control") }
    var installed: Bool {
        FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent("bin/matveev-xray-service").path)
            || FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent("bin/controller.sh").path)
    }
    var currentVersion: String { (try? String(contentsOf: control.appendingPathComponent("version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1" }
    var runtimeStatus: String {
        if let live = liveStatus() {
            switch live.state {
            case "waiting-network": return "waiting for network"
            case "connected": return "running"
            case "off": return "stopped"
            default: return live.state
            }
        }
        return (try? String(contentsOf: control.appendingPathComponent("runtime-status"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
    }
    var isConnecting: Bool {
        if let live = liveStatus() { return ["starting", "recovering", "waiting-network"].contains(live.state) }
        return ["starting", "waiting for network"].contains(runtimeStatus)
    }
    var automaticRoutingLastUpdate: Date? {
        Self.routingUpdateDate(at: control.appendingPathComponent("routing-updated-at"))
    }
    static func routingUpdateDate(at file: URL) -> Date? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, seconds > 0, seconds <= Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    var running: Bool {
        if let live = liveStatus() { return live.state == "connected" }
        let file = control.appendingPathComponent("runtime-status")
        guard (try? String(contentsOf: file, encoding: .utf8))?.hasPrefix("running") == true else { return false }
        if currentVersion == "1" { return true }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    func send(_ action: String, until deadline: Date = Date().addingTimeInterval(Self.operationTimeout)) async throws {
        guard ["on", "off", "restart", "reload", "reset"].contains(action) else { throw VPNError.message("Invalid controller command.") }
        try Self.checkDeadline(deadline)
        if socketReady {
            switch action {
            case "on": try await setDesired(true, until: deadline)
            case "off", "reset": try await setDesired(false, until: deadline)
            case "restart":
                try await setDesired(false, until: deadline)
                try await setDesired(true, until: deadline)
            default:
                _ = try await exchange(action: "GetStatus", expected: 0, payload: nil, until: deadline)
            }
            return
        }
        // File commands remain only while an older controller.sh installation is still present.
        let token = UUID().uuidString
        let response = control.appendingPathComponent("response-\(token)")
        let expiry = Int64(deadline.timeIntervalSince1970 * 1000)
        try privateWrite(Data("\(action) \(token) \(expiry)\n".utf8), to: control.appendingPathComponent("command"))
        while Date() < deadline {
            if let value = try? String(contentsOf: response, encoding: .utf8) {
                try? FileManager.default.removeItem(at: response)
                guard value.hasPrefix("ok") else {
                    throw VPNError.diagnostic("The controller rejected the change. The previous configuration was retained.", recentRuntimeErrors())
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNError.diagnostic("The operation exceeded its 15-second limit.", recentRuntimeErrors())
    }

    func generate(_ state: SavedState, at stage: URL, until deadline: Date = Date().addingTimeInterval(Self.operationTimeout)) async throws -> URL {
        try Self.checkDeadline(deadline)
        try state.rules.validate()
        let nodes = state.subscription.isEmpty ? [] : try Subscription.nodes(state.subscription)
        if !nodes.isEmpty && !nodes.contains(where: { $0.id == state.selectedNodeID }) {
            throw VPNError.message("Choose a node before applying changes.")
        }
        var url = state.subscriptionURL
        if URL(string: url)?.scheme != "https" { url = "" }
        let intent = RuntimeIntent(
            nodes: nodes.map { RuntimeNode(id: $0.id, uri: $0.uri) },
            selectedNodeID: state.selectedNodeID ?? "",
            subscriptionURL: url,
            mode: state.rules.mode.rawValue,
            presets: state.rules.automaticRoutingEnabled ? state.rules.automaticServices : [],
            userDomains: state.rules.domains.map { $0.lowercased() },
            adBlocking: state.rules.adBlockingEnabled
        )
        let config = stage.appendingPathComponent("config.json")
        try privateWrite(try JSONEncoder().encode(intent), to: config)
        return config
    }

    func deploy(_ config: URL, until deadline: Date = Date().addingTimeInterval(Self.operationTimeout)) async throws {
        try Self.checkDeadline(deadline)
        guard socketReady else { throw VPNError.message("The VPN service is not available.") }
        let payload = try Data(contentsOf: config)
        let current = try await exchange(action: "GetStatus", expected: 0, payload: nil, until: deadline)
        _ = try await exchange(action: "Apply", expected: current.revision, payload: payload, until: deadline)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try? privateWrite(Data(hash.utf8), to: control.appendingPathComponent("config-sha256"))
    }

    func configurationMatches(_ config: URL) -> Bool {
        guard let data = try? Data(contentsOf: config),
              let active = try? String(contentsOf: control.appendingPathComponent("config-sha256"), encoding: .utf8)
        else { return false }
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return active.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    func install(_ config: URL, desiredOn: Bool) async throws {
        let script = payload.appendingPathComponent("install-service.sh")
        let command = ["/bin/bash", script.path, payload.path, config.path, String(getuid()), String(getgid()), desiredOn ? "on" : "off"].map(Self.quote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await Command.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        guard result.status == 0 else {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = output.isEmpty ? "osascript exited with status \(result.status)." : output
            let cancelled = output.localizedCaseInsensitiveContains("user canceled") || output.contains("(-128)")
            let summary = cancelled
                ? "System installation was cancelled. Your settings were preserved."
                : "System installation failed. Your settings were preserved. Export Logs for technical details."
            throw VPNError.diagnostic(summary, details)
        }
        for _ in 0..<150 {
            if currentVersion == Self.version && socketReady {
                // Installation is ready when the service answers. Connecting is a separate operation.
                if desiredOn { try await setDesired(true, until: Date().addingTimeInterval(Self.operationTimeout)) }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNError.diagnostic("The service was installed but did not become ready within 15 seconds.", recentRuntimeErrors())
    }

    func liveStatus() -> (state: String, nodeID: String, error: String)? {
        guard socketReady, let reply = try? exchangeSync(action: "GetStatus", expected: 0, payload: nil, until: Date().addingTimeInterval(2)) else { return nil }
        return (reply.state, reply.nodeID, reply.error)
    }

    private var socketURL: URL { baseDirectory.appendingPathComponent("ipc/service.sock") }
    private var socketReady: Bool { FileManager.default.fileExists(atPath: socketURL.path) }

    private func setDesired(_ on: Bool, until deadline: Date) async throws {
        let current = try await exchange(action: "GetStatus", expected: 0, payload: nil, until: deadline)
        let payload = try JSONSerialization.data(withJSONObject: ["desiredOn": on])
        _ = try await exchange(action: "SetDesiredOn", expected: current.revision, payload: payload, until: deadline)
        guard on else { return }
        // A dead selected server is replaced before this returns. The caller's
        // remaining budget can expire while that attempt is still starting.
        let connectedBy = Date().addingTimeInterval(30)
        while Date() < connectedBy {
            let live = try await exchange(action: "GetStatus", expected: 0, payload: nil, until: connectedBy)
            switch live.state {
            case "connected":
                return
            case "error", "off":
                let failure = VPNError.message(Self.describeRuntimeError(live.error))
                _ = try? await exchange(action: "SetDesiredOn", expected: live.revision, payload: try JSONSerialization.data(withJSONObject: ["desiredOn": false]), until: connectedBy)
                throw failure
            default:
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let stopBy = Date().addingTimeInterval(3)
        if let live = try? await exchange(action: "GetStatus", expected: 0, payload: nil, until: stopBy) {
            if live.state == "connected" { return }
            _ = try? await exchange(action: "SetDesiredOn", expected: live.revision, payload: try JSONSerialization.data(withJSONObject: ["desiredOn": false]), until: stopBy)
            if live.state == "error" || live.state == "off" {
                throw VPNError.message(Self.describeRuntimeError(live.error))
            }
        }
        throw VPNError.message("The VPN did not finish connecting.")
    }

    private static func describeRuntimeError(_ token: String) -> String {
        switch token {
        case "network_or_dns_conflict":
            return "Another VPN tunnel is already using the network, so this one did not start."
        case "no_selected_node":
            return "Choose a server before connecting."
        case "configuration_rejected":
            return "The VPN configuration was rejected."
        case "tun_unavailable":
            return "The VPN could not create a tunnel interface."
        case "startup_timeout":
            return "The VPN did not finish starting. Try connecting again."
        case "switch_limit", "recovery_exhausted":
            return "The VPN could not find a working server. Try again in a minute."
        case "":
            return "The VPN stopped while it was starting."
        default:
            return "The VPN could not start (\(token))."
        }
    }

    func statusLine() -> String? {
        guard let live = liveStatus() else { return nil }
        switch live.state {
        case "starting":
            return "Connecting…"
        case "recovering":
            return "Restoring the connection…"
        case "waiting-network":
            return "Waiting for network…"
        case "error":
            return Self.describeRuntimeError(live.error)
        default:
            return nil
        }
    }

    private func exchange(action: String, expected: UInt64, payload: Data?, until deadline: Date) async throws -> IPCReply {
        try Self.checkDeadline(deadline)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.exchangeSync(action: action, expected: expected, payload: payload, until: deadline)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func exchangeSync(action: String, expected: UInt64, payload: Data?, until deadline: Date) throws -> IPCReply {
        try Self.checkDeadline(deadline)
        var object: [String: Any] = ["version": 1, "requestID": UUID().uuidString, "action": action, "expectedRevision": expected]
        if let payload { object["payload"] = try JSONSerialization.jsonObject(with: payload) }
        let body = try JSONSerialization.data(withJSONObject: object)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNError.message("The VPN service is not available.") }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8CString)
        guard bytes.count < 104 else { throw VPNError.message("The VPN service is not available.") }
        withUnsafeMutablePointer(to: &address.sun_path.0) { dest in
            bytes.withUnsafeBufferPointer { src in dest.update(from: src.baseAddress!, count: src.count) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw VPNError.message("The VPN service is not available.") }
        var message = body
        message.append(10)
        let wrote = message.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard wrote == message.count else { throw VPNError.message("The VPN service is not available.") }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !collected.contains(10) && collected.count < 1_048_576 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(buffer, count: count)
        }
        guard let newline = collected.firstIndex(of: 10),
              let reply = try JSONSerialization.jsonObject(with: collected[..<newline]) as? [String: Any] else {
            throw VPNError.message("The VPN service is not available.")
        }
        let status = reply["status"] as? [String: Any] ?? [:]
        let error = reply["error"] as? String ?? ""
        if reply["success"] as? Bool != true {
            throw VPNError.message(error.isEmpty ? "The VPN service rejected the change." : error)
        }
        return IPCReply(
            state: status["runtimeState"] as? String ?? "",
            nodeID: status["nodeID"] as? String ?? "",
            error: status["error"] as? String ?? "",
            revision: (status["acceptedRevision"] as? NSNumber)?.uint64Value ?? 0,
            probes: reply["probes"] as? [[String: Any]] ?? []
        )
    }

    func measureNodes(_ ids: [String], until deadline: Date) async -> [String: NodeProbeResult]? {
        guard socketReady, currentVersion == Self.version, !ids.isEmpty else { return nil }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["nodeIDs": ids]) else { return nil }
        guard let reply = try? await exchange(action: "ProbeNodes", expected: 0, payload: payload, until: deadline) else { return nil }
        var results: [String: NodeProbeResult] = [:]
        for probe in reply.probes {
            guard let id = probe["id"] as? String, !id.isEmpty else { continue }
            if probe["reachable"] as? Bool == true {
                let latency = (probe["latencyMilliseconds"] as? NSNumber)?.intValue
                results[id] = NodeProbeResult(outcome: .reachable, latencyMilliseconds: latency.map { max(1, $0) }, method: .tcp)
            } else {
                results[id] = NodeProbeResult(outcome: .timedOut, latencyMilliseconds: nil, method: nil)
            }
        }
        return results
    }

    func recentRuntimeErrors() -> String {
        recentRuntimeErrorDetails() ?? "The VPN runtime did not provide an error log."
    }

    func recentRuntimeErrorDetails() -> String? {
        let files = [control.appendingPathComponent("last-error.log"), baseDirectory.appendingPathComponent("run/vpn.error.log")]
        let details = files.compactMap { file -> String? in
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
                return file.lastPathComponent + ":\n" + text.split(separator: "\n").suffix(80).joined(separator: "\n")
            }
            return nil
        }
        return details.isEmpty ? nil : details.joined(separator: "\n\n")
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct IPCReply {
    var state = ""
    var nodeID = ""
    var error = ""
    var revision: UInt64 = 0
    var probes: [[String: Any]] = []
}

private struct RuntimeIntent: Codable {
    var nodes: [RuntimeNode]
    var selectedNodeID: String
    var subscriptionURL: String
    var mode: String
    var presets: [String]
    var userDomains: [String]
    var adBlocking: Bool
}

private struct RuntimeNode: Codable {
    var id: String
    var uri: String
}

func privateWrite(_ data: Data, to file: URL) throws {
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("matveev-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

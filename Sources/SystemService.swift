import Foundation
import CryptoKit

struct CommandResult { let status: Int32; let output: String }

enum Command {
    static func run(_ executable: String, _ arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
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
    static let version = "10"
    static let base = URL(fileURLWithPath: "/Library/Application Support/matveevVpn")
    var payload: URL { Bundle.main.resourceURL!.appendingPathComponent(".payload") }
    var control: URL { Self.base.appendingPathComponent("control") }
    var installed: Bool { FileManager.default.fileExists(atPath: Self.base.appendingPathComponent("bin/controller.sh").path) }
    var currentVersion: String { (try? String(contentsOf: control.appendingPathComponent("version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1" }
    var runtimeStatus: String {
        (try? String(contentsOf: control.appendingPathComponent("runtime-status"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
    }
    var running: Bool {
        let file = control.appendingPathComponent("runtime-status")
        guard (try? String(contentsOf: file, encoding: .utf8))?.hasPrefix("running") == true else { return false }
        if currentVersion == "1" { return true }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    func send(_ action: String) async throws {
        guard ["on", "off", "restart", "reload", "reset"].contains(action) else { throw VPNError.message("Invalid controller command.") }
        let token = UUID().uuidString
        let response = control.appendingPathComponent("response-\(token)")
        try privateWrite(Data("\(action) \(token)\n".utf8), to: control.appendingPathComponent("command"))
        for _ in 0..<150 {
            if let value = try? String(contentsOf: response, encoding: .utf8) {
                try? FileManager.default.removeItem(at: response)
                guard value.hasPrefix("ok") else {
                    throw VPNError.diagnostic("The controller rejected the change. The previous configuration was retained.", recentRuntimeErrors())
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNError.diagnostic("The controller did not respond within 15 seconds.", recentRuntimeErrors())
    }

    func generate(_ state: SavedState, at stage: URL) async throws -> URL {
        try state.rules.validate()
        let nodes = try Subscription.nodes(state.subscription)
        guard let node = nodes.first(where: { $0.id == state.selectedNodeID }) else { throw VPNError.message("Choose a node before applying changes.") }
        let subscription = stage.appendingPathComponent("subscription")
        let rules = stage.appendingPathComponent("rules.json")
        let config = stage.appendingPathComponent("config.json")
        try privateWrite(Data(state.subscription.utf8), to: subscription)
        try privateWrite(JSONEncoder().encode(state.rules), to: rules)
        let generated = await Command.run("/usr/bin/ruby", [payload.appendingPathComponent("tools/build-config.rb").path, subscription.path, config.path, String(node.index), rules.path])
        guard generated.status == 0 else { throw VPNError.diagnostic("Invalid routing rule or unsupported VLESS transport. Check domain patterns and process expressions.", generated.output) }
        let checked = await Command.run(payload.appendingPathComponent("sing-box").path, ["check", "-c", config.path])
        guard checked.status == 0 else { throw VPNError.diagnostic("The configuration did not pass validation. Check the node and routing expressions.", checked.output) }
        let xrayConfig = URL(fileURLWithPath: config.path + ".xray.json")
        if FileManager.default.fileExists(atPath: xrayConfig.path) {
            let xrayChecked = await Command.run(payload.appendingPathComponent("xray").path, ["run", "-test", "-c", xrayConfig.path])
            guard xrayChecked.status == 0 else { throw VPNError.diagnostic("The Xray transport configuration did not pass validation. Check the selected node.", xrayChecked.output) }
        }
        return config
    }

    func deploy(_ config: URL) async throws {
        let pendingXray = control.appendingPathComponent("pending-xray.json")
        try? FileManager.default.removeItem(at: pendingXray)
        let xrayConfig = URL(fileURLWithPath: config.path + ".xray.json")
        if FileManager.default.fileExists(atPath: xrayConfig.path) {
            try privateWrite(Data(contentsOf: xrayConfig), to: pendingXray)
        }
        try privateWrite(Data(contentsOf: config), to: control.appendingPathComponent("pending-config.json"))
        try await send("reload")
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
        guard result.status == 0 else { throw VPNError.message("System installation failed or was cancelled. Your settings were preserved.") }
        for _ in 0..<150 {
            if currentVersion == Self.version && (!desiredOn || running) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNError.diagnostic("The service was installed but did not become ready within 15 seconds.", recentRuntimeErrors())
    }

    func recentRuntimeErrors() -> String {
        let files = [control.appendingPathComponent("last-error.log"), Self.base.appendingPathComponent("run/vpn.error.log")]
        for file in files {
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
                return text.split(separator: "\n").suffix(80).joined(separator: "\n")
            }
        }
        return "The VPN runtime did not provide an error log."
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
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

import Foundation
import CryptoKit

enum VPNError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum RoutingMode: String, Codable, CaseIterable { case selective, all }

struct RoutingRules: Codable, Equatable {
    var domains: [String] = []
    var applications: [String] = []
    var processPathRegexes: [String] = []
    var mode: RoutingMode = .selective
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        applications = try c.decodeIfPresent([String].self, forKey: .applications) ?? []
        processPathRegexes = try c.decodeIfPresent([String].self, forKey: .processPathRegexes) ?? []
        mode = try c.decodeIfPresent(RoutingMode.self, forKey: .mode) ?? .selective
    }
    func validate() throws {
        for (index, entry) in domains.enumerated() {
            let domain = entry.hasPrefix("*.") ? String(entry.dropFirst(2)) : entry
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            let valid = !domain.isEmpty && domain.count <= 253 && labels.allSatisfy {
                $0.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil
            }
            guard valid else { throw VPNError.message("Domain line \(index + 1): use example.com or *.example.com, without a URL or path.") }
        }
        for (index, pattern) in processPathRegexes.enumerated() {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { throw VPNError.message("Application path line \(index + 1): invalid regular expression.") }
            if ["(?=", "(?!", "(?<=", "(?<!"].contains(where: pattern.contains) || pattern.range(of: #"\\[1-9]"#, options: .regularExpression) != nil {
                throw VPNError.message("Application path line \(index + 1): lookarounds and backreferences are not supported. Use a simple path expression.")
            }
        }
    }
}

struct VPNNode: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let index: Int
}

enum Subscription {
    static func decode(_ data: Data) throws -> String {
        guard data.count <= 4_194_304, let raw = String(data: data, encoding: .utf8) else {
            throw VPNError.message("The subscription is too large or is not text.")
        }
        let compact = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
        let decoded = raw.contains("vless://") ? raw : String(data: Data(base64Encoded: padded) ?? Data(), encoding: .utf8) ?? ""
        let lines = decoded.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("vless://") }) else {
            throw VPNError.message("The subscription must contain VLESS links.")
        }
        let result = lines.joined(separator: "\n") + "\n"
        _ = try nodes(result)
        return result
    }

    static func nodes(_ text: String) throws -> [VPNNode] {
        var seen = Set<String>()
        return try text.split(whereSeparator: \.isNewline).enumerated().map { offset, line in
            guard var parts = URLComponents(string: String(line)), parts.scheme == "vless",
                  let host = parts.host, !host.isEmpty, let port = parts.port, (1...65535).contains(port),
                  let user = parts.user, UUID(uuidString: user) != nil else {
                throw VPNError.message("Invalid VLESS node on line \(offset + 1).")
            }
            let name = parts.fragment.flatMap { $0.isEmpty ? nil : $0 } ?? "\(host):\(port)"
            parts.fragment = nil
            parts.host = host.lowercased()
            parts.queryItems = parts.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            let id = SHA256.hash(data: Data((parts.string ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            return VPNNode(id: id, name: name, host: host, port: port, index: offset + 1)
        }.filter { seen.insert($0.id).inserted }
    }
}

struct SavedState: Codable {
    var schemaVersion = 2
    var subscriptionURL = ""
    var subscription = ""
    var selectedNodeID: String?
    var rules = RoutingRules()
    var desiredOn = false
    var lastRefresh: Date?
    var migratedFromV1 = false
}

struct StateStore {
    struct Pending: Codable { let state: SavedState; let configHash: String }
    let directory: URL
    let legacyDirectory: URL
    let runtimeHashFile: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/matveevVpn"), legacyDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VPN"), runtimeHashFile: URL = URL(fileURLWithPath: "/Library/Application Support/matveevVpn/control/config-sha256")) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.runtimeHashFile = runtimeHashFile
    }
    var file: URL { directory.appendingPathComponent("settings.json") }
    var pendingFile: URL { directory.appendingPathComponent("pending.json") }
    func load() throws -> SavedState {
        if FileManager.default.fileExists(atPath: pendingFile.path) {
            let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingFile))
            let activeHash = (try? String(contentsOf: runtimeHashFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if activeHash == pending.configHash { try save(pending.state) }
            if activeHash != nil { try FileManager.default.removeItem(at: pendingFile) }
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return try migrate() }
        let value = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
        guard value.schemaVersion == 2 else { throw VPNError.message("These settings require a newer app version.") }
        return value
    }
    func stage(_ state: SavedState, config: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hash = SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined()
        let data = try JSONEncoder().encode(Pending(state: state, configHash: hash))
        try data.write(to: pendingFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingFile.path)
    }
    func finishTransaction() throws {
        if FileManager.default.fileExists(atPath: pendingFile.path) { try FileManager.default.removeItem(at: pendingFile) }
    }
    func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func migrate() throws -> SavedState {
        let legacy = legacyDirectory
        let subscriptionFile = legacy.appendingPathComponent(".service/private/subscription.decoded")
        guard FileManager.default.fileExists(atPath: subscriptionFile.path) else { return SavedState() }
        var state = SavedState()
        state.subscription = try Subscription.decode(Data(contentsOf: subscriptionFile))
        state.rules = try JSONDecoder().decode(RoutingRules.self, from: Data(contentsOf: legacy.appendingPathComponent("routing-rules.json")))
        state.subscriptionURL = (try? String(contentsOf: legacy.appendingPathComponent(".service/private/subscription-url.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let index = Int((try String(contentsOf: legacy.appendingPathComponent(".service/current-server.txt"), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
        state.selectedNodeID = try Subscription.nodes(state.subscription).first { $0.index == index }?.id
        state.desiredOn = (try? String(contentsOfFile: "/Library/Application Support/matveevVpn/control/runtime-status", encoding: .utf8))?.hasPrefix("running") == true
        state.migratedFromV1 = true
        try save(state)
        return state
    }
}

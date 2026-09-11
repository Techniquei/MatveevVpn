import Foundation
import CryptoKit

enum VPNError: LocalizedError {
    case message(String)
    case diagnostic(String, String)

    var errorDescription: String? {
        switch self {
        case .message(let text), .diagnostic(let text, _): return text
        }
    }

    var diagnosticDetails: String? {
        if case .diagnostic(_, let details) = self { return details }
        return nil
    }
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
    static func decode(_ data: Data, allowHappJSON: Bool = false) throws -> String {
        guard data.count <= 4_194_304, let raw = String(data: data, encoding: .utf8) else {
            throw VPNError.message("The subscription is too large or is not text.")
        }
        let cleaned = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        if allowHappJSON, let links = happVLESSLinks(cleaned), !links.isEmpty {
            let result = links.joined(separator: "\n") + "\n"
            _ = try nodes(result)
            return result
        }
        let compact = cleaned.components(separatedBy: .whitespacesAndNewlines).joined()
        let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
        let base64 = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let decoded = cleaned.contains("vless://") ? cleaned : String(data: Data(base64Encoded: base64) ?? Data(), encoding: .utf8) ?? ""
        let lines = decoded.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))) }
            .filter { $0.hasPrefix("vless://") }
        guard !lines.isEmpty else {
            throw VPNError.diagnostic(
                "The subscription must contain VLESS links.",
                "Received bytes: \(data.count)\nText encoding: UTF-8\nDirect VLESS content: \(cleaned.contains("vless://") ? "yes" : "no")\nBase64 decoding: \(Data(base64Encoded: base64) == nil ? "failed" : "succeeded")"
            )
        }
        let result = lines.joined(separator: "\n") + "\n"
        _ = try nodes(result)
        return result
    }

    private static func happVLESSLinks(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let configurations: [[String: Any]]
        if let array = value as? [[String: Any]] {
            configurations = array
        } else if let object = value as? [String: Any] {
            configurations = [object]
        } else {
            return nil
        }

        var links: [String] = []
        for configuration in configurations {
            let remarks = configuration["remarks"] as? String
            let outbounds = configuration["outbounds"] as? [[String: Any]] ?? []
            let vlessOutbounds = outbounds.filter { ($0["protocol"] as? String)?.lowercased() == "vless" }
            for (outboundIndex, outbound) in vlessOutbounds.enumerated() {
                guard let settings = outbound["settings"] as? [String: Any],
                      let vnext = settings["vnext"] as? [[String: Any]] else { continue }
                for (serverIndex, server) in vnext.enumerated() {
                    guard let host = server["address"] as? String, !host.isEmpty,
                          let port = integer(server["port"]), (1...65535).contains(port),
                          let users = server["users"] as? [[String: Any]] else { continue }
                    for user in users {
                        guard let id = user["id"] as? String, UUID(uuidString: id) != nil else { continue }
                        var components = URLComponents()
                        components.scheme = "vless"
                        components.user = id
                        components.host = host
                        components.port = port

                        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
                        let network = string(stream["network"]) ?? "raw"
                        let security = string(stream["security"]) ?? "none"
                        var query = [URLQueryItem(name: "encryption", value: string(user["encryption"]) ?? "none")]
                        query.append(URLQueryItem(name: "type", value: network))
                        query.append(URLQueryItem(name: "security", value: security))
                        append(string(user["flow"]), named: "flow", to: &query)

                        if security == "reality", let reality = stream["realitySettings"] as? [String: Any] {
                            append(string(reality["serverName"]), named: "sni", to: &query)
                            append(string(reality["fingerprint"]), named: "fp", to: &query)
                            append(string(reality["publicKey"]) ?? string(reality["password"]), named: "pbk", to: &query)
                            append(string(reality["shortId"]), named: "sid", to: &query, includeEmpty: true)
                            append(string(reality["spiderX"]), named: "spx", to: &query)
                            append(string(reality["mldsa65Verify"]), named: "pqv", to: &query)
                        } else if security == "tls", let tls = stream["tlsSettings"] as? [String: Any] {
                            append(string(tls["serverName"]), named: "sni", to: &query)
                            append(string(tls["fingerprint"]), named: "fp", to: &query)
                            if let alpn = tls["alpn"] as? [String], !alpn.isEmpty {
                                query.append(URLQueryItem(name: "alpn", value: alpn.joined(separator: ",")))
                            }
                        }

                        switch network {
                        case "ws":
                            let ws = stream["wsSettings"] as? [String: Any] ?? [:]
                            append(string(ws["path"]), named: "path", to: &query)
                            if let headers = ws["headers"] as? [String: Any] {
                                append(string(headers["Host"]) ?? string(headers["host"]), named: "host", to: &query)
                            }
                        case "grpc":
                            let grpc = stream["grpcSettings"] as? [String: Any] ?? [:]
                            append(string(grpc["serviceName"]), named: "serviceName", to: &query, includeEmpty: true)
                        case "xhttp", "splithttp":
                            let xhttp = stream["xhttpSettings"] as? [String: Any] ?? [:]
                            append(string(xhttp["host"]), named: "host", to: &query)
                            append(string(xhttp["path"]), named: "path", to: &query)
                            append(string(xhttp["mode"]), named: "mode", to: &query)
                            if let extra = xhttp["extra"], JSONSerialization.isValidJSONObject(extra),
                               let data = try? JSONSerialization.data(withJSONObject: extra),
                               let encoded = String(data: data, encoding: .utf8) {
                                query.append(URLQueryItem(name: "extra", value: encoded))
                            }
                        default: break
                        }

                        components.queryItems = query
                        let tag = string(outbound["tag"])
                        let suffixNeeded = vlessOutbounds.count > 1 || vnext.count > 1 || users.count > 1
                        let fallbackName = tag ?? "Happ VLESS"
                        let suffix = suffixNeeded ? " \(outboundIndex + 1).\(serverIndex + 1)" : ""
                        components.fragment = (remarks?.isEmpty == false ? remarks! : fallbackName) + suffix
                        if let link = components.string { links.append(link) }
                    }
                }
            }
        }
        return links
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func append(_ value: String?, named name: String, to items: inout [URLQueryItem], includeEmpty: Bool = false) {
        guard let value, includeEmpty || !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    static func nodes(_ text: String) throws -> [VPNNode] {
        var seen = Set<String>()
        return try text.split(whereSeparator: \.isNewline).enumerated().map { offset, line in
            guard var parts = URLComponents(string: String(line)), parts.scheme == "vless",
                  let host = parts.host, !host.isEmpty, let port = parts.port, (1...65535).contains(port),
                  let user = parts.user, UUID(uuidString: user) != nil else {
                throw VPNError.diagnostic("Invalid VLESS node on line \(offset + 1).", "The node is missing a valid UUID, hostname or port. Credentials and addresses were omitted from this report.")
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
    let defaultRulesFile: URL?
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/matveevVpn"), legacyDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VPN"), runtimeHashFile: URL = URL(fileURLWithPath: "/Library/Application Support/matveevVpn/control/config-sha256"), defaultRulesFile: URL? = Bundle.main.resourceURL?.appendingPathComponent(".payload/default-rules.json")) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.runtimeHashFile = runtimeHashFile
        self.defaultRulesFile = defaultRulesFile
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
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func freshState() throws -> SavedState {
        guard let defaultRulesFile, FileManager.default.fileExists(atPath: defaultRulesFile.path) else {
            return SavedState()
        }
        var state = SavedState()
        state.rules = try JSONDecoder().decode(RoutingRules.self, from: Data(contentsOf: defaultRulesFile))
        try state.rules.validate()
        return state
    }
    private func migrate() throws -> SavedState {
        let legacy = legacyDirectory
        let subscriptionFile = legacy.appendingPathComponent(".service/private/subscription.decoded")
        guard FileManager.default.fileExists(atPath: subscriptionFile.path) else { return try freshState() }
        var state = SavedState()
        state.subscription = try Subscription.decode(Data(contentsOf: subscriptionFile))
        let legacyRules = legacy.appendingPathComponent("routing-rules.json")
        if let rules = try? JSONDecoder().decode(RoutingRules.self, from: Data(contentsOf: legacyRules)) {
            state.rules = rules
        } else {
            state.rules = try freshState().rules
        }
        state.subscriptionURL = (try? String(contentsOf: legacy.appendingPathComponent(".service/private/subscription-url.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let index = Int((try String(contentsOf: legacy.appendingPathComponent(".service/current-server.txt"), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
        state.selectedNodeID = try Subscription.nodes(state.subscription).first { $0.index == index }?.id
        state.desiredOn = (try? String(contentsOfFile: "/Library/Application Support/matveevVpn/control/runtime-status", encoding: .utf8))?.hasPrefix("running") == true
        state.migratedFromV1 = true
        try save(state)
        return state
    }
}

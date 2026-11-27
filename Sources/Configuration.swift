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

enum AutomaticRoutingCatalog {
    static let services = [
        "youtube", "telegram", "whatsapp", "instagram", "facebook", "twitter", "discord",
        "openai", "anthropic", "google-gemini", "cursor", "github-copilot", "spotify"
    ]
    static let recommended = services

    static func title(for identifier: String) -> String {
        let known = [
            "youtube": "YouTube", "telegram": "Telegram", "whatsapp": "WhatsApp",
            "instagram": "Instagram", "facebook": "Facebook", "twitter": "X (Twitter)",
            "discord": "Discord",
            "openai": "ChatGPT", "anthropic": "Claude", "google-gemini": "Google Gemini",
            "cursor": "Cursor", "github-copilot": "GitHub Copilot", "spotify": "Spotify"
        ]
        return known[identifier] ?? identifier.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

struct RoutingRules: Codable, Equatable {
    var domains: [String] = []
    var mode: RoutingMode = .selective
    var automaticRoutingEnabled = true
    var automaticServices = AutomaticRoutingCatalog.recommended
    var adBlockingEnabled = false
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        mode = try c.decodeIfPresent(RoutingMode.self, forKey: .mode) ?? .selective
        automaticRoutingEnabled = try c.decodeIfPresent(Bool.self, forKey: .automaticRoutingEnabled) ?? true
        automaticServices = try c.decodeIfPresent([String].self, forKey: .automaticServices) ?? AutomaticRoutingCatalog.recommended
        adBlockingEnabled = try c.decodeIfPresent(Bool.self, forKey: .adBlockingEnabled) ?? false
    }
    func validate() throws {
        let unknownServices = Set(automaticServices).subtracting(AutomaticRoutingCatalog.services)
        guard unknownServices.isEmpty else {
            throw VPNError.message("The routing configuration contains an unsupported service preset.")
        }
        for (index, entry) in domains.enumerated() {
            let domain = entry.hasPrefix("*.") ? String(entry.dropFirst(2)) : entry
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            let valid = !domain.isEmpty && domain.count <= 253 && labels.allSatisfy {
                $0.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil
            }
            guard valid else { throw VPNError.message("Domain line \(index + 1): use example.com or *.example.com, without a URL or path.") }
        }
    }
}

enum VPNProtocol: String {
    case vless
    case hysteria2

    init?(scheme: String) {
        let scheme = scheme.lowercased()
        self.init(rawValue: scheme == "hy2" ? "hysteria2" : scheme)
    }

    var title: String { self == .vless ? "VLESS" : "Hysteria 2" }
}

struct VPNNode: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let index: Int
    let vpnProtocol: VPNProtocol
    let supportsSingBoxReality: Bool
}

enum Subscription {
    static func linkProtocol(_ link: String) -> VPNProtocol? {
        guard let separator = link.range(of: "://") else { return nil }
        return VPNProtocol(scheme: String(link[..<separator.lowerBound]))
    }

    static func decode(_ data: Data, allowHappJSON: Bool = false) throws -> String {
        guard data.count <= 4_194_304, let raw = String(data: data, encoding: .utf8) else {
            throw VPNError.message("The subscription is too large or is not text.")
        }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        let cleaned = raw.trimmingCharacters(in: trim)
        if allowHappJSON, let links = happLinks(cleaned), !links.isEmpty {
            let result = links.joined(separator: "\n") + "\n"
            _ = try nodes(result)
            return result
        }
        func supportedLines(in text: String) -> [String] {
            text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: trim) }
                .filter { linkProtocol($0) != nil }
        }
        var lines = supportedLines(in: cleaned)
        var base64Data: Data?
        if lines.isEmpty {
            let compact = cleaned.components(separatedBy: .whitespacesAndNewlines).joined()
            let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
            let base64 = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64Data = Data(base64Encoded: base64)
            lines = supportedLines(in: base64Data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
        guard !lines.isEmpty else {
            throw VPNError.diagnostic(
                "The subscription must contain VLESS or Hysteria 2 links.",
                "Received bytes: \(data.count)\nText encoding: UTF-8\nBase64 decoding: \(base64Data == nil ? "failed" : "succeeded")"
            )
        }
        let urlCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        let result = lines.map { line in
            linkProtocol(line) == .hysteria2 ? line.addingPercentEncoding(withAllowedCharacters: urlCharacters) ?? line : line
        }.joined(separator: "\n") + "\n"
        _ = try nodes(result)
        return result
    }

    private static func happLinks(_ text: String) -> [String]? {
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
            let supported = outbounds.filter {
                ["vless", "hysteria"].contains(($0["protocol"] as? String)?.lowercased() ?? "")
            }
            let vlessCount = supported.filter { ($0["protocol"] as? String)?.lowercased() == "vless" }.count
            var vlessIndex = 0
            for outbound in supported {
                if (outbound["protocol"] as? String)?.lowercased() == "hysteria" {
                    if let link = happHysteriaLink(outbound, remarks: remarks) { links.append(link) }
                    continue
                }
                vlessIndex += 1
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
                        let suffixNeeded = vlessCount > 1 || vnext.count > 1 || users.count > 1
                        let fallbackName = tag ?? "Happ VLESS"
                        let suffix = suffixNeeded ? " \(vlessIndex).\(serverIndex + 1)" : ""
                        components.fragment = (remarks?.isEmpty == false ? remarks! : fallbackName) + suffix
                        if let link = components.string { links.append(link) }
                    }
                }
            }
        }
        return links
    }

    private static func happHysteriaLink(_ outbound: [String: Any], remarks: String?) -> String? {
        guard let settings = outbound["settings"] as? [String: Any], integer(settings["version"]) == 2,
              let host = string(settings["address"]), !host.isEmpty,
              let port = integer(settings["port"]), (1...65535).contains(port),
              let stream = outbound["streamSettings"] as? [String: Any],
              stream["network"] as? String == "hysteria", stream["security"] as? String == "tls",
              let hysteria = stream["hysteriaSettings"] as? [String: Any],
              let auth = string(hysteria["auth"]), !auth.isEmpty else { return nil }

        var link = URLComponents()
        link.scheme = "hysteria2"
        link.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        link.port = port
        link.user = auth
        link.fragment = remarks.flatMap { $0.isEmpty ? nil : $0 } ?? string(outbound["tag"]) ?? "Hysteria 2"
        let tls = stream["tlsSettings"] as? [String: Any] ?? [:]
        var query: [URLQueryItem] = []
        append(string(tls["serverName"]), named: "sni", to: &query)
        append(string(tls["pinnedPeerCertSha256"]), named: "pinSHA256", to: &query)
        if tls["allowInsecure"] as? Bool == true { query.append(URLQueryItem(name: "insecure", value: "1")) }
        if !query.isEmpty { link.queryItems = query }
        return link.string
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
            let protocolKind = linkProtocol(String(line))
            guard let protocolKind, var parts = URLComponents(string: String(line)),
                  let host = parts.host, !host.isEmpty,
                  let port = parts.port ?? (protocolKind == .hysteria2 ? 443 : nil), (1...65535).contains(port),
                  let user = parts.user,
                  protocolKind == .vless ? UUID(uuidString: user) != nil : !user.isEmpty && ["", "/"].contains(parts.path) else {
                throw VPNError.diagnostic("Invalid \(protocolKind?.title ?? "VPN") node on line \(offset + 1).", "Check the credentials, hostname and port.")
            }
            let displayHost = protocolKind == .hysteria2 && host.hasPrefix("[") && host.hasSuffix("]")
                ? String(host.dropFirst().dropLast()) : host
            let name = parts.fragment.flatMap { $0.isEmpty ? nil : $0 } ?? "\(host):\(port)"
            var query: [String: String] = [:]
            for item in parts.queryItems ?? [] { query[item.name] = item.value ?? "" }
            parts.fragment = nil
            parts.host = host.lowercased()
            parts.scheme = protocolKind.rawValue
            if protocolKind == .hysteria2 {
                parts.port = port
                parts.path = ""
                if let pin = query["pinSHA256"],
                   pin.range(of: #"\A(?:[0-9a-fA-F]{64}|(?:[0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2})\z"#, options: .regularExpression) == nil {
                    throw VPNError.message("Invalid Hysteria 2 certificate fingerprint on line \(offset + 1).")
                }
            }
            parts.queryItems = parts.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            let id = SHA256.hash(data: Data((parts.string ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            let supportsSingBoxReality = protocolKind == .vless && query["security"] == "reality"
                && ["", "tcp", "raw"].contains(query["type"] ?? "")
                && ["", "none"].contains(query["encryption"] ?? "")
                && ["", "xtls-rprx-vision"].contains(query["flow"] ?? "")
                && (query["pqv"] ?? "").isEmpty
            return VPNNode(id: id, name: name, host: displayHost, port: port, index: offset + 1, vpnProtocol: protocolKind,
                           supportsSingBoxReality: supportsSingBoxReality)
        }.filter { seen.insert($0.id).inserted }
    }
}

struct SavedSubscription: Codable, Identifiable {
    let id: UUID
    let name: String?
    let url: String
    let content: String
    let selectedNodeID: String?
    let lastRefresh: Date?
    let happCompatibility: Bool?

    static func displayName(_ name: String?, url: String) -> String {
        if let name, !name.isEmpty { return name }
        return URLComponents(string: url)?.host ?? "Subscription"
    }

    var displayName: String { Self.displayName(name, url: url) }
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
    // Optional fields let existing single-subscription settings load unchanged.
    var subscriptionID: UUID?
    var subscriptionName: String?
    var subscriptionHappCompatibility: Bool?
    var otherSubscriptions: [SavedSubscription]?
    var preferSingBoxReality: Bool?

    var activeSubscriptionName: String { SavedSubscription.displayName(subscriptionName, url: subscriptionURL) }

    mutating func archiveActiveSubscription() {
        guard !subscription.isEmpty else { return }
        var saved = otherSubscriptions ?? []
        saved.append(SavedSubscription(id: subscriptionID ?? UUID(), name: subscriptionName,
                                       url: subscriptionURL, content: subscription,
                                       selectedNodeID: selectedNodeID, lastRefresh: lastRefresh,
                                       happCompatibility: subscriptionHappCompatibility))
        otherSubscriptions = saved
    }

    mutating func activateSubscription(_ profile: SavedSubscription?) {
        subscriptionID = profile?.id
        subscriptionName = profile?.name
        subscriptionHappCompatibility = profile?.happCompatibility
        subscriptionURL = profile?.url ?? ""
        subscription = profile?.content ?? ""
        selectedNodeID = profile?.selectedNodeID ?? (try? Subscription.nodes(subscription))?.first?.id
        lastRefresh = profile?.lastRefresh
        if let profile { otherSubscriptions?.removeAll { $0.id == profile.id } }
        else { desiredOn = false }
    }
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
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func freshState() throws -> SavedState { SavedState() }
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

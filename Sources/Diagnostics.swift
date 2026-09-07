import Foundation
import Network

enum NodeProbe {
    // TCP reachability, not VPN throughput or a guarantee of authentication.
    static func measure(_ node: VPNNode) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(node.host), port: NWEndpoint.Port(rawValue: UInt16(node.port))!, using: .tcp)
            let queue = DispatchQueue(label: "matveev.node-probe")
            let started = Date()
            var finished = false
            let finish: (String) -> Void = { result in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish("\(Int(Date().timeIntervalSince(started) * 1000)) ms")
                case .failed: finish("Unreachable")
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish("Timed out") }
        }
    }
}

enum RuleInspector {
    static func explain(domain: String, process: String, path: String, rules: RoutingRules) -> String {
        if process == "sing-box" { return "Direct — VPN engine loop prevention." }
        if rules.mode == .all { return "VPN — All Traffic mode (local/private destinations remain direct)." }
        let host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for value in rules.domains {
            let suffix = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
            if host == suffix || host.hasSuffix("." + suffix) { return "VPN — domain rule: \(value)" }
        }
        if rules.applications.contains(process) { return "VPN — process name: \(process)" }
        for pattern in rules.processPathRegexes {
            if let regex = try? NSRegularExpression(pattern: pattern), regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil {
                return "VPN — application path rule: \(pattern)"
            }
        }
        return "Direct — no matching rule. This predicts configured rules; it does not inspect a live connection or DNS cache."
    }
}

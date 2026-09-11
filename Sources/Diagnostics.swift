import Foundation

struct NodeProbeResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case reachable, unreachable, timedOut, noDirectInterface, cancelled }
    enum Method: Equatable, Sendable { case icmp, tcp }

    let outcome: Outcome
    let latencyMilliseconds: Int?
    let method: Method?

    var isReachable: Bool { outcome == .reachable }
    var displayText: String {
        switch outcome {
        case .reachable:
            let latency = latencyMilliseconds.map { "\($0) ms" } ?? "Reachable"
            return latency + (method == .icmp ? " · ping" : " · TCP")
        case .unreachable: return "Unreachable"
        case .timedOut: return "Timed out"
        case .noDirectInterface: return "No direct interface"
        case .cancelled: return "Cancelled"
        }
    }
}

enum NodeProbe {
    // Bind every probe to the physical interface so an active TUN cannot
    // report its local TCP acceptance time as the remote node's latency.
    static func measure(_ node: VPNNode, timeout: TimeInterval = 5) async -> NodeProbeResult {
        if Task.isCancelled { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        guard let interface = await physicalInterface() else {
            return NodeProbeResult(outcome: .noDirectInterface, latencyMilliseconds: nil, method: nil)
        }

        let pingTimeout = max(1, min(Int(timeout.rounded(.up)), 3))
        let ping = await Command.run("/sbin/ping", [
            "-n", "-q", "-b", interface, "-c", "3", "-i", "0.2",
            "-W", "700", "-t", String(pingTimeout), node.host
        ])
        if let average = averagePingMilliseconds(ping.output) {
            return NodeProbeResult(outcome: .reachable, latencyMilliseconds: average, method: .icmp)
        }
        if Task.isCancelled { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }

        let started = Date()
        let tcp = await Command.run("/usr/bin/nc", [
            "-4", "-b", interface, "-G", "3", "-w", "3", "-z", node.host, String(node.port)
        ])
        guard !Task.isCancelled else { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        if tcp.status == 0 {
            let elapsed = max(1, Int(Date().timeIntervalSince(started) * 1_000))
            return NodeProbeResult(outcome: .reachable, latencyMilliseconds: elapsed, method: .tcp)
        }
        return NodeProbeResult(outcome: ping.status == 0 ? .unreachable : .timedOut, latencyMilliseconds: nil, method: nil)
    }

    private static func physicalInterface() async -> String? {
        let result = await Command.run("/usr/sbin/scutil", ["--nwi"])
        guard result.status == 0 else { return nil }
        let candidates = result.output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 3, fields[1] == ":", fields[2] == "flags" else { return nil }
            let name = String(fields[0])
            guard !name.hasPrefix("utun"), name != "lo0", !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { return nil }
            return name
        }
        return candidates.first(where: { $0.hasPrefix("en") }) ?? candidates.first
    }

    static func averagePingMilliseconds(_ output: String) -> Int? {
        let pattern = #"=\s*[0-9.]+/([0-9.]+)/[0-9.]+/[0-9.]+\s*ms"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output),
              let average = Double(output[range]) else { return nil }
        return max(1, Int(average.rounded()))
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

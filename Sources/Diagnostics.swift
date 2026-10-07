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
            return latencyMilliseconds.map { "\($0) ms" } ?? "Reachable"
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
        let deadline = Date().addingTimeInterval(timeout)
        if Task.isCancelled { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        guard let interface = await physicalInterface(until: deadline) else {
            return NodeProbeResult(outcome: .noDirectInterface, latencyMilliseconds: nil, method: nil)
        }

        let pingTimeout = max(1, min(Int(timeout.rounded(.up)), 3))
        let ping = await Command.run("/sbin/ping", [
            "-n", "-q", "-b", interface, "-c", "3", "-i", "0.2",
            "-W", "700", "-t", String(pingTimeout), node.host
        ], timeout: deadline.timeIntervalSinceNow)
        if Date() >= deadline { return NodeProbeResult(outcome: .timedOut, latencyMilliseconds: nil, method: nil) }
        if let average = averagePingMilliseconds(ping.output) {
            return NodeProbeResult(outcome: .reachable, latencyMilliseconds: average, method: .icmp)
        }
        if Task.isCancelled { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }

        let started = Date()
        let tcp = await Command.run("/usr/bin/nc", [
            "-4", "-b", interface, "-G", "3", "-w", "3", "-z", node.host, String(node.port)
        ], timeout: deadline.timeIntervalSinceNow)
        guard !Task.isCancelled else { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        if tcp.status == 0 {
            let elapsed = max(1, Int(Date().timeIntervalSince(started) * 1_000))
            return NodeProbeResult(outcome: .reachable, latencyMilliseconds: elapsed, method: .tcp)
        }
        return NodeProbeResult(outcome: ping.status == 0 ? .unreachable : .timedOut, latencyMilliseconds: nil, method: nil)
    }

    private static func physicalInterface(until deadline: Date) async -> String? {
        let result = await Command.run("/usr/sbin/scutil", ["--nwi"], timeout: deadline.timeIntervalSinceNow)
        guard result.status == 0 else { return nil }
        return physicalInterface(in: result.output)
    }

    static func physicalInterface(in output: String) -> String? {
        let candidates = output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 3, fields[1] == ":", fields[2] == "flags", line.contains("(IPv4") else { return nil }
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

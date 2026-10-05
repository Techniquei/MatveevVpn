import Darwin
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
        guard Date() < deadline else { return NodeProbeResult(outcome: .timedOut, latencyMilliseconds: nil, method: nil) }

        // While connected, system DNS returns a FakeDNS address for the server
        // name. Ping and TCP to that address time out even though the tunnel works.
        // A short batch has no time for that lookup and must still finish at its deadline.
        let target = await probeTarget(node.host, until: deadline)
        if Task.isCancelled { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        guard Date() < deadline else { return NodeProbeResult(outcome: .timedOut, latencyMilliseconds: nil, method: nil) }

        let pingTimeout = min(2, max(1, Int(deadline.timeIntervalSinceNow.rounded(.down))))
        let ping = await Command.run("/sbin/ping", [
            "-n", "-q", "-b", interface, "-c", "2", "-i", "0.2",
            "-W", "700", "-t", String(pingTimeout), target
        ], timeout: deadline.timeIntervalSinceNow)
        if let average = averagePingMilliseconds(ping.output) {
            return NodeProbeResult(outcome: .reachable, latencyMilliseconds: average, method: .icmp)
        }
        if Task.isCancelled { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        guard Date() < deadline else { return NodeProbeResult(outcome: .timedOut, latencyMilliseconds: nil, method: nil) }

        let started = Date()
        let tcp = await Command.run("/usr/bin/nc", [
            "-4", "-b", interface, "-G", "3", "-w", "3", "-z", target, String(node.port)
        ], timeout: deadline.timeIntervalSinceNow)
        guard !Task.isCancelled else { return NodeProbeResult(outcome: .cancelled, latencyMilliseconds: nil, method: nil) }
        if tcp.status == 0 {
            let elapsed = max(1, Int(Date().timeIntervalSince(started) * 1_000))
            return NodeProbeResult(outcome: .reachable, latencyMilliseconds: elapsed, method: .tcp)
        }
        return NodeProbeResult(outcome: .timedOut, latencyMilliseconds: nil, method: nil)
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

    private static func probeTarget(_ host: String, until deadline: Date) async -> String {
        if ipv4Literal(host) { return host }
        let budget = deadline.timeIntervalSinceNow - 0.8
        guard budget >= 0.4 else { return host }
        return await numericTarget(host, timeout: min(1.5, budget))
    }

    static func numericTarget(_ host: String, timeout: TimeInterval) async -> String {
        if ipv4Literal(host) { return host }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let address = dohLookup(host, timeout: timeout).flatMap { ipv4Answers(in: $0).first }
                continuation.resume(returning: address ?? host)
            }
        }
    }

    // Ask 1.1.1.1 by address. A name lookup through the system resolver, or UDP
    // port 53 into the tunnel, is answered by FakeDNS.
    private static func dohLookup(_ host: String, timeout: TimeInterval) -> Data? {
        guard let query = dnsQuery(host) else { return nil }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matveev-dns-\(UUID().uuidString)")
        guard (try? query.write(to: file, options: [.atomic])) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sS", "--http1.1", "--max-time", String(format: "%.1f", max(0.1, timeout)),
            "--resolve", "cloudflare-dns.com:443:1.1.1.1",
            "-H", "content-type: application/dns-message",
            "-H", "accept: application/dns-message",
            "--data-binary", "@\(file.path)",
            "https://cloudflare-dns.com/dns-query"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let kill = DispatchWorkItem {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 0.5, execute: kill)
        defer { kill.cancel() }
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    static func ipv4Answers(in payload: Data) -> [String] {
        guard payload.count >= 12 else { return [] }
        let code = (Int(payload[2]) << 8 | Int(payload[3])) & 0x000F
        guard code == 0 else { return [] }
        let questions = Int(payload[4]) << 8 | Int(payload[5])
        let answers = Int(payload[6]) << 8 | Int(payload[7])
        var offset = 12
        for _ in 0..<questions {
            guard skipDNSName(&offset, payload), offset + 4 <= payload.count else { return [] }
            offset += 4
        }
        var found: [String] = []
        for _ in 0..<answers {
            guard skipDNSName(&offset, payload), offset + 10 <= payload.count else { return found }
            let type = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            let klass = Int(payload[offset + 2]) << 8 | Int(payload[offset + 3])
            let length = Int(payload[offset + 8]) << 8 | Int(payload[offset + 9])
            offset += 10
            guard offset + length <= payload.count else { return found }
            if type == 1 && klass == 1 && length == 4 {
                let ip = (0..<4).map { String(payload[offset + $0]) }.joined(separator: ".")
                if usableProbeAddress(ip) { found.append(ip) }
            }
            offset += length
        }
        return found
    }

    private static func dnsQuery(_ host: String) -> Data? {
        let labels = host.split(separator: ".")
        guard !labels.isEmpty, host.count <= 253, labels.allSatisfy({ !$0.isEmpty && $0.count < 64 }) else { return nil }
        var packet = Data([UInt8(arc4random() & 0xFF), UInt8(arc4random() & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in labels {
            packet.append(UInt8(label.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return packet
    }

    private static func skipDNSName(_ offset: inout Int, _ payload: Data) -> Bool {
        var cursor = offset
        var end = offset
        var hops = 0
        while cursor < payload.count && hops < 16 {
            let length = Int(payload[cursor])
            if length == 0 {
                if hops == 0 { end = cursor + 1 }
                offset = end
                return true
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < payload.count else { return false }
                if hops == 0 { end = cursor + 2 }
                cursor = ((length & 0x3F) << 8) | Int(payload[cursor + 1])
                hops += 1
                continue
            }
            guard length < 64, cursor + 1 + length <= payload.count else { return false }
            cursor += 1 + length
            if hops == 0 { end = cursor }
        }
        return false
    }

    private static func ipv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func usableProbeAddress(_ ip: String) -> Bool {
        guard ipv4Literal(ip) else { return false }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) { return false }
        if octets[0] == 0 || octets[0] == 127 || octets[0] >= 224 { return false }
        return true
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

import Foundation

@main struct DiagnosticsTests {
    static func main() throws {
        let output = """
        3 packets transmitted, 3 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 39.125/42.480/47.201/3.101 ms
        """
        precondition(NodeProbe.averagePingMilliseconds(output) == 42)
        let ping = NodeProbeResult(outcome: .reachable, latencyMilliseconds: 42, method: .icmp)
        let tcp = NodeProbeResult(outcome: .reachable, latencyMilliseconds: 51, method: .tcp)
        precondition(ping.displayText == "42 ms")
        precondition(tcp.displayText == "51 ms")
        let network = """
            REACH : flags 0x00000002 (Reachable)
            utun4 : flags 0x5 (IPv4,DNS)
            en0 : flags 0x5 (IPv4,DNS)
            """
        precondition(NodeProbe.physicalInterface(in: network) == "en0")
        precondition(NodeProbe.physicalInterface(in: "REACH : flags 0x00000002 (Reachable)") == nil)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let updateFile = root.appendingPathComponent("routing-updated-at")
        precondition(SystemService.routingUpdateDate(at: updateFile) == nil)
        try privateWrite(Data("1700000000\n".utf8), to: updateFile)
        precondition(SystemService.routingUpdateDate(at: updateFile) == Date(timeIntervalSince1970: 1700000000))
        for invalid in ["", "error", "nan", "inf", "0", "-1", "99999999999"] {
            try privateWrite(Data(invalid.utf8), to: updateFile)
            precondition(SystemService.routingUpdateDate(at: updateFile) == nil)
        }
        print("diagnostics: latency display and routing refresh dates passed")
    }
}

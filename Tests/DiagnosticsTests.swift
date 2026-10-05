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
        let synthetic = Data([
            0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x06, 0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x63, 0x6F, 0x6D, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 198, 18, 0, 2
        ])
        precondition(NodeProbe.ipv4Answers(in: synthetic).isEmpty, "FakeDNS answer must not be used as a node address")
        let real = Data([
            0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x06, 0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x63, 0x6F, 0x6D, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 203, 0, 113, 10
        ])
        precondition(NodeProbe.ipv4Answers(in: real) == ["203.0.113.10"])
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

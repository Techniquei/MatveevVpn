import Foundation

@main struct DiagnosticsTests {
    static func main() {
        let output = """
        3 packets transmitted, 3 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 39.125/42.480/47.201/3.101 ms
        """
        precondition(NodeProbe.averagePingMilliseconds(output) == 42)
        let ping = NodeProbeResult(outcome: .reachable, latencyMilliseconds: 42, method: .icmp)
        let tcp = NodeProbeResult(outcome: .reachable, latencyMilliseconds: 51, method: .tcp)
        precondition(ping.displayText == "42 ms · ping")
        precondition(tcp.displayText == "51 ms · TCP")
        let network = """
            REACH : flags 0x00000002 (Reachable)
            utun4 : flags 0x5 (IPv4,DNS)
            en0 : flags 0x5 (IPv4,DNS)
            """
        precondition(NodeProbe.physicalInterface(in: network) == "en0")
        precondition(NodeProbe.physicalInterface(in: "REACH : flags 0x00000002 (Reachable)") == nil)
        print("diagnostics: ping parsing and measurement labels passed")
    }
}

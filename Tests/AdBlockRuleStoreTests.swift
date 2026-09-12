import Foundation

@main
struct AdBlockRuleStoreTests {
    static func main() throws {
        let domains = (0..<20_000).map { "ad\($0).example.com" }
        let validData = Data(("# HaGeZi fixture\n" + domains.joined(separator: "\n") + "\n").utf8)
        precondition(AdBlockRuleStore.validDomains(in: validData)?.count == domains.count)

        let malformed = validData + Data("bad_domain.example\n".utf8)
        precondition(AdBlockRuleStore.validDomains(in: malformed) == nil)
        precondition(AdBlockRuleStore.validDomains(in: Data("ads.example\n".utf8)) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matveev-adblock-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let stage = root.appendingPathComponent("stage")
        let bundled = root.appendingPathComponent("bundled.txt")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try validData.write(to: bundled)
        try AdBlockRuleStore(directory: cache).materialize(in: stage, bundledFile: bundled)
        let stagedData = try Data(contentsOf: stage.appendingPathComponent(AdBlockRuleStore.stagedFileName))
        precondition(stagedData == validData)

        print("ad blocking: HaGeZi validation and bundled fallback passed")
    }
}

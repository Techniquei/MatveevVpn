import Foundation

@main struct ConfigurationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("VPN")
        let service = legacy.appendingPathComponent(".service")
        try FileManager.default.createDirectory(at: service.appendingPathComponent("private"), withIntermediateDirectories: true)
        let a = "vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp#First"
        let b = "vless://22222222-2222-2222-2222-222222222222@second.example.com:443?type=tcp&security=tls#Second"
        let text = a + "\n" + b + "\n"
        let nodes = try Subscription.nodes(text)
        let reordered = try Subscription.nodes(b + "\n" + a)
        precondition(nodes[0].id == reordered[1].id)
        let renamed = try Subscription.nodes(a.replacingOccurrences(of: "#First", with: "#Renamed").replacingOccurrences(of: "security=tls&type=tcp", with: "type=tcp&security=tls"))
        precondition(nodes[0].id == renamed[0].id)
        let decoded = try Subscription.decode(Data(Data(text.utf8).base64EncodedString().utf8))
        precondition(decoded == text)
        do { _ = try Subscription.decode(Data("garbage".utf8)); fatalError("Invalid subscription accepted") } catch {}
        try Data(text.utf8).write(to: service.appendingPathComponent("private/subscription.decoded"))
        try Data("2\n".utf8).write(to: service.appendingPathComponent("current-server.txt"))
        try Data("https://example.com/private-token\n".utf8).write(to: service.appendingPathComponent("private/subscription-url.txt"))
        try Data("{\"domains\":[\"example.com\"],\"applications\":[\"Example\"]}".utf8).write(to: legacy.appendingPathComponent("routing-rules.json"))
        let hashFile = root.appendingPathComponent("runtime-hash")
        let defaultsFile = root.appendingPathComponent("default-rules.json")
        let defaultRules = """
        {"domains":["youtube.com","cursor.com"],"applications":["Cursor"],"processPathRegexes":["^.*/Cursor\\\\.app/Contents/.*"],"mode":"selective"}
        """
        try Data(defaultRules.utf8).write(to: defaultsFile)
        let store = StateStore(directory: root.appendingPathComponent("settings"), legacyDirectory: legacy, runtimeHashFile: hashFile, defaultRulesFile: defaultsFile)
        var state = try store.load()
        precondition(state.migratedFromV1 && state.selectedNodeID == nodes[1].id)
        precondition(state.rules.domains == ["example.com"] && state.rules.processPathRegexes.isEmpty)
        state.rules.mode = .all
        try store.save(state)
        let saved = try store.load()
        precondition(saved.rules.mode == .all)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        var next = state; next.rules.domains = ["*.new.example.com"]
        try next.rules.validate()
        try store.stage(next, config: Data("new config".utf8))
        let pending = try JSONDecoder().decode(StateStore.Pending.self, from: Data(contentsOf: store.pendingFile))
        try Data(pending.configHash.utf8).write(to: hashFile)
        let recovered = try store.load()
        precondition(recovered.rules.domains == next.rules.domains, "Applied transaction must recover after app interruption")
        try store.stage(state, config: Data("rejected config".utf8))
        let unchanged = try store.load()
        precondition(unchanged.rules.domains == next.rules.domains, "Rejected transaction must not replace settings")
        var invalid = RoutingRules(); invalid.domains = ["https://example.com"]
        do { try invalid.validate(); fatalError("URL accepted as domain") } catch {}
        try store.save(try store.freshState())
        let reset = try store.load()
        precondition(reset.subscription.isEmpty, "Reset must not remigrate legacy settings")
        precondition(reset.rules.domains == ["youtube.com", "cursor.com"] && reset.rules.applications == ["Cursor"], "Reset must restore bundled defaults")
        precondition(reset.rules.processPathRegexes == ["^.*/Cursor\\.app/Contents/.*"], "Default helper path must be preserved")

        let freshStore = StateStore(directory: root.appendingPathComponent("fresh-settings"), legacyDirectory: root.appendingPathComponent("missing-legacy"), runtimeHashFile: hashFile, defaultRulesFile: defaultsFile)
        let fresh = try freshStore.load()
        precondition(fresh.rules == reset.rules, "Fresh installs must load bundled routing defaults")
        var customized = fresh
        customized.rules.domains = ["custom.example.com"]
        try freshStore.save(customized)
        let preserved = try freshStore.load()
        precondition(preserved.rules.domains == ["custom.example.com"], "Updates must not replace saved user rules")
        print("configuration: defaults, migration, persistence, transaction recovery, reset, node identity and decoding passed")
    }
}

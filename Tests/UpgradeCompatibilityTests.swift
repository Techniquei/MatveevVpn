import Foundation

// The synthetic fixture was encoded using Configuration.swift from tag v1.3.5.
@main struct UpgradeCompatibilityTests {
    static func main() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let original = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matveev-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in RoutingMode.allCases {
            for desiredOn in [false, true] {
                let directory = root.appendingPathComponent("\(mode.rawValue)-\(desiredOn)")
                let hashFile = directory.appendingPathComponent("active-hash")
                let store = StateStore(directory: directory, legacyDirectory: root.appendingPathComponent("absent"), runtimeHashFile: hashFile)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var old = original
                var rules = old["rules"] as! [String: Any]
                rules["mode"] = mode.rawValue
                old["rules"] = rules
                old["desiredOn"] = desiredOn
                try JSONSerialization.data(withJSONObject: old).write(to: store.file, options: .atomic)

                let loaded = try store.load()
                let nodes = try Subscription.nodes(loaded.subscription)
                precondition(loaded.schemaVersion == 2 && loaded.selectedNodeID == nodes[1].id)
                precondition(loaded.selectedNodeID == original["selectedNodeID"] as? String,
                             "The selected 1.3.5 server must keep its stable identity")
                precondition(loaded.subscriptionURL == original["subscriptionURL"] as? String)
                precondition(loaded.subscription == original["subscription"] as? String)
                precondition(loaded.desiredOn == desiredOn && loaded.rules.mode == mode)
                precondition(loaded.rules.domains == ["custom.example.com", "*.example.org"])
                precondition(loaded.rules.automaticRoutingEnabled && loaded.rules.automaticServices == ["youtube", "telegram", "openai"])
                precondition(loaded.rules.adBlockingEnabled && !loaded.migratedFromV1)
                precondition(loaded.lastRefresh == Date(timeIntervalSince1970: 1_700_000_000))
                try loaded.rules.validate()
                try store.save(loaded)
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as! [String: Any]
                let savedRules = saved["rules"] as! [String: Any]
                precondition(savedRules["applications"] == nil && savedRules["processPathRegexes"] == nil)
                let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as! NSNumber
                precondition(permissions.intValue == 0o600)

                try store.stage(loaded, config: Data("upgraded configuration".utf8))
                let pending = try JSONDecoder().decode(StateStore.Pending.self, from: Data(contentsOf: store.pendingFile))
                try Data(pending.configHash.utf8).write(to: hashFile, options: .atomic)
                let recovered = try store.load()
                precondition(recovered.rules == loaded.rules && recovered.selectedNodeID == loaded.selectedNodeID)
                precondition(recovered.desiredOn == desiredOn && recovered.subscription == loaded.subscription)
                precondition(!FileManager.default.fileExists(atPath: store.pendingFile.path))
            }
        }
        let customizedFixture = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
            .appendingPathComponent("settings-1.3.5-customized-default-domains.json")
        let customizedData = try Data(contentsOf: customizedFixture)
        let customizedJSON = try JSONSerialization.jsonObject(with: customizedData) as! [String: Any]
        let customizedRules = customizedJSON["rules"] as! [String: Any]
        let customizedDirectory = root.appendingPathComponent("customized-default-domains")
        try FileManager.default.createDirectory(at: customizedDirectory, withIntermediateDirectories: false)
        let customizedStore = StateStore(directory: customizedDirectory, legacyDirectory: root.appendingPathComponent("absent"))
        try customizedData.write(to: customizedStore.file)
        let customized = try customizedStore.load()
        precondition(customized.rules.domains == customizedRules["domains"] as! [String],
                     "A customized 1.3.5 list must not be erased because its domains match old bundled defaults")
        print("upgrade 1.3.5: settings, node identity, both modes/on-off states and journal recovery passed")
    }
}

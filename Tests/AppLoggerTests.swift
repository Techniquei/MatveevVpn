import Foundation

@main struct AppLoggerTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secret = "vless://test-credential@vpn.example.invalid:443?security=tls#Private"
        try Data("legacy diagnostic: \(secret)\n".utf8).write(to: file)
        let logger = AppLogger(file: file)
        let upgradedLog = try String(contentsOf: file, encoding: .utf8)
        precondition(!upgradedLog.contains("test-credential"), "Old logs must be sanitized on upgrade")
        logger.write("new diagnostic: \(secret.uppercased())\nRuntime core: sing-box")
        let sanitized = logger.contents()
        precondition(!sanitized.localizedCaseInsensitiveContains("test-credential"))
        precondition(!sanitized.localizedCaseInsensitiveContains("vless://"))
        precondition(sanitized.contains("Runtime core: sing-box"))

        for index in 0..<80 {
            logger.write("entry-\(index) " + String(repeating: "x", count: 50_000))
            let size = try Data(contentsOf: file).count
            precondition(size <= AppLogger.maximumBytes, "Log exceeded its hard size limit")
        }
        let text = logger.contents()
        precondition(text.contains("entry-79"), "Newest log entries must be retained")
        precondition(!text.contains("entry-0 "), "Old entries must be removed")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let date = Date(timeIntervalSince1970: 1_782_637_445)
        let name = AppLogger.exportFileName(at: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        precondition(name == "matveevVpn-2026-06-28_09-04-05.log", "Exported logs need a unique, sortable timestamp: \(name)")
        print("app logger: hard size limit, retention and export filename passed")
    }
}

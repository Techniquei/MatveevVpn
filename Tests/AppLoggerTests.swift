import Foundation

@main struct AppLoggerTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.log")
        let logger = AppLogger(file: file)

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
        print("app logger: hard size limit and retention passed")
    }
}

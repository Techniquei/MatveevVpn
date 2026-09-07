import Foundation
import CryptoKit

final class FakeTransport: ConfigurationTransport {
    var installed = true
    var currentVersion = SystemService.version
    var running = false
    var reject = false
    var active = "old"
    let hashFile: URL
    init(hashFile: URL) { self.hashFile = hashFile }
    func generate(_ state: SavedState, at stage: URL) async throws -> URL {
        let url = stage.appendingPathComponent("config")
        try Data(state.subscription.utf8).write(to: url)
        return url
    }
    func deploy(_ config: URL) async throws {
        if reject { throw VPNError.message("Rejected") }
        let data = try Data(contentsOf: config)
        active = String(decoding: data, as: UTF8.self)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try Data(hash.utf8).write(to: hashFile)
    }
    func install(_ config: URL, desiredOn: Bool) async throws { try await deploy(config); running = desiredOn }
    func send(_ action: String) async throws { running = action != "off" }
}

@main struct CoordinatorTests {
    static func main() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = root.appendingPathComponent("hash")
        let store = StateStore(directory: root.appendingPathComponent("state"), legacyDirectory: root.appendingPathComponent("none"), runtimeHashFile: hash)
        let transport = FakeTransport(hashFile: hash)
        let coordinator = ConfigurationCoordinator(store: store, transport: transport)
        var old = SavedState(); old.subscription = "old"
        try store.save(old)
        var next = old; next.subscription = "new"; next.desiredOn = true
        transport.reject = true
        do { _ = try await coordinator.apply(next, previous: old); fatalError("Rejection ignored") } catch {}
        let unchanged = try store.load()
        precondition(unchanged.subscription == "old" && transport.active == "old")
        transport.reject = false
        _ = try await coordinator.apply(next, previous: old)
        let applied = try store.load()
        precondition(applied.subscription == "new" && transport.running && transport.active == "new")
        precondition(!FileManager.default.fileExists(atPath: store.pendingFile.path))
        transport.installed = false; transport.reject = true
        do { _ = try await coordinator.apply(old, previous: next); fatalError("Installation cancellation ignored") } catch {}
        let retained = try store.load()
        precondition(retained.subscription == "new")
        print("coordinator: rejected deployment, successful commit and installation cancellation passed")
    }
}

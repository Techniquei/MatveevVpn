import Foundation
import CryptoKit

final class FakeTransport: ConfigurationTransport {
    var installed = true
    var currentVersion = SystemService.version
    var running = false
    var reject = false
    var rejectStart = false
    var active = "old"
    var requireStoppedInstall = false
    var installDesiredStates: [Bool] = []
    var actions: [String] = []
    var deadlines: [Date] = []
    var blockSettingsFile: URL?
    let hashFile: URL
    init(hashFile: URL) { self.hashFile = hashFile }
    func generate(_ state: SavedState, at stage: URL, until deadline: Date = Date().addingTimeInterval(15)) async throws -> URL {
        deadlines.append(deadline)
        let url = stage.appendingPathComponent("config")
        try Data(state.subscription.utf8).write(to: url)
        return url
    }
    func deploy(_ config: URL, until deadline: Date = Date().addingTimeInterval(15)) async throws {
        deadlines.append(deadline)
        if reject { throw VPNError.message("Rejected") }
        let data = try Data(contentsOf: config)
        if data.isEmpty && running { throw VPNError.message("The unconfigured component cannot run a tunnel") }
        active = String(decoding: data, as: UTF8.self)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try Data(hash.utf8).write(to: hashFile)
        if let file = blockSettingsFile {
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
            blockSettingsFile = nil
        }
    }
    func install(_ config: URL, desiredOn: Bool) async throws {
        installDesiredStates.append(desiredOn)
        if requireStoppedInstall && desiredOn { throw VPNError.message("Tunnel is not ready during installation") }
        try await deploy(config)
        installed = true
        running = desiredOn
    }
    func send(_ action: String, until deadline: Date = Date().addingTimeInterval(15)) async throws {
        deadlines.append(deadline)
        actions.append(action)
        if rejectStart && action == "on" { throw VPNError.message("Could not start") }
        running = action != "off"
    }
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
        transport.deadlines = []
        let deadline = Date().addingTimeInterval(15)
        _ = try await coordinator.apply(next, previous: old, until: deadline)
        precondition(transport.deadlines.count == 3 && transport.deadlines.allSatisfy { $0 == deadline })
        let calls = transport.deadlines.count
        do {
            _ = try await coordinator.apply(old, previous: next, until: Date().addingTimeInterval(-1))
            fatalError("An expired transaction was applied")
        } catch { precondition(error.localizedDescription.contains("15-second limit")) }
        precondition(transport.deadlines.count == calls && transport.active == "new")
        let applied = try store.load()
        precondition(applied.subscription == "new" && transport.running && transport.active == "new")
        precondition(!FileManager.default.fileExists(atPath: store.pendingFile.path))
        transport.installed = false; transport.reject = true
        do { _ = try await coordinator.apply(old, previous: next); fatalError("Installation cancellation ignored") } catch {}
        let retained = try store.load()
        precondition(retained.subscription == "new")
        transport.reject = false
        transport.installed = true
        transport.currentVersion = "12"
        _ = try await coordinator.apply(next, previous: next)
        precondition(transport.installDesiredStates.last == false && transport.actions.last == "on",
                     "Repairs must install stopped, commit settings, then connect")
        transport.rejectStart = true
        var repaired = next
        repaired.subscription = "saved-before-connect"
        do {
            _ = try await coordinator.apply(repaired, previous: next)
            fatalError("A failed post-repair connection was ignored")
        } catch { precondition(error.localizedDescription.contains("subscription was saved")) }
        let savedRepair = try store.load()
        precondition(savedRepair.subscription == "saved-before-connect")
        precondition(!FileManager.default.fileExists(atPath: store.pendingFile.path))
        transport.rejectStart = false

        let freshHash = root.appendingPathComponent("fresh-hash")
        let freshStore = StateStore(directory: root.appendingPathComponent("fresh-state"), legacyDirectory: root.appendingPathComponent("none"), runtimeHashFile: freshHash)
        let freshTransport = FakeTransport(hashFile: freshHash)
        freshTransport.installed = false
        freshTransport.requireStoppedInstall = true
        let freshCoordinator = ConfigurationCoordinator(store: freshStore, transport: freshTransport)
        var firstConnection = SavedState()
        firstConnection.subscription = "first"
        firstConnection.selectedNodeID = "first-node"
        firstConnection.desiredOn = true
        _ = try await freshCoordinator.apply(firstConnection, previous: SavedState())
        let installedState = try freshStore.load()
        precondition(freshTransport.installDesiredStates == [false] && freshTransport.actions == ["on"])
        precondition(freshTransport.running && installedState.subscription == "first")
        precondition(!FileManager.default.fileExists(atPath: freshStore.pendingFile.path))
        freshTransport.installed = false
        freshTransport.rejectStart = true
        var retryConnection = firstConnection
        retryConnection.subscription = "retry"
        do {
            _ = try await freshCoordinator.apply(retryConnection, previous: firstConnection)
            fatalError("A failed connection was reported as successful")
        } catch {
            precondition(error.localizedDescription.contains("subscription was saved"))
        }
        let savedRetry = try freshStore.load()
        precondition(savedRetry.subscription == "retry")
        precondition(freshTransport.installed && !FileManager.default.fileExists(atPath: freshStore.pendingFile.path))

        let provisionedHash = root.appendingPathComponent("provisioned-hash")
        let provisionedStore = StateStore(directory: root.appendingPathComponent("provisioned-state"), legacyDirectory: root.appendingPathComponent("none"), runtimeHashFile: provisionedHash)
        let provisionedTransport = FakeTransport(hashFile: provisionedHash)
        let provisionedCoordinator = ConfigurationCoordinator(store: provisionedStore, transport: provisionedTransport)
        try provisionedStore.save(SavedState())
        provisionedTransport.active = ""
        provisionedTransport.blockSettingsFile = provisionedStore.file
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: provisionedStore.file.path) }
        do {
            _ = try await provisionedCoordinator.apply(firstConnection, previous: SavedState())
            fatalError("Settings write failure ignored")
        } catch {}
        let restoredProvisioned = try provisionedStore.load()
        precondition(restoredProvisioned.subscription.isEmpty && !restoredProvisioned.desiredOn)
        precondition(provisionedTransport.active.isEmpty && !provisionedTransport.running && provisionedTransport.actions.last == "off",
                     "A failed first connection must restore the preinstalled, stopped configuration")
        precondition(!FileManager.default.fileExists(atPath: provisionedStore.pendingFile.path))
        print("coordinator: rejected deployment, commit, cancelled install and first-run install passed")
    }
}

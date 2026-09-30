import Foundation

protocol ConfigurationTransport {
    var installed: Bool { get }
    var currentVersion: String { get }
    var running: Bool { get }
    func generate(_ state: SavedState, at stage: URL) async throws -> URL
    func deploy(_ config: URL) async throws
    func install(_ config: URL, desiredOn: Bool) async throws
    func send(_ action: String) async throws
}

extension SystemService: ConfigurationTransport {}

/// Owns the commit boundary. Views cannot write the live settings or configuration.
actor ConfigurationCoordinator {
    private let store: StateStore
    private let transport: ConfigurationTransport
    private var applying = false

    init(store: StateStore = StateStore(), transport: ConfigurationTransport = SystemService()) {
        self.store = store
        self.transport = transport
    }

    func apply(_ next: SavedState, previous: SavedState) async throws -> SavedState {
        guard !applying else { throw VPNError.message("Another configuration change is still in progress.") }
        applying = true
        defer { applying = false }
        let stage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let config = try await transport.generate(next, at: stage)
        try store.stage(next, config: Data(contentsOf: config))

        let isFirstInstall = !transport.installed
        let requiresInstall = isFirstInstall || transport.currentVersion != SystemService.version
        if requiresInstall {
            // First installation must finish without waiting for the new tunnel to reach the network.
            try await transport.install(config, desiredOn: isFirstInstall ? false : next.desiredOn)
        } else {
            try await transport.deploy(config)
            if next.desiredOn != transport.running { try await transport.send(next.desiredOn ? "on" : "off") }
        }

        do { try store.save(next) }
        catch {
            if !previous.subscription.isEmpty || !isFirstInstall,
               let old = try? await transport.generate(previous, at: stage) {
                do {
                    // The preinstalled configuration has no TUN and must be restored stopped.
                    if !previous.desiredOn { try await transport.send("off") }
                    try await transport.deploy(old)
                    if previous.desiredOn { try await transport.send("on") }
                    try store.finishTransaction()
                } catch {
                    throw VPNError.message("The controller accepted the change, but saving and rollback failed. The recovery journal was retained; reopen the app to reconcile settings.")
                }
            }
            throw VPNError.message("Could not save settings. The previous configuration was restored where available.")
        }
        try store.finishTransaction()
        if isFirstInstall && next.desiredOn {
            do { try await transport.send("on") }
            catch {
                let details = (error as? VPNError)?.diagnosticDetails ?? error.localizedDescription
                throw VPNError.diagnostic("The component was installed and your subscription was saved, but the VPN could not connect. Try connecting again.", details)
            }
        }
        return next
    }
}

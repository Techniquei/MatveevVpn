import AppKit
import Sparkle

// Probe update information for a disposable bundle. Never download or install.
@MainActor private final class ChannelProbe: NSObject, SPUUpdaterDelegate {
    let policy: AppUpdater
    var found: String?
    var finished = false
    var failure: Error?

    init(policy: AppUpdater) { self.policy = policy }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        policy.allowedChannels(for: updater)
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found = item.versionString
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        failure = error
        finished = true
    }
}

@main struct SparkleChannelTests {
    @MainActor static func main() throws {
        precondition(CommandLine.arguments.count == 5, "Pass feed URL, expected stable build, expected beta build and public key file")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matveev-sparkle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "matveev-sparkle-policy-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = AppUpdater(defaults: defaults)
        for (index, enabled) in [false, true, false].enumerated() {
            policy.setBetaUpdates(enabled)
            let identifier = "com.matveev.channel-test." + UUID().uuidString
            defer { UserDefaults.standard.removePersistentDomain(forName: identifier) }
            let app = directory.appendingPathComponent("Probe\(index).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleName": "Channel Test",
                "CFBundlePackageType": "APPL", "CFBundleVersion": "1304",
                "CFBundleShortVersionString": "1.3.4", "SUFeedURL": CommandLine.arguments[1],
                "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
                "SUPublicEDKey": try String(contentsOfFile: CommandLine.arguments[4]).trimmingCharacters(in: .whitespacesAndNewlines),
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            let host = Bundle(url: app)!
            let probe = ChannelProbe(policy: policy)
            let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
            let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: probe)
            try updater.start()
            updater.checkForUpdateInformation()
            let deadline = Date(timeIntervalSinceNow: 20)
            while !probe.finished && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            precondition(probe.finished, "Update discovery must finish within its test bound")
            if let failure = probe.failure { throw failure }
            let expected = CommandLine.arguments[enabled ? 3 : 2]
            precondition(probe.found == expected, "Beta=\(enabled): expected \(expected), found \(probe.found ?? "none")")
            print("Sparkle probe: beta=\(enabled), offered build \(expected)")
        }
    }
}

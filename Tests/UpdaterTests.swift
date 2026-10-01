import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

@main struct UpdaterTests {
    @MainActor static func main() {
        let suite = "matveev-updater-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = AppUpdater(defaults: defaults)
        precondition(!updater.betaUpdatesEnabled)
        precondition(updater.updateChannels.isEmpty, "New and existing installations must stay on stable by default")
        updater.setBetaUpdates(true)
        precondition(updater.updateChannels == ["beta"], "Opting in must permit the beta channel; Sparkle also includes stable")
        precondition(defaults.bool(forKey: "betaUpdates"))
        let reopened = AppUpdater(defaults: defaults)
        precondition(reopened.betaUpdatesEnabled && reopened.updateChannels == ["beta"], "Opt-in must survive relaunch")
        reopened.setBetaUpdates(false)
        precondition(reopened.updateChannels.isEmpty)
        precondition(!AppUpdater(defaults: defaults).betaUpdatesEnabled, "Opting out must persist")
        #if canImport(Sparkle)
        var terminationRequests = 0
        let relaunchPolicy = AppUpdater(defaults: defaults, terminateApplication: { terminationRequests += 1 })
        let sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil),
                                 delegate: relaunchPolicy)
        let item = SUAppcastItem(dictionary: [
            "sparkle:version": "2",
            "enclosure": ["url": "https://example.invalid/update.zip", "length": "1"]
        ])!
        relaunchPolicy.updater(sparkle, willInstallUpdate: item)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(terminationRequests == 0, "Preparation or install-on-quit must not terminate the app")
        precondition(relaunchPolicy.updaterShouldRelaunchApplication(sparkle))
        relaunchPolicy.updaterWillRelaunchApplication(sparkle)
        precondition(terminationRequests == 0, "Sparkle must send its relaunch instruction before termination")
        let deadline = Date(timeIntervalSinceNow: 1)
        while terminationRequests == 0 && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        precondition(terminationRequests == 1, "The old app must quit without an external quit event")
        print("updater: deferred termination after Sparkle relaunch callback passed")
        #endif
        print("updater: stable default, beta opt-in, relaunch and opt-out passed")
    }
}

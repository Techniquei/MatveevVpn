import Foundation

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
        print("updater: stable default, beta opt-in, relaunch and opt-out passed")
    }
}

import Foundation
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var betaUpdatesEnabled: Bool
    private let defaults: UserDefaults
    var updateChannels: Set<String> { betaUpdatesEnabled ? ["beta"] : [] }
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    var available: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        betaUpdatesEnabled = defaults.bool(forKey: "betaUpdates")
        super.init()
        #if canImport(Sparkle)
        if available {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        #endif
    }
    func setBetaUpdates(_ enabled: Bool) {
        guard enabled != betaUpdatesEnabled else { return }
        betaUpdatesEnabled = enabled
        defaults.set(enabled, forKey: "betaUpdates")
        #if canImport(Sparkle)
        controller?.updater.resetUpdateCycleAfterShortDelay()
        #endif
    }
    func check() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannels
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        AppLogger.shared.write("Sparkle prepared update \(item.displayVersionString); waiting for its managed install and relaunch")
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        AppLogger.shared.write("Sparkle is relaunching the updated application")
    }
}
#endif

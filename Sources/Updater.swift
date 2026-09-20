import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    var available: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil }
    private override init() {
        super.init()
        #if canImport(Sparkle)
        if available {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
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

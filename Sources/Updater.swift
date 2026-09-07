import Foundation
import AppKit
import Darwin
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
        // Sparkle has already extracted and validated the update at this point.
        // Closing the app releases its bundle so the installer can replace it.
        NSApplication.shared.terminate(nil)

        // A modal window or an AppKit termination edge case must not leave the
        // old process alive while Sparkle is waiting to install the update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}
#endif

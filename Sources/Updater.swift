import Foundation
import Combine
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var betaUpdatesEnabled: Bool
    private let defaults: UserDefaults
    private let terminateApplication: @MainActor () -> Void
    var updateChannels: Set<String> { betaUpdatesEnabled ? ["beta"] : [] }
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    var available: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil }
    init(defaults: UserDefaults = .standard,
         terminateApplication: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.defaults = defaults
        self.terminateApplication = terminateApplication
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
        AppLogger.shared.write("Update check requested; channel=\(betaUpdatesEnabled ? "stable+beta" : "stable")")
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    static func errorDetails(_ error: Error) -> String {
        var details: [String] = []
        var current: NSError? = error as NSError
        // Bound the chain in case a framework supplies recursive error details.
        for _ in 0..<8 {
            guard let next = current else { break }
            var description = "\(next.domain) (\(next.code)): \(next.localizedDescription)"
            if let reason = next.localizedFailureReason { description += "; reason=\(reason)" }
            if let suggestion = next.localizedRecoverySuggestion { description += "; recovery=\(suggestion)" }
            details.append(description)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return details.joined(separator: " <- ")
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        AppLogger.shared.write("Update check aborted: \(Self.errorDetails(error))")
    }

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
        // Sparkle 2.9.6 sends its install-and-relaunch instruction after this
        // callback returns. Quit on the next main-queue turn so that instruction
        // reaches the installer before the old process exits. This also avoids
        // depending on the installer's external quit event being delivered.
        DispatchQueue.main.async { self.terminateApplication() }
    }
}
#endif

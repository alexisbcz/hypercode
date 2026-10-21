import Sparkle
import SwiftUI

/// Keeps the app up to date with Sparkle, from the appcast attached to the latest GitHub release.
///
/// Sparkle checks once a day by default and asks before installing; Settings can let it download
/// and install in the background instead. Debug builds never check, so `make run` doesn't offer
/// to replace itself with a release.
@Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is running, or in Debug builds.
    private(set) var canCheck = false
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    var installsAutomatically: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = installsAutomatically }
    }

    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        lastChecked = updater.lastUpdateCheckDate
        guard Self.isEnabled else { return }
        canCheck = updater.canCheckForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastChecked = updater.lastUpdateCheckDate }
            },
        ]
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

import AppKit
import Combine
import Sparkle

/// Sparkle over-the-air updates. The feed URL and EdDSA public key live in
/// `Blablabla-Info.plist`; `scripts/release.sh` publishes signed builds.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false

    /// Optional feed override for testing a release before publishing it
    /// (`defaults write ~/Library/Preferences/gpogrebnyak.Blablabla blabla.updateFeedURL <url>`).
    /// Safe to honor: Sparkle still refuses archives not signed with our EdDSA key.
    nonisolated static let feedOverrideKey = "blabla.updateFeedURL"

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: Self.feedOverrideKey)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// We're a menu-bar app with no Dock icon, so a scheduled update alert
    /// would open behind whatever the user is doing. Opting in lets us bring
    /// it to the front ourselves.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate() }
    }
}

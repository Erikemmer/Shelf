import Sparkle

/// Wraps Sparkle's standard updater: checks automatically (`SUEnableAutomaticChecks`
/// in `Info.plist`), never installs without asking (`SUAutomaticallyUpdate` is
/// false there), and remembers the version a background check found so the
/// welcome screen can say so.
@MainActor
@Observable
final class UpdaterModel: NSObject, SPUUpdaterDelegate {
    /// `lazy`, not set in `init`: the delegate can only be handed to
    /// `SPUStandardUpdaterController` at construction time (it has no
    /// settable `delegate` property afterwards), and that construction needs
    /// `self` – which does not exist yet during `NSObject`'s own `init`.
    /// Deferring to first access is what lets `self` be used safely here.
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    /// Set once a background or manual check finds something newer; cleared
    /// only by relaunching (an installed update starts at nil again).
    private(set) var availableUpdateVersion: String?

    override init() {
        super.init()
        _ = controller  // starts the updater now rather than on the first check
    }

    /// `Shelf ▸ Check for Updates…` – shows Sparkle's own progress UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
    }

    /// `SHELF_APPCAST_URL` redirects the feed – Debug builds only, so a stray
    /// environment variable can never point a Release build (what Erik
    /// actually runs) at a test channel.
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
            return ProcessInfo.processInfo.environment["SHELF_APPCAST_URL"]
        #else
            return nil
        #endif
    }
}

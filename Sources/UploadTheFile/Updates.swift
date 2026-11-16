import AppKit
import Sparkle

/// Automatic updates with Sparkle: a check about once a day, Sparkle's own window for a new
/// version, and the "Check for Updates…" menu item. The feed address and the public key that
/// signed updates must match are in Info.plist (SUFeedURL, SUPublicEDKey).
///
/// Created by the app delegate at launch, never in the `--render-snapshots` path, so drawing
/// snapshots does not start an updater or touch the network.
@MainActor
final class AppUpdates: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Without an app bundle that names its feed (a `swift run` binary), Sparkle can only
        // report an error, so it is not started at all.
        guard Self.hasFeed else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    private static var hasFeed: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    /// The menu item that starts a check the person asked for. The controller is its target, so
    /// AppKit enables the item only while `canCheckForUpdates` is true (no check running). Without
    /// an updater the item has no action and stays disabled.
    func checkForUpdatesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        if let controller {
            item.target = controller
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        }
        return item
    }

    // MARK: SPUStandardUserDriverDelegate

    /// The app has no Dock icon and no window, so Sparkle's default for a scheduled update (show
    /// it behind every other app) would leave it unseen. Declaring gentle-reminder support is
    /// what Sparkle asks of such apps; the alert is then brought to the front below.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A new version is about to be shown (scheduled or asked for): make this app the active one so
    /// the window is in front.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate { AppActivation.bringToFront() }
    }

    /// The same for Sparkle's modal alerts ("You're up to date", an error).
    func standardUserDriverWillShowModalAlert() {
        AppActivation.bringToFront()
    }
}

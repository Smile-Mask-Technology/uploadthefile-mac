import AppKit
import Observation
import Sparkle
import UploadTheFileCore

/// Automatic updates with Sparkle: a check about once a day, Sparkle's own window for a new
/// version, and the "Check for Updates…" menu item. The feed address and the public key that
/// signed updates must match are in Info.plist (SUFeedURL, SUPublicEDKey).
///
/// Created by the app delegate at launch, never in the `--render-snapshots` path, so drawing
/// snapshots does not start an updater or touch the network.
@MainActor
final class AppUpdates: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private let model: AppModel
    /// The version Sparkle found on a scheduled check and did not show (see below).
    private var pending = PendingUpdate()
    /// Sparkle's relaunch, kept while a publish or replace is running.
    private var relaunchHold = RelaunchHold()

    init(model: AppModel = .shared) {
        self.model = model
        super.init()
        // Without an app bundle that names its feed (a `swift run` binary), Sparkle can only
        // report an error, so it is not started at all.
        guard Self.hasFeed else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        Notifier.onCheckForUpdates = { [weak self] in self?.controller?.checkForUpdates(nil) }
        trackBusy()
    }

    private static var hasFeed: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    /// The menu item that starts a check the person asked for; while a scheduled update waits it
    /// names that version, and the same action brings Sparkle's window for it forward. The
    /// controller is its target, so AppKit enables the item only while `canCheckForUpdates` is
    /// true (no check running). Without an updater the item has no action and stays disabled.
    func checkForUpdatesItem() -> NSMenuItem {
        let item = NSMenuItem(title: pending.menuTitle, action: nil, keyEquivalent: "")
        if let controller {
            item.target = controller
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        }
        return item
    }

    // MARK: SPUUpdaterDelegate

    /// The feed is the one in Info.plist. Without this, a `SUFeedURL` written to the app's user
    /// defaults would take precedence and point the updater somewhere else.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// "Install and Relaunch" while a publish or replace is running waits for it to end instead
    /// of quitting the app in the middle of an upload.
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        relaunchHold.request(isBusy: model.session.isActive) { installHandler() }
    }

    /// Runs the held relaunch when the publish ends.
    private func trackBusy() {
        withObservationTracking {
            _ = model.session.isActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.relaunchHold.busyChanged(isBusy: self.model.session.isActive)
                self.trackBusy()
            }
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// The app has no Dock icon and no window, and a scheduled update window that came to the
    /// front would take the keyboard focus from whatever the person is doing. Declaring
    /// gentle-reminder support lets the app decide how a scheduled update is announced.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when it is in immediate focus (right after
    /// launch). Otherwise it is announced by the menu item and a notification, below.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// An update Sparkle does not show: remember it for the menu item and post one notification
    /// (clicking it runs the same check, which brings Sparkle's window to the front). Updates
    /// Sparkle shows, scheduled or asked for, are activated by Sparkle when they should be.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        guard pending.record(version: version) else { return }
        let message = PendingUpdate.notification(version: version)
        Task {
            await Notifier.post(
                title: message.title, body: message.body,
                userInfo: [PendingUpdate.notificationActionKey: PendingUpdate.notificationActionValue])
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        pending.clear()
    }
}

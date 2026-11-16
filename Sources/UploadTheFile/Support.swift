import AppKit
import Foundation
import UserNotifications

/// Notifications for finished links. Permission is asked once, on the first link,
/// and a notification is only posted when it was granted.
@MainActor
enum Notifier {
    /// The notification center only works inside a real app bundle.
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func configure(delegate: UNUserNotificationCenterDelegate) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Asks for permission if the user was never asked.
    static func requestIfNeeded() async {
        guard isAvailable else { return }
        guard await authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in
                continuation.resume()
            }
        }
    }

    static func post(title: String, body: String) async {
        guard isAvailable else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in continuation.resume() }
        }
    }

    /// The completion-handler APIs, so that only plain values (the status, nothing) cross the
    /// concurrency boundary. With the async APIs, Swift 6.1 (Xcode 16, GitHub's macos-15 runner)
    /// refuses to send the non-Sendable `UNUserNotificationCenter` and `UNNotificationSettings`
    /// across an `await`, even though newer compilers accept it.
    private static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

/// Shows notifications even while the app is the active one (it is always an accessory app).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// Modal questions that are better as real alerts than as in-popover sheets: the menu bar window
/// closes when it loses focus, an alert does not.
@MainActor
enum Alerts {
    static func confirmDelete(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "The file and its link are removed from your account. People who have the link can no longer open it. This can't be undone."
        let remove = alert.addButton(withTitle: "Delete")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        AppActivation.bringToFront()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        AppActivation.bringToFront()
        alert.runModal()
    }
}

/// Brings this menu bar app to the front before it shows a window, popover or alert.
@MainActor
enum AppActivation {
    /// `NSApp.activate()` (the macOS 14 cooperative request) is NOT used: in this accessory app
    /// the request was still pending when the first menu opened in the popover (the row's "…"),
    /// and its arrival closed that menu about 250 ms later; every later menu stayed open.
    /// Measured with a minimal popover app, the cursor over the button: the cooperative call
    /// closed the first menu every run, `activate(ignoringOtherApps:)` and no activation at all
    /// never did. The older call activates at once, so nothing lands while a menu is open.
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

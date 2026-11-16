import Foundation

/// A new version that Sparkle found on a scheduled check but did not put in front of the person
/// (the app would have taken the keyboard focus from whatever they were doing). The menu item
/// says so until the update session ends.
public struct PendingUpdate: Equatable, Sendable {
    public private(set) var version: String?

    public init() {}

    /// The menu item that starts a check the person asks for.
    public static let checkTitle = "Check for Updates…"

    /// The value under `userInfo[notificationActionKey]` of the notification this type produces;
    /// clicking it runs the same check as the menu item.
    public static let notificationActionKey = "action"
    public static let notificationActionValue = "checkForUpdates"

    public var menuTitle: String {
        guard let version else { return Self.checkTitle }
        return "Update to \(version)…"
    }

    /// Remembers the version. True when it is not the one already remembered, so a notification
    /// goes out once per version and not at every scheduled check.
    @discardableResult
    public mutating func record(version: String) -> Bool {
        guard self.version != version else { return false }
        self.version = version
        return true
    }

    public mutating func clear() {
        version = nil
    }

    public static func notification(version: String) -> (title: String, body: String) {
        ("Update available", "Upload the File \(version) is available.")
    }
}

/// Holds Sparkle's relaunch while a publish or replace is running, so "Install and Relaunch" in
/// the update window does not quit the app in the middle of an upload.
@MainActor
public struct RelaunchHold {
    private var held: (@MainActor () -> Void)?

    public init() {}

    public var isHolding: Bool { held != nil }

    /// True when `relaunch` is kept for later (Sparkle then waits for it); false when the caller
    /// should relaunch now and `relaunch` is never run.
    public mutating func request(isBusy: Bool, relaunch: @escaping @MainActor () -> Void) -> Bool {
        guard isBusy else { return false }
        held = relaunch
        return true
    }

    /// Call whenever the busy state may have changed; runs the held relaunch once work has ended.
    public mutating func busyChanged(isBusy: Bool) {
        guard !isBusy, let relaunch = held else { return }
        held = nil
        relaunch()
    }
}

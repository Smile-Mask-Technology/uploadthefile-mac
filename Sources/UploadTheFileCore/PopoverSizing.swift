import Foundation

/// When and how the menu bar popover changes size.
///
/// The popover must never chase SwiftUI's ideal size on its own: the window frame and the SwiftUI
/// layout would feed each other (a frame change re-lays out the content, a content change resizes
/// the window), and while files are being dropped the content changes on every frame. AppKit stops
/// that loop by raising "The window has been marked as needing another Update Constraints in
/// Window pass ..." and the app crashes. Instead the popover has a fixed width, the content reports
/// the height it needs *for that width* (which does not depend on the window), and this type decides
/// whether the window follows: only for a real change, in whole points, inside limits, and never
/// while a drag is over the app.
public enum PopoverSizing {
    /// The popover's width, and the width the content is laid out at.
    public static let width: Double = 340
    /// Shortest popover: the signed-out and empty states are never smaller than this.
    public static let minHeight: Double = 120
    /// Tallest popover when the screen allows it; the page list scrolls beyond this.
    public static let maxHeight: Double = 640
    /// Changes of this many points or fewer are ignored (layout rounding must not resize the window).
    public static let changeThreshold: Double = 1
    /// How long the content has to stay the same height before the window follows, in milliseconds.
    public static let settleMilliseconds = 100

    /// The height the popover should be, or `nil` to leave it as it is.
    ///
    /// - Parameters:
    ///   - current: The popover's height now (`nil` before the first one).
    ///   - measured: The height the content asked for at ``width``.
    ///   - isDragActive: A drag is over the popover or the menu bar icon.
    ///   - maxHeight: The most the screen allows (at most ``PopoverSizing/maxHeight``).
    public static func nextHeight(
        current: Double?, measured: Double, isDragActive: Bool, maxHeight: Double = PopoverSizing.maxHeight
    ) -> Double? {
        guard !isDragActive, measured.isFinite, measured > 0 else { return nil }
        let upper = max(minHeight, min(maxHeight, PopoverSizing.maxHeight))
        let wanted = min(max(measured.rounded(.up), minHeight), upper)
        if let current, abs(wanted - current) <= changeThreshold { return nil }
        return wanted
    }
}

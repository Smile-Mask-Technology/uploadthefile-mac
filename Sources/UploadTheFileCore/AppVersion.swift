import Foundation
import UptfKit

/// The version shown in the app (the popover header and the menu bar icon's menu): the running
/// bundle's own CFBundleShortVersionString, so it is the version actually installed. A binary
/// outside an app bundle (`swift run`) has none and shows the package's version.
public enum AppVersion {
    public static func display(infoDictionary: [String: Any]?) -> String {
        let short = (infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let short, !short.isEmpty else { return UptfKitVersion.value }
        return short
    }

    /// The disabled line in the menu bar icon's menu.
    public static func menuTitle(infoDictionary: [String: Any]?) -> String {
        "Version \(display(infoDictionary: infoDictionary))"
    }

    /// The running app's version.
    public static var current: String { display(infoDictionary: Bundle.main.infoDictionary) }
}

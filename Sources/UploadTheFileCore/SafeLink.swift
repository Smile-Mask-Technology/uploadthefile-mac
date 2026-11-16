import Foundation

/// Which link strings the app opens or shows as a link. Links come from the website's answers and
/// from the local history file; a server we do not control (or a history file someone edited) can
/// put anything in them, such as `file:`, `smb:`, `ssh:` or an app's own scheme, and a click would
/// hand it to the system. Only web links are opened.
public enum SafeLink {
    /// The URL to open for `link`, or nil when it must not be opened. `https` always passes; plain
    /// `http` only when the site the app is signed in to is itself plain `http` (local development).
    public static func url(from link: String, site: URL?) -> URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty
        else { return nil }
        switch scheme {
        case "https":
            return url
        case "http":
            return site?.scheme?.lowercased() == "http" ? url : nil
        default:
            return nil
        }
    }

    public static func isOpenable(_ link: String, site: URL?) -> Bool {
        url(from: link, site: site) != nil
    }
}

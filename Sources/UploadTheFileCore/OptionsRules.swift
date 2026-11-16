import Foundation

/// Rules for the Options window's fields, checked as the user types so mistakes show up early.
public enum OptionsRules {
    public static let passwordLengths = 6...72
    public static let nameLengths = 3...32
    public static let maxGateMessageLength = 200

    /// Why this password pair cannot be saved, or nil when it can.
    public static func passwordProblem(_ password: String, confirmation: String) -> String? {
        if password.isEmpty { return nil }  // nothing typed yet: no complaint, the button stays off
        if !passwordLengths.contains(password.count) { return "Use 6 to 72 characters." }
        if !confirmation.isEmpty && confirmation != password { return "The two passwords don't match." }
        return nil
    }

    public static func canSavePassword(_ password: String, confirmation: String) -> Bool {
        passwordLengths.contains(password.count) && password == confirmation
    }

    /// Why this name cannot be used for a link, or nil. Anything else the server decides.
    public static func nameProblem(_ proposed: String) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        if !nameLengths.contains(name.count) { return "Use 3 to 32 characters." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        if !name.allSatisfy({ allowed.contains($0) }) { return "Use lowercase letters, numbers and hyphens." }
        return nil
    }

    public static func canRename(from current: String, to proposed: String) -> Bool {
        let name = proposed.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name != current && nameProblem(name) == nil
    }

    /// The expiry to send: nil means "never" (the API gets an explicit null).
    public static func expiryToSend(neverExpires: Bool, date: Date) -> Date? {
        neverExpires ? nil : date
    }

    public static func expiryProblem(neverExpires: Bool, date: Date, now: Date = Date()) -> String? {
        if neverExpires { return nil }
        return date > now ? nil : "Pick a time in the future."
    }

    public static func clampedGateMessage(_ message: String) -> String {
        String(message.prefix(maxGateMessageLength))
    }

    /// The plans page of a site: `<origin>/pricing`, whatever path the origin string carries.
    public static func pricingURL(origin: URL) -> URL {
        siteURL(origin: origin, path: "/pricing")
    }

    /// Where people manage everything they published on the website (the dashboard's Pages
    /// list): `<origin>/dashboard`. Signed out, the website asks them to sign in first.
    public static func dashboardURL(origin: URL) -> URL {
        siteURL(origin: origin, path: "/dashboard")
    }

    /// The line under the sign-in button, as Markdown with both links (the website's own
    /// sign-in wording): "By continuing, you agree to our Terms and Privacy Policy."
    public static func signInNotice(origin: URL) -> String {
        let terms = siteURL(origin: origin, path: "/terms").absoluteString
        let privacy = siteURL(origin: origin, path: "/privacy").absoluteString
        return "By continuing, you agree to our [Terms](\(terms)) and [Privacy Policy](\(privacy))."
    }

    private static func siteURL(origin: URL, path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = origin.scheme
        parts.host = origin.host
        parts.port = origin.port
        parts.path = path
        return parts.url ?? origin.appendingPathComponent(String(path.dropFirst()))
    }
}

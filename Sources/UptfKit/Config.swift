public import Foundation

/// Where the app talks to: the site origin and the URLs derived from it.
public struct UptfConfig: Sendable, Hashable {
    public static let defaultOrigin = "https://uploadthefile.com"
    /// Environment variable that overrides the site origin (for local dev servers).
    public static let environmentKey = "UPTF_SITE"

    /// Site origin without a trailing slash, e.g. `https://uploadthefile.com`.
    public let origin: String

    /// Creates a config for `origin`. Only `https` is accepted, except `http` on loopback hosts
    /// (local development), so tokens never travel over plain HTTP to a remote host.
    public init(origin: String = UptfConfig.defaultOrigin) throws {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
            let scheme = parts.scheme?.lowercased(),
            let host = parts.host?.lowercased(), !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/"
        else {
            throw UptfError.unexpected("“\(origin)” isn't a valid site address. Expected something like https://uploadthefile.com")
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw UptfError.unexpected("The site address must start with https (http is only allowed for localhost): \(origin)")
        }
        parts.scheme = scheme
        parts.host = host
        parts.path = ""
        guard let normalized = parts.string else {
            throw UptfError.unexpected("“\(origin)” isn't a valid site address.")
        }
        self.origin = normalized
    }

    /// The configuration for this process: `UPTF_SITE` if set, otherwise production.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> UptfConfig {
        if let override = environment[environmentKey], !override.isEmpty {
            return try UptfConfig(origin: override)
        }
        return try UptfConfig()
    }

    public var originURL: URL { URL(string: origin)! }

    /// `<origin>/api/v1`, the base of the REST API.
    public var apiBase: URL { URL(string: origin + "/api/v1")! }

    /// The OAuth `resource` the app asks tokens for. Must be exactly `<origin>/api/v1`.
    public var appResourceURL: URL { apiBase }

    public var registrationEndpoint: URL { URL(string: origin + "/api/oauth/register")! }
    public var tokenEndpoint: URL { URL(string: origin + "/api/oauth/token")! }
    public var revocationEndpoint: URL { URL(string: origin + "/api/oauth/revoke")! }
    public var authorizeEndpoint: URL { URL(string: origin + "/oauth/authorize")! }

    /// Scopes the app requests.
    public static let scope = "sites:read sites:write"
    /// Name shown on the consent screen.
    public static let clientName = "Upload the File for Mac"
}

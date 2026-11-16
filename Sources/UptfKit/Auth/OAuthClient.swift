public import Foundation

/// Minimal async HTTP: `URLSession` in production, a fake in tests.
public protocol HTTPLoader: Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPLoader {
    public func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UptfError.unexpected("Upload the File sent back something we couldn't read.")
        }
        return (data, http)
    }
}

extension URLSession {
    /// A session with no cache or cookie storage and sensible timeouts, for OAuth and API calls.
    public static func uptfDefault() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

/// Token endpoint response (RFC 6749 §5.1).
public struct OAuthTokens: Sendable, Equatable, Decodable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: TimeInterval?
    public var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

/// Anything that can trade a refresh token for new tokens.
public protocol TokenRefresher: Sendable {
    func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens
}

/// The OAuth 2.1 endpoints of one site: dynamic registration, authorization URL, token and refresh.
public struct OAuthClient: TokenRefresher {
    public let config: UptfConfig
    private let loader: any HTTPLoader

    public init(config: UptfConfig, loader: any HTTPLoader = URLSession.uptfDefault()) {
        self.config = config
        self.loader = loader
    }

    // MARK: Dynamic client registration (RFC 7591)

    /// Registers this app as a public client and returns its `client_id`.
    public func registerClient() async throws -> String {
        var request = URLRequest(url: config.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "client_name": UptfConfig.clientName,
            "redirect_uris": ["http://127.0.0.1/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": UptfConfig.scope,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw UptfError.signInFailed(Self.errorMessage(data) ?? "Sign-in couldn't start. Please try again.")
        }
        struct Registration: Decodable { var client_id: String }
        guard let registration = try? JSONDecoder().decode(Registration.self, from: data), !registration.client_id.isEmpty else {
            throw UptfError.signInFailed("Sign-in couldn't start. Please try again.")
        }
        return registration.client_id
    }

    // MARK: Authorization request

    /// The URL to open in the browser. PKCE S256, loopback redirect, `resource` = `<origin>/api/v1`.
    public func authorizeURL(clientId: String, redirectURI: String, state: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: config.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: UptfConfig.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: config.appResourceURL.absoluteString),
        ]
        return components.url!
    }

    // MARK: Token endpoint

    public func exchange(code: String, codeVerifier: String, redirectURI: String, clientId: String) async throws -> OAuthTokens {
        let form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientId),
            ("code_verifier", codeVerifier),
            ("resource", config.appResourceURL.absoluteString),
        ]
        do {
            return try await tokenRequest(form)
        } catch UptfError.notSignedIn {
            throw UptfError.signInFailed("Sign-in didn't go through. Please try again.")
        }
    }

    /// Throws `UptfError.notSignedIn` when the refresh token is no longer valid (`invalid_grant`).
    public func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
        try await tokenRequest([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientId),
            ("resource", config.appResourceURL.absoluteString),
        ])
    }

    /// RFC 7009 revocation. The server revokes the whole grant whichever half is presented, so
    /// revoking the refresh token also ends the access token. Answers 200 even for an unknown
    /// token (§2.2), so only a transport or server failure throws.
    public func revoke(refreshToken: String, clientId: String) async throws {
        var request = URLRequest(url: config.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            Self.formEncode([
                ("token", refreshToken),
                ("token_type_hint", "refresh_token"),
                ("client_id", clientId),
            ]).utf8)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw UptfError.server(
                status: response.statusCode,
                message: Self.errorMessage(data) ?? "Signing out didn't work. Please try again.")
        }
    }

    private func tokenRequest(_ form: [(String, String)]) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 {
                throw UptfError.rateLimited(
                    retryAfter: RetryAfter.seconds(from: response.value(forHTTPHeaderField: "Retry-After")))
            }
            let error = (try? JSONDecoder().decode(OAuthErrorBody.self, from: data))
            if error?.error == "invalid_grant" { throw UptfError.notSignedIn }
            var message = Self.errorMessage(data) ?? "Signing in again didn't work. Please try again."
            if error?.error == "invalid_client" { message = "invalid_client: " + message }
            throw UptfError.server(status: response.statusCode, message: message)
        }
        guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data), !tokens.accessToken.isEmpty else {
            throw UptfError.unexpected("Sign-in got an answer we couldn't read. Please try again.")
        }
        return tokens
    }

    // MARK: Helpers

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await loader.load(request)
        } catch let error as UptfError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UptfError.network(error)
        }
    }

    private struct OAuthErrorBody: Decodable {
        var error: String?
        var error_description: String?
    }

    /// `error_description` / `error` from an OAuth error body, or the envelope's `error` string.
    static func errorMessage(_ data: Data) -> String? {
        if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
            if let description = body.error_description, !description.isEmpty { return description }
            if let error = body.error, !error.isEmpty { return error }
        }
        return nil
    }

    /// `application/x-www-form-urlencoded` body. Only unreserved characters are left as-is.
    static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

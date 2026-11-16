import AppKit
public import Foundation

/// Opens URLs in the user's default browser.
public enum BrowserOpener {
    /// Returns false if the URL could not be opened.
    public static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// Browser sign-in: OAuth 2.1 authorization code + PKCE over a loopback redirect.
public struct Authenticator: Sendable {
    public let config: UptfConfig
    private let store: any TokenStore
    private let registrations: ClientRegistrationStore
    private let oauth: OAuthClient
    private let openURL: @Sendable (URL) -> Bool
    private let callbackTimeout: TimeInterval

    /// - Parameter callbackTimeout: how long to wait for the browser to come back, in seconds.
    public init(
        config: UptfConfig, store: any TokenStore, registrations: ClientRegistrationStore,
        oauth: OAuthClient? = nil, openURL: @escaping @Sendable (URL) -> Bool = BrowserOpener.open,
        callbackTimeout: TimeInterval = 300
    ) {
        self.config = config
        self.store = store
        self.registrations = registrations
        self.oauth = oauth ?? OAuthClient(config: config)
        self.openURL = openURL
        self.callbackTimeout = callbackTimeout
    }

    /// True when credentials for this site are stored (does not contact the server).
    public func isSignedIn() throws -> Bool {
        try store.load(origin: config.origin) != nil
    }

    /// Removes the stored credentials for this site. Revokes the grant on the server first
    /// (best effort): returns false if that failed, in which case the credentials are still
    /// forgotten on this Mac and the grant can be revoked from the account settings.
    @discardableResult
    public func signOut() async throws -> Bool {
        var revoked = true
        if let credentials = try store.load(origin: config.origin) {
            do {
                try await oauth.revoke(refreshToken: credentials.refreshToken, clientId: credentials.clientId)
            } catch {
                revoked = false
            }
        }
        try store.delete(origin: config.origin)
        return revoked
    }

    /// Runs the whole flow: register (once), open the browser, wait for the redirect, exchange
    /// the code, store the tokens. `onAuthorizationURL` is called with the URL being opened so a
    /// terminal can show it as a fallback.
    ///
    /// When the server no longer knows the stored registration, the registration is forgotten.
    /// If the token request is what reveals it, the flow starts over once with a new registration.
    /// If the sign-in page rejected it, no redirect ever comes back: the wait ends in a timeout,
    /// and the next attempt registers again.
    public func signIn(onAuthorizationURL: @Sendable (URL) -> Void = { _ in }) async throws {
        do {
            try await attemptSignIn(onAuthorizationURL: onAuthorizationURL)
        } catch is UnknownClient {
            do {
                try await attemptSignIn(onAuthorizationURL: onAuthorizationURL)
            } catch is UnknownClient {
                throw UptfError.signInFailed("The sign-in page didn't recognise this app. Please try again.")
            }
        }
    }

    /// The server answered `invalid_client`: the stored registration is gone and has been forgotten.
    private struct UnknownClient: Error {}

    private func attemptSignIn(onAuthorizationURL: @Sendable (URL) -> Void) async throws {
        let clientId = try await clientId()
        let pkce = try PKCE.generate()
        let state = try PKCE.generateState()

        let server = LoopbackServer(expectedState: state, timeout: callbackTimeout)
        let port = try await server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        let url = oauth.authorizeURL(
            clientId: clientId, redirectURI: redirectURI, state: state, codeChallenge: pkce.challenge)
        onAuthorizationURL(url)
        guard openURL(url) else {
            throw UptfError.signInFailed("Could not open the browser. Open this link yourself: \(url.absoluteString)")
        }

        let code: String
        do {
            code = try await server.waitForCode()
        } catch UptfError.signInFailed(let message) where message == server.timeoutMessage {
            // An unknown client is refused on the sign-in page, so nothing ever comes back.
            try? registrations.forget(origin: config.origin)
            throw UptfError.signInFailed(message)
        }
        let tokens: OAuthTokens
        do {
            tokens = try await oauth.exchange(
                code: code, codeVerifier: pkce.verifier, redirectURI: redirectURI, clientId: clientId)
        } catch UptfError.server(_, let message) where message.contains("invalid_client") {
            try? registrations.forget(origin: config.origin)
            throw UnknownClient()
        }
        guard let refreshToken = tokens.refreshToken else {
            throw UptfError.signInFailed("Sign-in didn't finish. Please try again.")
        }
        try store.save(
            StoredCredentials(
                accessToken: tokens.accessToken, refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(tokens.expiresIn ?? 3600), clientId: clientId),
            origin: config.origin)
    }

    private func clientId() async throws -> String {
        if let existing = registrations.clientId(origin: config.origin) { return existing }
        let registered = try await oauth.registerClient()
        try registrations.save(clientId: registered, origin: config.origin)
        return registered
    }
}

import Foundation
import Testing

@testable import UptfKit

@Suite("PKCE and authorization")
struct AuthTests {
    // RFC 7636 appendix B. (The sha256/base64url of this verifier is E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM.)
    @Test func pkceMatchesRFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsValidAndUnique() throws {
        let first = try PKCE.generate()
        let second = try PKCE.generate()
        #expect(first.verifier.count == 43)
        #expect(first.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(first.verifier != second.verifier)
        #expect(first.challenge == PKCE.challenge(for: first.verifier))
    }

    @Test func authorizeURLCarriesPKCEResourceAndLoopbackRedirect() throws {
        let config = try UptfConfig(origin: "https://uploadthefile.com")
        let oauth = OAuthClient(config: config)
        let url = oauth.authorizeURL(
            clientId: "client-1", redirectURI: "http://127.0.0.1:51789/callback", state: "state-1",
            codeChallenge: "challenge-1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "uploadthefile.com")
        #expect(components.path == "/oauth/authorize")

        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        #expect(value("client_id") == "client-1")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge") == "challenge-1")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "state-1")
        #expect(value("redirect_uri") == "http://127.0.0.1:51789/callback")
        #expect(value("resource") == "https://uploadthefile.com/api/v1")
        #expect(value("scope") == "sites:read sites:write")
    }

    @Test func resourceFollowsTheConfiguredOrigin() throws {
        let config = try UptfConfig(origin: "http://localhost:3000/")
        #expect(config.origin == "http://localhost:3000")
        #expect(config.appResourceURL.absoluteString == "http://localhost:3000/api/v1")
    }

    @Test func plainHTTPIsOnlyAllowedOnLoopback() {
        #expect(throws: UptfError.self) { try UptfConfig(origin: "http://example.com") }
    }
}

@Suite("Authorization callback")
struct CallbackTests {
    @Test func parsesCodeAndState() throws {
        let callback = try #require(AuthorizationCallback.parse(target: "/callback?code=abc123&state=xyz"))
        #expect(callback.code == "abc123")
        #expect(callback.state == "xyz")
        #expect(try callback.validated(expectedState: "xyz") == "abc123")
    }

    @Test func otherPathsAreNotTheCallback() {
        #expect(AuthorizationCallback.parse(target: "/favicon.ico") == nil)
        #expect(AuthorizationCallback.parse(target: "/callbackx?code=a&state=b") == nil)
    }

    @Test func serverErrorIsReported() throws {
        let callback = try #require(
            AuthorizationCallback.parse(
                target: "/callback?error=access_denied&error_description=Nope&state=xyz"))
        #expect(callback.error == "access_denied")
        #expect(throws: CallbackError.denied(error: "access_denied", description: "Nope")) {
            try callback.validated(expectedState: "xyz")
        }
    }

    @Test func stateMismatchIsRejected() throws {
        let callback = try #require(AuthorizationCallback.parse(target: "/callback?code=abc&state=other"))
        #expect(throws: CallbackError.stateMismatch) { try callback.validated(expectedState: "xyz") }
    }

    @Test func missingStateIsRejectedBeforeAnythingElse() throws {
        let callback = try #require(AuthorizationCallback.parse(target: "/callback?error=access_denied"))
        #expect(throws: CallbackError.stateMismatch) { try callback.validated(expectedState: "xyz") }
    }

    @Test func missingCodeIsReported() throws {
        let callback = try #require(AuthorizationCallback.parse(target: "/callback?state=xyz"))
        #expect(throws: CallbackError.missingCode) { try callback.validated(expectedState: "xyz") }
    }
}

// MARK: - TokenManager

/// Counts refreshes and takes a moment, so concurrent callers overlap.
actor CountingRefresher: TokenRefresher {
    private(set) var calls = 0

    func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
        calls += 1
        try await Task.sleep(for: .milliseconds(150))
        return OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 3600, tokenType: "Bearer")
    }
}

@Suite("TokenManager")
struct TokenManagerTests {
    private let origin = "https://uploadthefile.test"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(expiringIn seconds: TimeInterval) -> InMemoryTokenStore {
        InMemoryTokenStore([
            origin: StoredCredentials(
                accessToken: "old-access", refreshToken: "old-refresh",
                expiresAt: base.addingTimeInterval(seconds), clientId: "client")
        ])
    }

    @Test func twoConcurrentRequestsNearExpiryRefreshExactlyOnce() async throws {
        let store = store(expiringIn: 30)  // inside the 60 s leeway
        let refresher = CountingRefresher()
        let now = base
        let manager = TokenManager(origin: origin, store: store, refresher: refresher, leeway: 60, now: { now })

        async let first = manager.accessToken()
        async let second = manager.accessToken()
        let (a, b) = try await (first, second)

        #expect(a == "new-access")
        #expect(b == "new-access")
        #expect(await refresher.calls == 1)
        let saved = try #require(try store.load(origin: origin))
        #expect(saved.refreshToken == "new-refresh")

        // A later call finds a fresh token and does not refresh again.
        #expect(try await manager.accessToken() == "new-access")
        #expect(await refresher.calls == 1)
    }

    @Test func aValidTokenIsNotRefreshed() async throws {
        let refresher = CountingRefresher()
        let now = base
        let manager = TokenManager(
            origin: origin, store: store(expiringIn: 3600), refresher: refresher, now: { now })
        #expect(try await manager.accessToken() == "old-access")
        #expect(await refresher.calls == 0)
    }

    @Test func rejectedTokenRefreshesButOnlyOnce() async throws {
        let refresher = CountingRefresher()
        let now = base
        let manager = TokenManager(
            origin: origin, store: store(expiringIn: 3600), refresher: refresher, now: { now })

        // The server said 401 for "old-access" (twice, from two requests).
        async let first = manager.accessToken(replacing: "old-access")
        async let second = manager.accessToken(replacing: "old-access")
        let (a, b) = try await (first, second)
        #expect(a == "new-access" && b == "new-access")
        #expect(await refresher.calls == 1)

        // Somebody already replaced it: a late 401 report does not trigger another refresh.
        #expect(try await manager.accessToken(replacing: "old-access") == "new-access")
        #expect(await refresher.calls == 1)
    }

    @Test func nothingStoredMeansNotSignedIn() async {
        let manager = TokenManager(
            origin: origin, store: InMemoryTokenStore(), refresher: CountingRefresher())
        let error = await thrownUptfError { try await manager.accessToken() }
        guard case .notSignedIn? = error else {
            Issue.record("expected notSignedIn, got \(String(describing: error))")
            return
        }
    }
}

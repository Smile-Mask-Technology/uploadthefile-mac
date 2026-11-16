import Foundation
import Testing
@testable import UptfKit

/// `uptf logout` ends the grant on the server (RFC 7009), then forgets it locally, and still
/// forgets it locally when the server cannot be reached.
@Suite("Sign-out")
struct SignOutTests {
    final class RecordingLoader: HTTPLoader, @unchecked Sendable {
        let status: Int?
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { _requests } }

        /// `status` nil means the network is down.
        init(status: Int?) { self.status = status }

        func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { _requests.append(request) }
            guard let status else { throw URLError(.notConnectedToInternet) }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let config = try! UptfConfig(origin: "http://127.0.0.1:3300")

    func signedInAuthenticator(_ loader: RecordingLoader, home: URL) throws -> (Authenticator, InMemoryTokenStore) {
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(accessToken: "utf_at_x", refreshToken: "utf_rt_secret", expiresAt: Date().addingTimeInterval(3600), clientId: "client_1"),
            origin: Self.config.origin)
        let authenticator = Authenticator(
            config: Self.config, store: store,
            registrations: ClientRegistrationStore(fileURL: home.appendingPathComponent("oauth-clients.json")),
            oauth: OAuthClient(config: Self.config, loader: loader), openURL: { _ in true })
        return (authenticator, store)
    }

    @Test func revokesTheRefreshTokenThenForgetsIt() async throws {
        try await withTempDirectory { home in
            let loader = RecordingLoader(status: 200)
            let (authenticator, store) = try signedInAuthenticator(loader, home: home)
            #expect(try await authenticator.signOut() == true)
            #expect(try store.load(origin: Self.config.origin) == nil)
            let request = try #require(loader.requests.first)
            #expect(request.url == Self.config.revocationEndpoint)
            #expect(request.httpMethod == "POST")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("token=utf_rt_secret"))
            #expect(body.contains("token_type_hint=refresh_token"))
            #expect(body.contains("client_id=client_1"))
        }
    }

    @Test func forgetsLocallyEvenWhenTheServerIsUnreachable() async throws {
        try await withTempDirectory { home in
            let loader = RecordingLoader(status: nil)
            let (authenticator, store) = try signedInAuthenticator(loader, home: home)
            #expect(try await authenticator.signOut() == false)
            #expect(try store.load(origin: Self.config.origin) == nil)
        }
    }

    @Test func signedOutAlreadyMakesNoRequest() async throws {
        try await withTempDirectory { home in
            let loader = RecordingLoader(status: 200)
            let authenticator = Authenticator(
                config: Self.config, store: InMemoryTokenStore(),
                registrations: ClientRegistrationStore(fileURL: home.appendingPathComponent("oauth-clients.json")),
                oauth: OAuthClient(config: Self.config, loader: loader), openURL: { _ in true })
            let revoked = try await authenticator.signOut()
            #expect(revoked)
            #expect(loader.requests.isEmpty)
        }
    }
}

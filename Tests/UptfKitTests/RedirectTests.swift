import Foundation
import Testing

@testable import UptfKit

/// Answers every request itself, without a network: hosts starting with `cross307` or
/// `cross302` redirect to another origin, `same307` redirects within the origin, and
/// `elsewhere.test` is where a followed redirect would land (it answers with a token).
final class RedirectStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [(url: String, authorization: String?)] = []

    static func requests(toHostsStartingWith prefix: String) -> [String] {
        lock.withLock { log.filter { URL(string: $0.url)?.host?.hasPrefix(prefix) == true }.map(\.url) }
    }

    static func authorizationHeaders(sentTo host: String) -> [String?] {
        lock.withLock { log.filter { URL(string: $0.url)?.host == host }.map(\.authorization) }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.withLock { Self.log.append((url.absoluteString, request.value(forHTTPHeaderField: "Authorization"))) }

        let redirect: (status: Int, location: String)?
        if host.hasPrefix("cross307") {
            redirect = (307, "https://elsewhere.test/collect")
        } else if host.hasPrefix("cross302") {
            redirect = (302, "https://elsewhere.test/collect")
        } else if host.hasPrefix("same307") {
            redirect = (307, "https://\(host)/moved")
        } else {
            redirect = nil
        }

        if let redirect, let target = URL(string: redirect.location) {
            let response = HTTPURLResponse(
                url: url, statusCode: redirect.status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.location])!
            var next = URLRequest(url: target)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // When the session refuses the redirect, the redirect answer becomes the final
            // response, which a URL protocol has to deliver itself (a real HTTP load does).
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let body = Data(#"{"access_token":"from-elsewhere","refresh_token":"r","expires_in":3600}"#.utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Redirects are not followed")
struct RedirectTests {
    private func oauth(host: String) throws -> OAuthClient {
        let config = try UptfConfig(origin: "https://\(host)")
        return OAuthClient(config: config, loader: URLSession.uptfSession(configuration: RedirectStub.configuration()))
    }

    @Test func aTokenRequestRedirectedToAnotherOriginIsNotReplayedThere() async throws {
        let host = "cross307.token.test"
        let error = await thrownUptfError {
            try await oauth(host: host).refresh(refreshToken: "utf_rt_secret", clientId: "client")
        }
        guard case .server(let status, _)? = error else {
            Issue.record("expected the redirect to be reported as an error, got \(String(describing: error))")
            return
        }
        #expect(status == 307)
        #expect(RedirectStub.requests(toHostsStartingWith: host).count == 1)
        #expect(RedirectStub.requests(toHostsStartingWith: "elsewhere").isEmpty)
    }

    @Test func aRedirectWithinTheSameOriginIsNotFollowedEither() async throws {
        let host = "same307.token.test"
        let error = await thrownUptfError {
            try await oauth(host: host).refresh(refreshToken: "utf_rt_secret", clientId: "client")
        }
        guard case .server(let status, _)? = error else {
            Issue.record("expected the redirect to be reported as an error, got \(String(describing: error))")
            return
        }
        #expect(status == 307)
        #expect(RedirectStub.requests(toHostsStartingWith: host).count == 1)
    }

    @Test func revokingIsNotFollowedToAnotherOrigin() async throws {
        let host = "cross302.revoke.test"
        let error = await thrownUptfError {
            try await oauth(host: host).revoke(refreshToken: "utf_rt_secret", clientId: "client")
        }
        guard case .server(let status, _)? = error else {
            Issue.record("expected the redirect to be reported as an error, got \(String(describing: error))")
            return
        }
        #expect(status == 302)
        #expect(RedirectStub.requests(toHostsStartingWith: "elsewhere").isEmpty)
    }

    @Test func anApiRequestNeverSendsItsBearerTokenToAnotherOrigin() async throws {
        let config = try UptfConfig(origin: "https://cross307.api.test")
        let store = InMemoryTokenStore([
            config.origin: StoredCredentials(
                accessToken: "utf_at_secret", refreshToken: "utf_rt_secret",
                expiresAt: Date().addingTimeInterval(3600), clientId: "client")
        ])
        let session = URLSession.uptfSession(configuration: RedirectStub.configuration())
        let client = UptfClient(config: config, store: store, session: session)

        let error = await thrownUptfError { try await client.pages() }

        guard case .server(let status, _)? = error else {
            Issue.record("expected the redirect to be reported as an error, got \(String(describing: error))")
            return
        }
        #expect(status == 307)
        #expect(RedirectStub.authorizationHeaders(sentTo: "cross307.api.test") == ["Bearer utf_at_secret"])
        #expect(RedirectStub.requests(toHostsStartingWith: "elsewhere").isEmpty)
    }
}

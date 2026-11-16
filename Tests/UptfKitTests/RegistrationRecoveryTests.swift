import Foundation
import Testing

@testable import UptfKit

/// A server for the sign-in calls: it registers clients as `fresh-1`, `fresh-2`, ... and
/// refuses the token request (`invalid_client`) for every client id in `unknownClients`.
final class SignInServer: HTTPLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var registered = 0
    private var tokenRequests = 0
    private let unknownClients: Set<String>
    private let rejectEveryClient: Bool

    init(unknownClients: Set<String> = [], rejectEveryClient: Bool = false) {
        self.unknownClients = unknownClients
        self.rejectEveryClient = rejectEveryClient
    }

    var registrations: Int { lock.withLock { registered } }
    var tokenCalls: Int { lock.withLock { tokenRequests } }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        func reply(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if url.path.hasSuffix("/register") {
            let number = lock.withLock { () -> Int in registered += 1; return registered }
            return reply(201, #"{"client_id":"fresh-\#(number)"}"#)
        }
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        lock.withLock { tokenRequests += 1 }
        let unknown = rejectEveryClient || unknownClients.contains { form.contains("client_id=\($0)&") || form.hasSuffix("client_id=\($0)") }
        if unknown {
            return reply(401, #"{"error":"invalid_client","error_description":"Unknown client"}"#)
        }
        return reply(200, #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer"}"#)
    }
}

/// Opens the sign-in page by delivering the redirect to the loopback listener straight away,
/// the way a browser would after the person approves.
final class ApprovingBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    private let approves: Bool

    init(approves: Bool = true) { self.approves = approves }

    var opened: [URL] { lock.withLock { _opened } }

    func open(_ url: URL) -> Bool {
        lock.withLock { _opened.append(url) }
        guard approves,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
            let state = items.first(where: { $0.name == "state" })?.value,
            var callback = URLComponents(string: redirect)
        else { return true }
        callback.queryItems = [URLQueryItem(name: "code", value: "code-1"), URLQueryItem(name: "state", value: state)]
        if let target = callback.url {
            Task { _ = try? await URLSession.shared.data(from: target) }
        }
        return true
    }
}

@Suite("Stale client registration")
struct RegistrationRecoveryTests {
    private let config = try! UptfConfig(origin: "http://127.0.0.1:3301")

    private func authenticator(
        server: SignInServer, browser: ApprovingBrowser, home: URL, callbackTimeout: TimeInterval = 300
    ) -> (Authenticator, InMemoryTokenStore, ClientRegistrationStore) {
        let store = InMemoryTokenStore()
        let registrations = ClientRegistrationStore(fileURL: home.appendingPathComponent("oauth-clients.json"))
        let authenticator = Authenticator(
            config: config, store: store, registrations: registrations,
            oauth: OAuthClient(config: config, loader: server), openURL: { browser.open($0) },
            callbackTimeout: callbackTimeout)
        return (authenticator, store, registrations)
    }

    @Test func aRegistrationTheTokenEndpointRefusesIsReplacedAndSignInGoesOn() async throws {
        try await withTempDirectory { home in
            let server = SignInServer(unknownClients: ["stale"])
            let browser = ApprovingBrowser()
            let (authenticator, store, registrations) = authenticator(server: server, browser: browser, home: home)
            try registrations.save(clientId: "stale", origin: config.origin)

            try await authenticator.signIn()

            #expect(server.registrations == 1)
            #expect(browser.opened.count == 2)
            #expect(registrations.clientId(origin: config.origin) == "fresh-1")
            #expect(try store.load(origin: config.origin)?.clientId == "fresh-1")
        }
    }

    @Test func aRegistrationTheServerKeepsRefusingStopsAfterOneNewTry() async throws {
        try await withTempDirectory { (home: URL) async throws -> Void in
            let server = SignInServer(rejectEveryClient: true)
            let browser = ApprovingBrowser()
            let (authenticator, store, registrations) = authenticator(server: server, browser: browser, home: home)
            try registrations.save(clientId: "stale", origin: config.origin)

            let error = await thrownUptfError { try await authenticator.signIn() }

            guard case .signInFailed? = error else {
                Issue.record("expected signInFailed, got \(String(describing: error))")
                return
            }
            #expect(server.registrations == 1)
            #expect(server.tokenCalls == 2)
            #expect(browser.opened.count == 2)
            #expect(registrations.clientId(origin: config.origin) == nil)
            #expect(try store.load(origin: config.origin) == nil)
        }
    }

    @Test func aSignInPageThatNeverRedirectsBackForgetsTheRegistration() async throws {
        try await withTempDirectory { (home: URL) async throws -> Void in
            let server = SignInServer()
            let browser = ApprovingBrowser(approves: false)
            let (authenticator, _, registrations) = authenticator(
                server: server, browser: browser, home: home, callbackTimeout: 0.3)
            try registrations.save(clientId: "stale", origin: config.origin)

            let error = await thrownUptfError { try await authenticator.signIn() }

            guard case .signInFailed? = error else {
                Issue.record("expected signInFailed, got \(String(describing: error))")
                return
            }
            #expect(registrations.clientId(origin: config.origin) == nil)
            #expect(browser.opened.count == 1)
        }
    }

    @Test func aWorkingRegistrationIsKept() async throws {
        try await withTempDirectory { home in
            let server = SignInServer()
            let browser = ApprovingBrowser()
            let (authenticator, store, registrations) = authenticator(server: server, browser: browser, home: home)
            try registrations.save(clientId: "known", origin: config.origin)

            try await authenticator.signIn()

            #expect(server.registrations == 0)
            #expect(registrations.clientId(origin: config.origin) == "known")
            #expect(try store.load(origin: config.origin)?.clientId == "known")
        }
    }
}

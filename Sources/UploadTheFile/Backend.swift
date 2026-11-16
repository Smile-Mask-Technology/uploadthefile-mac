import AppKit
import Foundation
import UptfKit

/// Everything the app needs to talk to one site: sign-in, API client, local index.
/// Built once at launch; `afterSignOut()` gives a fresh client so a different account never sees
/// the previous account's cached list.
struct Backend: Sendable {
    let config: UptfConfig
    let store: any TokenStore
    let client: UptfClient
    let index: PublishedIndex
    let authenticator: Authenticator

    init() throws {
        let config = try UptfConfig.fromEnvironment()
        let store = KeychainTokenStore()
        self.init(
            config: config, store: store, client: UptfClient(config: config, store: store),
            index: try PublishedIndex(config: config),
            authenticator: Authenticator(config: config, store: store, registrations: try .standard()))
    }

    private init(
        config: UptfConfig, store: any TokenStore, client: UptfClient, index: PublishedIndex,
        authenticator: Authenticator
    ) {
        self.config = config
        self.store = store
        self.client = client
        self.index = index
        self.authenticator = authenticator
    }

    var publisher: Publisher { Publisher(client: client, index: index) }

    func withFreshClient() -> Backend {
        Backend(
            config: config, store: store, client: UptfClient(config: config, store: store), index: index,
            authenticator: authenticator)
    }

    /// The site as shown to people: `uploadthefile.com`, or `localhost:3000` for a dev server.
    var siteLabel: String {
        let url = config.originURL
        guard let host = url.host else { return config.origin }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

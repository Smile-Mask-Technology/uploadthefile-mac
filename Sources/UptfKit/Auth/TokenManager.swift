public import Foundation

/// Hands out valid access tokens and rotates refresh tokens, one refresh at a time.
///
/// Refresh tokens are single use, so two requests must never refresh with the same one:
/// all refreshes go through this actor, concurrent callers join the refresh already running,
/// and the store is re-read before every decision so a refresh done by another process
/// (the app and the CLI share the Keychain item) is picked up instead of repeated.
public actor TokenManager {
    private let origin: String
    private let store: any TokenStore
    private let refresher: any TokenRefresher
    private let now: @Sendable () -> Date
    private let leeway: TimeInterval
    private var inFlight: Task<StoredCredentials, any Error>?

    /// - Parameter leeway: refresh this many seconds before the access token expires.
    public init(
        origin: String, store: any TokenStore, refresher: any TokenRefresher,
        leeway: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.origin = origin
        self.store = store
        self.refresher = refresher
        self.leeway = leeway
        self.now = now
    }

    /// An access token that is good for at least `leeway` more seconds.
    /// Throws ``UptfError/notSignedIn`` when nothing is stored.
    public func accessToken() async throws -> String {
        try await credentials(rejecting: nil).accessToken
    }

    /// Call after the API answered 401 for `rejected`. Refreshes unless somebody already did.
    public func accessToken(replacing rejected: String) async throws -> String {
        try await credentials(rejecting: rejected).accessToken
    }

    private func credentials(rejecting rejected: String?) async throws -> StoredCredentials {
        // No suspension point between the check of `inFlight`, the store read and starting the
        // task, so this section is atomic with respect to other callers.
        if let inFlight { return try await inFlight.value }
        guard let current = try store.load(origin: origin) else { throw UptfError.notSignedIn }
        let needsRefresh: Bool
        if let rejected {
            needsRefresh = current.accessToken == rejected
        } else {
            needsRefresh = current.expiresAt.timeIntervalSince(now()) <= leeway
        }
        guard needsRefresh else { return current }
        let task = Task { try await self.performRefresh(current) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performRefresh(_ current: StoredCredentials) async throws -> StoredCredentials {
        let tokens: OAuthTokens
        do {
            tokens = try await refresher.refresh(refreshToken: current.refreshToken, clientId: current.clientId)
        } catch UptfError.notSignedIn {
            // Another process may have rotated the token first; if so, use what it saved.
            if let latest = try? store.load(origin: origin), latest.refreshToken != current.refreshToken {
                return latest
            }
            try? store.delete(origin: origin)
            throw UptfError.notSignedIn
        }
        let updated = StoredCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? current.refreshToken,
            expiresAt: now().addingTimeInterval(tokens.expiresIn ?? 3600),
            clientId: current.clientId)
        try store.save(updated, origin: origin)
        return updated
    }
}

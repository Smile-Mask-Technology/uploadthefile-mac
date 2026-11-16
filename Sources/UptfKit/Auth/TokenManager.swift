public import Foundation

/// Hands out valid access tokens and rotates refresh tokens, one refresh at a time.
///
/// Refresh tokens are single use, and presenting one a second time makes the server revoke the
/// whole grant. So two requests must never refresh with the same one: concurrent callers in this
/// process join the refresh already running, and a lock file (`flock`) makes the app and the CLI,
/// which share the Keychain item, take turns. Under the lock the store is read again, so a
/// refresh another process finished meanwhile is picked up instead of repeated.
public actor TokenManager {
    /// Where the cross-process lock lives: `refresh.lock` in the app's Application Support folder.
    public static func standardLockFileURL() -> URL? {
        try? AppSupport.directory().appendingPathComponent("refresh.lock")
    }

    private let origin: String
    private let store: any TokenStore
    private let refresher: any TokenRefresher
    private let now: @Sendable () -> Date
    private let leeway: TimeInterval
    private let lockFileURL: @Sendable () -> URL?
    private let lockTimeout: TimeInterval
    private var inFlight: Task<StoredCredentials, any Error>?

    /// - Parameters:
    ///   - leeway: refresh this many seconds before the access token expires.
    ///   - lockFileURL: the file other processes lock while they refresh, asked for when a
    ///     refresh starts; returning nil skips the cross-process lock (this process still
    ///     refreshes one at a time).
    ///   - lockTimeout: how long to wait for another process to finish refreshing before
    ///     giving up with ``UptfError/network(_:)`` (the stored credentials are kept).
    public init(
        origin: String, store: any TokenStore, refresher: any TokenRefresher,
        leeway: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() },
        lockFileURL: @escaping @Sendable () -> URL? = TokenManager.standardLockFileURL,
        lockTimeout: TimeInterval = 30
    ) {
        self.origin = origin
        self.store = store
        self.refresher = refresher
        self.leeway = leeway
        self.now = now
        self.lockFileURL = lockFileURL
        self.lockTimeout = lockTimeout
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

    private func needsRefresh(_ credentials: StoredCredentials, rejecting rejected: String?) -> Bool {
        if let rejected { return credentials.accessToken == rejected }
        return credentials.expiresAt.timeIntervalSince(now()) <= leeway
    }

    private func credentials(rejecting rejected: String?) async throws -> StoredCredentials {
        // No suspension point between the check of `inFlight`, the store read and starting the
        // task, so this section is atomic with respect to other callers.
        if let inFlight { return try await inFlight.value }
        guard let current = try store.load(origin: origin) else { throw UptfError.notSignedIn }
        guard needsRefresh(current, rejecting: rejected) else { return current }
        let task = Task { try await self.performRefresh(current, rejecting: rejected) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performRefresh(_ current: StoredCredentials, rejecting rejected: String?) async throws -> StoredCredentials {
        let lock = try await acquireLock()
        defer { lock?.release() }

        // Another process may have refreshed while we waited for the lock (or before we read the
        // store): use what it saved. Its tokens are the only valid ones, ours are spent.
        guard let stored = try store.load(origin: origin) else { throw UptfError.notSignedIn }
        if stored.refreshToken != current.refreshToken || !needsRefresh(stored, rejecting: rejected) {
            return stored
        }

        let tokens: OAuthTokens
        do {
            tokens = try await refresher.refresh(refreshToken: stored.refreshToken, clientId: stored.clientId)
        } catch UptfError.notSignedIn {
            // The lock is still held, so nobody else saves or deletes between this read and the
            // delete. Forget the credentials only if they are the ones that just failed.
            if let latest = try? store.load(origin: origin) {
                if latest.refreshToken != stored.refreshToken { return latest }
                try? store.delete(origin: origin)
            }
            throw UptfError.notSignedIn
        }
        let updated = StoredCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? stored.refreshToken,
            expiresAt: now().addingTimeInterval(tokens.expiresIn ?? 3600),
            clientId: stored.clientId)
        try store.save(updated, origin: origin)
        return updated
    }

    private func acquireLock() async throws -> RefreshLock? {
        guard let url = lockFileURL() else { return nil }
        do {
            return try await RefreshLock.acquire(at: url, timeout: lockTimeout)
        } catch is RefreshLock.TimedOut {
            // Still signed in: another process holds the refresh. Failing like a network error
            // keeps the stored credentials and the signed-in state; the next call tries again.
            throw UptfError.network(RefreshLock.TimedOut())
        }
    }
}

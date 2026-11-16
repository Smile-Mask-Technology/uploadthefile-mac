import Foundation
import Testing

@testable import UptfKit

/// Plays the token endpoint of a server that revokes the whole grant when a refresh token is
/// presented twice: every refresh token works once. Takes a moment, so overlapping calls overlap.
actor SingleUseRefreshEndpoint: TokenRefresher {
    private(set) var requests = 0
    private(set) var grantRevoked = false
    private var spent: Set<String> = []
    private var issued = 0

    func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
        requests += 1
        try await Task.sleep(for: .milliseconds(150))
        if spent.contains(refreshToken) || grantRevoked {
            grantRevoked = true
            throw UptfError.notSignedIn
        }
        spent.insert(refreshToken)
        issued += 1
        return OAuthTokens(
            accessToken: "access-\(issued)", refreshToken: "refresh-\(issued)", expiresIn: 3600, tokenType: "Bearer")
    }
}

/// The app and `uptf` are two processes with one Keychain item. Two managers over one store and
/// one lock file stand in for them.
@Suite("Token refresh across processes")
struct CrossProcessRefreshTests {
    private let origin = "https://uploadthefile.test"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func expiredStore() -> InMemoryTokenStore {
        InMemoryTokenStore([
            origin: StoredCredentials(
                accessToken: "old-access", refreshToken: "old-refresh",
                expiresAt: base.addingTimeInterval(-10), clientId: "client")
        ])
    }

    private func manager(
        _ store: InMemoryTokenStore, _ refresher: any TokenRefresher, lock: URL?, lockTimeout: TimeInterval = 30
    ) -> TokenManager {
        let now = base
        return TokenManager(
            origin: origin, store: store, refresher: refresher, now: { now },
            lockFileURL: { lock }, lockTimeout: lockTimeout)
    }

    @Test func twoProcessesRefreshOnceAndBothEndUpSignedIn() async throws {
        try await withTempDirectory { directory in
            let lock = directory.appendingPathComponent("refresh.lock")
            let store = expiredStore()
            let endpoint = SingleUseRefreshEndpoint()
            let app = manager(store, endpoint, lock: lock)
            let cli = manager(store, endpoint, lock: lock)

            async let fromApp = app.accessToken()
            async let fromCLI = cli.accessToken()
            let (a, b) = try await (fromApp, fromCLI)

            #expect(a == "access-1")
            #expect(b == "access-1")
            #expect(await endpoint.requests == 1)
            #expect(await endpoint.grantRevoked == false)
            let saved = try #require(try store.load(origin: origin))
            #expect(saved.refreshToken == "refresh-1")
        }
    }

    @Test func aRefreshDoneWhileWaitingForTheLockIsUsedNotRepeated() async throws {
        try await withTempDirectory { directory in
            let lock = directory.appendingPathComponent("refresh.lock")
            let store = expiredStore()
            let endpoint = SingleUseRefreshEndpoint()
            let held = try #require(try await RefreshLock.acquire(at: lock, timeout: 5))

            let waiting = Task { try await manager(store, endpoint, lock: lock).accessToken() }
            try await Task.sleep(for: .milliseconds(150))
            // The other process finishes its refresh and lets go.
            try store.save(
                StoredCredentials(
                    accessToken: "their-access", refreshToken: "their-refresh",
                    expiresAt: base.addingTimeInterval(3600), clientId: "client"),
                origin: origin)
            held.release()

            #expect(try await waiting.value == "their-access")
            #expect(await endpoint.requests == 0)
        }
    }

    @Test func waitingForTheLockIsBoundedAndLeavesTheCredentialsAlone() async throws {
        try await withTempDirectory { (directory: URL) async throws -> Void in
            let lock = directory.appendingPathComponent("refresh.lock")
            let store = expiredStore()
            let endpoint = SingleUseRefreshEndpoint()
            let held = try #require(try await RefreshLock.acquire(at: lock, timeout: 5))
            defer { held.release() }

            let waiter = manager(store, endpoint, lock: lock, lockTimeout: 0.3)
            let error = await thrownUptfError { try await waiter.accessToken() }

            guard case .network? = error else {
                Issue.record("expected a network-style error that keeps the sign-in, got \(String(describing: error))")
                return
            }
            #expect(await endpoint.requests == 0)
            #expect(try store.load(origin: origin)?.refreshToken == "old-refresh")
        }
    }

    @Test func theLockIsReleasedAfterASuccessfulRefresh() async throws {
        try await withTempDirectory { directory in
            let lock = directory.appendingPathComponent("refresh.lock")
            _ = try await manager(expiredStore(), SingleUseRefreshEndpoint(), lock: lock).accessToken()

            let next = try await RefreshLock.acquire(at: lock, timeout: 0.2)
            #expect(next != nil)
            next?.release()
        }
    }

    @Test func theLockIsReleasedWhenTheRefreshFails() async throws {
        struct Offline: TokenRefresher {
            func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
                throw UptfError.network(URLError(.notConnectedToInternet))
            }
        }
        try await withTempDirectory { directory in
            let lock = directory.appendingPathComponent("refresh.lock")
            let store = expiredStore()
            _ = await thrownUptfError { try await manager(store, Offline(), lock: lock).accessToken() }

            let next = try await RefreshLock.acquire(at: lock, timeout: 0.2)
            #expect(next != nil)
            next?.release()
            #expect(try store.load(origin: origin) != nil)
        }
    }

    @Test func aRejectedGrantDeletesTheCredentialsWhenNobodyReplacedThem() async throws {
        struct Revoked: TokenRefresher {
            func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
                throw UptfError.notSignedIn
            }
        }
        try await withTempDirectory { (directory: URL) async throws -> Void in
            let lock = directory.appendingPathComponent("refresh.lock")
            let store = expiredStore()
            let error = await thrownUptfError {
                try await manager(store, Revoked(), lock: directory.appendingPathComponent("refresh.lock")).accessToken()
            }
            guard case .notSignedIn? = error else {
                Issue.record("expected notSignedIn, got \(String(describing: error))")
                return
            }
            #expect(try store.load(origin: origin) == nil)
            #expect(FileManager.default.fileExists(atPath: lock.path))
        }
    }

    @Test func aRejectedGrantKeepsCredentialsAnotherProcessSavedMeanwhile() async throws {
        /// Rejects the old token, but only after "another process" saved a new one.
        struct RacedByAnotherProcess: TokenRefresher {
            let store: InMemoryTokenStore
            let origin: String
            func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
                try store.save(
                    StoredCredentials(
                        accessToken: "their-access", refreshToken: "their-refresh",
                        expiresAt: Date.distantFuture, clientId: clientId),
                    origin: origin)
                throw UptfError.notSignedIn
            }
        }
        try await withTempDirectory { directory in
            let store = expiredStore()
            let refresher = RacedByAnotherProcess(store: store, origin: origin)
            let token = try await manager(
                store, refresher, lock: directory.appendingPathComponent("refresh.lock")
            ).accessToken()
            #expect(token == "their-access")
            #expect(try store.load(origin: origin)?.refreshToken == "their-refresh")
        }
    }

    @Test func theLockFileIsPrivateToTheUser() async throws {
        try await withTempDirectory { directory in
            let lock = directory.appendingPathComponent("refresh.lock")
            let held = try #require(try await RefreshLock.acquire(at: lock, timeout: 1))
            defer { held.release() }
            let permissions = try FileManager.default.attributesOfItem(atPath: lock.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }
}

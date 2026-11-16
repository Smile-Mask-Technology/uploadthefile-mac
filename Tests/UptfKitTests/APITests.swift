import Foundation
import Testing

@testable import UptfKit

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test func envelopeErrorStringIsDecoded() {
        let body = Data(#"{"success":false,"error":"Password protection is available on Pro and above","upgrade":{"x":1}}"#.utf8)
        let error = ApiErrorMapper.map(status: 403, retryAfter: nil, body: body)
        guard case .server(let status, let message) = error else {
            Issue.record("expected .server, got \(error)")
            return
        }
        #expect(status == 403)
        #expect(message == "Password protection is available on Pro and above")
    }

    @Test func unreadableBodyFallsBackToTheStatus() {
        let error = ApiErrorMapper.map(status: 502, retryAfter: nil, body: Data("<html>bad gateway</html>".utf8))
        #expect(error.localizedDescription == "Something went wrong on our side. Try again in a moment.")
    }

    @Test func unauthorizedIsNotSignedIn() {
        let error = ApiErrorMapper.map(status: 401, retryAfter: nil, body: Data())
        guard case .notSignedIn = error else {
            Issue.record("expected .notSignedIn, got \(error)")
            return
        }
    }

    @Test func notFoundSaysSo() {
        let error = ApiErrorMapper.map(status: 404, retryAfter: nil, body: Data(#"{"success":false,"error":"Page not found"}"#.utf8))
        #expect(error.localizedDescription == "This link isn't in your account anymore.")
        #expect(error.statusCode == 404)
    }

    @Test func rateLimitWithRetryAfter() {
        let error = ApiErrorMapper.map(status: 429, retryAfter: "90", body: Data())
        guard case .rateLimited(let retryAfter) = error else {
            Issue.record("expected .rateLimited, got \(error)")
            return
        }
        #expect(retryAfter == 90)
        #expect(error.localizedDescription == "Too many changes in a short time. Try again in 2 minutes.")
    }

    @Test func rateLimitWithoutRetryAfter() {
        let error = ApiErrorMapper.map(status: 429, retryAfter: nil, body: Data())
        guard case .rateLimited(let retryAfter) = error else {
            Issue.record("expected .rateLimited, got \(error)")
            return
        }
        #expect(retryAfter == nil)
        #expect(error.localizedDescription == "Too many changes in a short time. Try again later.")
    }

    @Test func minutesAreRoundedUp() {
        #expect(UptfError.rateLimited(retryAfter: 1).localizedDescription == "Too many changes in a short time. Try again in 1 minute.")
        #expect(UptfError.rateLimited(retryAfter: 60).localizedDescription == "Too many changes in a short time. Try again in 1 minute.")
        #expect(UptfError.rateLimited(retryAfter: 61).localizedDescription == "Too many changes in a short time. Try again in 2 minutes.")
        #expect(UptfError.rateLimited(retryAfter: 3600).localizedDescription == "Too many changes in a short time. Try again in 60 minutes.")
        #expect(UptfError.rateLimited(retryAfter: 0).localizedDescription == "Too many changes in a short time. Try again in 1 minute.")
    }

    @Test func retryAfterAcceptsSecondsAndHTTPDates() {
        #expect(RetryAfter.seconds(from: "120") == 120)
        #expect(RetryAfter.seconds(from: " 7 ") == 7)
        #expect(RetryAfter.seconds(from: nil) == nil)
        #expect(RetryAfter.seconds(from: "soon") == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(RetryAfter.seconds(from: formatter.string(from: later), now: now) == 300)
    }
}

@Suite("UptfClient over a fake transport")
struct ClientTests {
    private static let listing = listJSON([pageJSON(id: "p1", name: "mysite"), pageJSON(id: "p2", name: nil, kind: "pdf")])

    /// Answers `GET /pages?...` with the listing and `GET /pages/<x>` with page p1.
    private static func standardTransport() -> FakeTransport {
        FakeTransport { method, path in
            switch (method, path) {
            case ("GET", let p) where p.hasPrefix("/pages?"): return .json(listing)
            case ("GET", "/pages/mysite"): return .json(pageEnvelopeJSON(pageJSON(id: "p1", name: "mysite")))
            case ("PATCH", "/pages/mysite"): return .json(pageEnvelopeJSON(pageJSON(id: "p1", name: "renamed")))
            case ("DELETE", "/pages/mysite"): return .json(#"{"success":true,"data":{"deleted":true,"id":"p1"}}"#)
            case ("POST", "/upload"):
                return .json(#"{"success":true,"data":{"url":"https://fresh.upload.tf","slug":"fresh","hasHtml":true}}"#, status: 201)
            default: return .error(404, "nope")
            }
        }
    }

    @Test func listingIsFetchedOnceAndServedFromTheCache() async throws {
        let transport = Self.standardTransport()
        let client = makeClient(transport)

        let first = try await client.pages()
        let second = try await client.pages()
        let byName = try await client.page("mysite")
        let byID = try await client.page("p2")

        #expect(first.map(\.id) == ["p1", "p2"])
        #expect(second == first)
        #expect(byName.id == "p1")
        #expect(byID.slug == "p2")  // an id-only page is addressed by its id
        #expect(transport.requests == ["GET /pages?limit=1000"])
    }

    @Test func refreshGoesBackToTheServer() async throws {
        let transport = Self.standardTransport()
        let client = makeClient(transport)
        _ = try await client.pages()
        _ = try await client.pages(refresh: true)
        #expect(transport.requests.count == 2)
    }

    @Test func detailsWithoutSettingsCostsNoExtraReads() async throws {
        let transport = Self.standardTransport()
        let client = makeClient(transport)
        _ = try await client.pages()
        let details = try await client.details("mysite")
        #expect(details.page.id == "p1")
        #expect(details.passwordProtected == nil)
        #expect(details.emailGateEnabled == nil)
        #expect(details.displayMode == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func aPageNotInTheCacheIsFetchedOnce() async throws {
        let transport = Self.standardTransport()
        let client = makeClient(transport)
        let page = try await client.page("mysite")
        #expect(page.id == "p1")
        #expect(transport.requests == ["GET /pages/mysite"])
    }

    @Test func settingsAreReadOneAfterAnotherAndStopAtARateLimit() async throws {
        let transport = FakeTransport { method, path in
            if path == "/pages/mysite" { return .json(pageEnvelopeJSON(pageJSON(id: "p1", name: "mysite"))) }
            return .error(429, "slow down", retryAfter: "3600")
        }
        let client = makeClient(transport)
        let error = await thrownUptfError { try await client.details("mysite", includeSettings: true) }
        guard case .rateLimited(let retryAfter)? = error else {
            Issue.record("expected rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == 3600)
        #expect(transport.requests == ["GET /pages/mysite", "GET /pages/mysite/password"])
    }

    @Test func renameUpdatesTheCachedPage() async throws {
        let transport = Self.standardTransport()
        let client = makeClient(transport)
        _ = try await client.pages()
        let renamed = try await client.rename("mysite", to: "renamed")
        #expect(renamed.id == "p1")

        let cached = try await client.page("renamed")
        #expect(cached.id == "p1")
        #expect(try await client.pages().map(\.slug) == ["renamed", "p2"])
        #expect(transport.requests == ["GET /pages?limit=1000", "PATCH /pages/mysite"])
    }

    @Test func unpublishRemovesTheCachedPage() async throws {
        let transport = Self.standardTransport()
        let client = makeClient(transport)
        _ = try await client.pages()
        try await client.unpublish("mysite")
        #expect(try await client.pages().map(\.id) == ["p2"])
        #expect(transport.requests == ["GET /pages?limit=1000", "DELETE /pages/mysite"])
    }

    @Test func publishingInvalidatesTheCache() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("note.html", in: directory, contents: "<h1>hi</h1>")
            let transport = Self.standardTransport()
            let client = makeClient(transport)
            _ = try await client.pages()

            let result = try await client.publish(file, name: "fresh")
            #expect(result.slug == "fresh")
            _ = try await client.pages()
            #expect(transport.requests == ["GET /pages?limit=1000", "POST /upload", "GET /pages?limit=1000"])
        }
    }

    @Test func rateLimitIsSurfacedAndNeverRetried() async {
        let transport = FakeTransport { _, _ in .error(429, "Too many requests. Please try again later.", retryAfter: "90") }
        let client = makeClient(transport)

        let error = await thrownUptfError { try await client.pages() }
        guard case .rateLimited(let retryAfter)? = error else {
            Issue.record("expected rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == 90)
        #expect(error?.localizedDescription == "Too many changes in a short time. Try again in 2 minutes.")
        #expect(transport.requests.count == 1)
    }

    @Test func rateLimitWithoutRetryAfterHeader() async {
        let transport = FakeTransport { _, _ in .error(429, "Too many requests") }
        let client = makeClient(transport)
        let error = await thrownUptfError { try await client.pages() }
        #expect(error?.localizedDescription == "Too many changes in a short time. Try again later.")
        #expect(transport.requests.count == 1)
    }

    @Test func aMissingLinkIsNotInYourAccount() async {
        let transport = FakeTransport { _, _ in .error(404, "Page not found") }
        let client = makeClient(transport)
        let error = await thrownUptfError { try await client.page("ghost") }
        #expect(error?.localizedDescription == "This link isn't in your account anymore.")
        #expect(error?.statusCode == 404)
    }

    @Test func serverMessagesPassThroughVerbatim() async {
        let transport = FakeTransport { _, _ in .error(403, "Password protection is available on Pro and above") }
        let client = makeClient(transport)
        let error = await thrownUptfError { try await client.setPassword("hunter22", for: "mysite") }
        #expect(error?.localizedDescription == "Password protection is available on Pro and above")
        #expect(error?.statusCode == 403)
    }
}

@Suite("PageCache")
struct PageCacheTests {
    @Test func staleListsAreNotServed() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = PageCache(lifetime: 60, now: { clock.now })
        await cache.store([makePage(id: "a", name: "one")])
        #expect(await cache.current()?.count == 1)
        clock.advance(61)
        #expect(await cache.current() == nil)
    }

    @Test func replaceOnlyTouchesCachedPages() async {
        let cache = PageCache()
        await cache.replace(makePage(id: "a", name: "one"))
        #expect(await cache.current() == nil)  // nothing cached: no partial list appears

        await cache.store([makePage(id: "a", name: "one")])
        await cache.replace(makePage(id: "a", name: "uno"))
        await cache.replace(makePage(id: "b", name: "two"))
        #expect(await cache.current()?.map(\.slug) == ["uno"])
    }

    @Test func updateEditsTheMatchingPage() async {
        let cache = PageCache()
        await cache.store([makePage(id: "a", name: "one")])
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        await cache.update("one") { $0.expiresAt = date }
        #expect(await cache.find("a")?.expiresAt == date)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

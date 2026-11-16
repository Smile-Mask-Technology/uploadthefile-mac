import Foundation

/// The account's page list, kept in memory so repeated reads cost no API requests.
///
/// Free accounts only get 20 reads per hour, so `GET /pages` is fetched once and everything
/// else (`page(_:)`, resolving names, `ls`) is answered from here until the list is refreshed,
/// goes stale, or a write changes it.
actor PageCache {
    private var pages: [PageInfo]?
    private var storedAt: Date?
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameter lifetime: seconds a stored list is served before it counts as stale.
    init(lifetime: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.now = now
    }

    /// The cached list, or nil when nothing is stored, it was invalidated, or it is stale.
    func current() -> [PageInfo]? {
        guard let pages, let storedAt, now().timeIntervalSince(storedAt) < lifetime else { return nil }
        return pages
    }

    /// A cached page whose name or id equals `reference`.
    func find(_ reference: String) -> PageInfo? {
        current()?.first { $0.slug == reference || $0.id == reference }
    }

    func store(_ pages: [PageInfo]) {
        self.pages = pages
        storedAt = now()
    }

    /// Forget everything; the next read goes to the server.
    func invalidate() {
        pages = nil
        storedAt = nil
    }

    /// Swaps in a fresh copy of a page that is already cached (same id). Does nothing otherwise,
    /// so a partial list can never pass for a complete one.
    func replace(_ page: PageInfo) {
        guard let index = pages?.firstIndex(where: { $0.id == page.id }) else { return }
        pages?[index] = page
    }

    /// Drops the page whose name or id equals `reference`.
    func remove(_ reference: String) {
        pages?.removeAll { $0.slug == reference || $0.id == reference }
    }

    /// Edits the cached page whose name or id equals `reference`.
    func update(_ reference: String, _ change: (inout PageInfo) -> Void) {
        guard let index = pages?.firstIndex(where: { $0.slug == reference || $0.id == reference }) else { return }
        change(&pages![index])
    }
}

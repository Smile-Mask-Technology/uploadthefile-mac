import CryptoKit
public import Foundation

/// A content fingerprint used to tell whether a published file or folder has changed.
public enum Fingerprint {
    /// SHA-256 (hex) of a file's contents, streamed in 1 MiB chunks.
    /// For a folder: SHA-256 over the sorted `relative path NUL file-hash LF` lines of the files
    /// ``FolderZipper`` would include, so it changes exactly when the published archive would.
    public static func sha256(of url: URL, includeHidden: Bool = false) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UptfError.unexpected("\(url.path) does not exist.")
        }
        if isDirectory.boolValue {
            var manifest = SHA256()
            for entry in try FolderZipper.previewEntries(folder: url, includeHidden: includeHidden) {
                let fileHash = try sha256(ofFile: url.appendingPathComponent(entry))
                manifest.update(data: Data("\(entry)\0\(fileHash)\n".utf8))
            }
            return hex(manifest.finalize())
        }
        return try sha256(ofFile: url)
    }

    private static func sha256(ofFile url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw UptfError.unexpected("Can't read \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One published file or folder, tied to its page by the page's immutable `id`.
public struct PublishedEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case file
        case folder
    }

    /// The page's immutable id (``PageInfo/id``). It survives renames, including renames made
    /// on the website, so it is what ties a local file to its page.
    public var id: String
    /// Site origin the page lives on (a dev server and production keep separate entries).
    public var origin: String
    /// The page's current name as last seen on the server; nil for an id-only link. Just data:
    /// it is refreshed from the server list, never used to identify the entry.
    public var name: String?
    public var url: String
    public var kind: Kind
    /// True when a zip was published to be served as a website.
    public var hostedAsSite: Bool
    /// Where the file was when last published. The bookmark finds it again if it moves.
    public var lastKnownPath: String
    /// Security-scoped bookmark (falls back to a plain one) for the file or folder.
    public var bookmark: Data?
    /// SHA-256 of the contents at publish time (see ``Fingerprint``).
    public var sha256: String
    public var publishedAt: Date

    /// Entries are made by `PublishedIndex` when something is published; this exists for fixtures.
    public init(
        id: String, origin: String, name: String?, url: String, kind: Kind, hostedAsSite: Bool,
        lastKnownPath: String, bookmark: Data? = nil, sha256: String, publishedAt: Date
    ) {
        self.id = id
        self.origin = origin
        self.name = name
        self.url = url
        self.kind = kind
        self.hostedAsSite = hostedAsSite
        self.lastKnownPath = lastKnownPath
        self.bookmark = bookmark
        self.sha256 = sha256
        self.publishedAt = publishedAt
    }

    /// What the API calls the page in URLs: the name, or the id when there is no name.
    public var slug: String { name ?? id }
}

/// The local record of what was published from where, kept as JSON in Application Support.
/// Entries are keyed by page id, so renaming a page on the website keeps the local link.
///
/// Every call re-reads the file and every write is atomic, so the app and the CLI can share it.
public actor PublishedIndex {
    private struct File: Codable {
        static let currentVersion = 2
        var version = File.currentVersion
        var entries: [PublishedEntry] = []
    }

    private struct Header: Decodable {
        var version: Int?
    }

    private let fileURL: URL
    private let origin: String

    public static func defaultFileURL() throws -> URL {
        try AppSupport.directory().appendingPathComponent("published-index.json")
    }

    /// - Parameters:
    ///   - fileURL: the JSON file (created on first write).
    ///   - origin: only entries for this site origin are visible and reconciled.
    public init(fileURL: URL, origin: String) {
        self.fileURL = fileURL
        self.origin = origin
    }

    public init(config: UptfConfig) throws {
        self.init(fileURL: try Self.defaultFileURL(), origin: config.origin)
    }

    // MARK: Queries

    public func entries() throws -> [PublishedEntry] {
        try load().entries.filter { $0.origin == origin }
    }

    public func entry(forID id: String) throws -> PublishedEntry? {
        try entries().first { $0.id == id }
    }

    /// The entry whose recorded name or id equals `reference`. The recorded name can be out of
    /// date after a rename on the website until the next ``reconcile(with:)``.
    public func entry(matching reference: String) throws -> PublishedEntry? {
        try entries().first { $0.name == reference || $0.id == reference }
    }

    /// The entry recorded for this file or folder. Matches by path first, then by following the
    /// stored bookmarks, so a file that was moved or renamed in Finder is still recognised.
    public func entry(for fileURL: URL) throws -> PublishedEntry? {
        let path = Self.normalizedPath(fileURL)
        let all = try entries()
        if let hit = all.first(where: { Self.normalizedPath(URL(fileURLWithPath: $0.lastKnownPath)) == path }) {
            return hit
        }
        return all.first { entry in
            guard let resolved = Self.resolve(entry.bookmark) else { return false }
            return Self.normalizedPath(resolved) == path
        }
    }

    /// True when `fileURL` has never been published or its contents differ from the last publish.
    /// The entry is found by the file's path, then its bookmark.
    public func changedSincePublish(_ fileURL: URL) throws -> Bool {
        guard let entry = try entry(for: fileURL) else { return true }
        return try changedSincePublish(fileURL, entry: entry)
    }

    /// True when `fileURL`'s contents differ from what was uploaded for `entry`. The entry is
    /// taken as given, not looked up again by path, so it can't be mixed up with the entry of
    /// another page that was recorded at the same path.
    public func changedSincePublish(_ fileURL: URL, entry: PublishedEntry) throws -> Bool {
        try Fingerprint.sha256(of: fileURL) != entry.sha256
    }

    /// Where the entry's file is now, following its bookmark if the recorded path is gone.
    public func currentURL(for entry: PublishedEntry) -> URL? {
        let recorded = URL(fileURLWithPath: entry.lastKnownPath)
        if FileManager.default.fileExists(atPath: recorded.path) { return recorded }
        return Self.resolve(entry.bookmark)
    }

    // MARK: Changes

    /// Records (or replaces) the entry for page `id`. Hashes `fileURL` unless `sha256` is given.
    /// Another entry for the same file path is replaced too: one file, one link.
    @discardableResult
    public func record(
        fileURL: URL, id: String, name: String?, url: String, kind: PublishedEntry.Kind,
        hostedAsSite: Bool = false, sha256: String? = nil, publishedAt: Date = Date()
    ) throws -> PublishedEntry {
        let entry = PublishedEntry(
            id: id, origin: origin, name: name, url: url, kind: kind, hostedAsSite: hostedAsSite,
            lastKnownPath: Self.normalizedPath(fileURL), bookmark: Self.makeBookmark(fileURL),
            sha256: try sha256 ?? Fingerprint.sha256(of: fileURL), publishedAt: publishedAt)
        var file = try load()
        let path = entry.lastKnownPath
        file.entries.removeAll { $0.origin == origin && ($0.id == id || $0.lastKnownPath == path) }
        file.entries.append(entry)
        try save(file)
        return entry
    }

    public func remove(id: String) throws {
        var file = try load()
        let before = file.entries.count
        file.entries.removeAll { $0.origin == origin && $0.id == id }
        if file.entries.count != before { try save(file) }
    }

    /// Takes the current name and URL of a page the server just told us about (after a rename,
    /// or whenever a fresh copy of the page is in hand). Does nothing if the page is not recorded.
    public func apply(_ page: PageInfo) throws {
        var file = try load()
        guard let index = file.entries.firstIndex(where: { $0.origin == origin && $0.id == page.id }) else { return }
        guard file.entries[index].name != page.name || file.entries[index].url != page.url else { return }
        file.entries[index].name = page.name
        file.entries[index].url = page.url
        try save(file)
    }

    /// Takes the current name and URL of every recorded page that is in the server's list, matched
    /// by page id, so a rename on the website keeps the link. Entries that are not in the list
    /// stay as they are: the list may belong to another account, or have been cut short, and
    /// the local record of which file is which link can't be rebuilt once it is gone.
    /// Entries leave the index only through ``remove(id:)``.
    public func reconcile(with pages: [PageInfo]) throws {
        let live = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var file = try load()
        var changed = false
        for position in file.entries.indices where file.entries[position].origin == origin {
            guard let page = live[file.entries[position].id] else { continue }
            guard file.entries[position].name != page.name || file.entries[position].url != page.url else { continue }
            file.entries[position].name = page.name
            file.entries[position].url = page.url
            changed = true
        }
        if changed { try save(file) }
    }

    // MARK: Storage

    private func load() throws -> File {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return File() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: fileURL)
            // A file from before entries were keyed by page id has nothing we can map to ids.
            if let header = try? decoder.decode(Header.self, from: data), (header.version ?? 0) < File.currentVersion {
                return File()
            }
            return try decoder.decode(File.self, from: data)
        } catch {
            throw UptfError.unexpected(
                "The list of what you've put online from this Mac at \(fileURL.path) could not be read (\(error.localizedDescription)). Move it aside to start fresh.")
        }
    }

    private func save(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    // MARK: Paths and bookmarks

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func makeBookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        for options: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI], [.withoutUI]] {
            if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return nil
    }
}

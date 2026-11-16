public import Foundation

/// What is about to be published: a single file or a folder that will be zipped.
public struct PublishPlan: Sendable, Equatable {
    public var url: URL
    public var kind: PublishedEntry.Kind
    /// For folders: the relative paths that will go into the zip (exactly what `FolderZipper` includes).
    public var entries: [String]
    /// For files: the size in bytes.
    public var fileSize: Int64?
    public var includeHidden: Bool

    /// `Publisher.prepare` is how a real plan is made; this exists for fixtures (snapshots, previews).
    public init(url: URL, kind: PublishedEntry.Kind, entries: [String] = [], fileSize: Int64? = nil, includeHidden: Bool = false) {
        self.url = url
        self.kind = kind
        self.entries = entries
        self.fileSize = fileSize
        self.includeHidden = includeHidden
    }

    /// True when a folder has an `index.html` at its top level, i.e. it is a website.
    public var hasRootIndexHtml: Bool { entries.contains("index.html") }
}

public struct PublishOutcome: Sendable, Equatable {
    public var result: PublishResult
    /// The index record, nil if it could not be written (the page is live regardless).
    public var entry: PublishedEntry?
    /// Why the index record is missing, when it is.
    public var historyError: String?
}

/// Publishes files and folders and keeps the local ``PublishedIndex`` in step.
///
/// Reads are scarce on free accounts (20 per hour), so the flows here use as few as they can:
/// publishing costs one write (plus one read only when the server's answer carries no page id),
/// and updating costs one list read to find the page by id, which also notices renames done on
/// the website.
public struct Publisher: Sendable {
    public let client: UptfClient
    public let index: PublishedIndex

    public init(client: UptfClient, index: PublishedIndex) {
        self.client = client
        self.index = index
    }

    /// Inspects `url` without uploading anything. Refuses credential locations unless
    /// `allowSensitive`, and files over ``UptfClient/maxUploadBytes``.
    public func prepare(_ url: URL, allowSensitive: Bool = false, includeHidden: Bool = false) throws -> PublishPlan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UptfError.unexpected("No such file or folder: \(url.path)")
        }
        if !allowSensitive, let reason = SensitivePath.reason(for: url) {
            throw UptfError.unexpected("Not putting “\(url.lastPathComponent)” online: \(reason).")
        }
        if isDirectory.boolValue {
            let entries = try FolderZipper.previewEntries(folder: url, includeHidden: includeHidden)
            guard !entries.isEmpty else {
                throw UptfError.unexpected("There is nothing to put online in \(url.lastPathComponent): every file is left out, or the folder is empty.")
            }
            return PublishPlan(url: url, kind: .folder, entries: entries, fileSize: nil, includeHidden: includeHidden)
        }
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size <= UptfClient.maxUploadBytes else { throw UptfError.tooLarge(bytes: size) }
        return PublishPlan(url: url, kind: .file, entries: [], fileSize: size, includeHidden: includeHidden)
    }

    /// The server's current page for a recorded entry, found by its immutable id. The index is
    /// brought up to date (a rename on the website shows up as a new name). Uses the client's
    /// cached list; a page that is not in it is asked for by id (one more read). An entry is
    /// dropped only when the server answers that the page does not exist: a page missing from
    /// the list may be another account's, or past the end of a long list.
    public func livePage(for entry: PublishedEntry) async throws -> PageInfo? {
        let pages = try await client.pages()
        if let page = pages.first(where: { $0.id == entry.id }) {
            try? await index.apply(page)
            return page
        }
        do {
            let page = try await client.page(entry.id)
            try? await index.apply(page)
            return page
        } catch UptfError.server(404, _) {
            // Not in this account: deleted on the website, or published while signed in to
            // another account. The entry stays, so signing back in to that account keeps the
            // link; only an explicit delete removes an entry.
            return nil
        }
    }

    /// The recorded entry for `url` and its page, if both still exist.
    public func existingPublication(for url: URL) async throws -> (entry: PublishedEntry, page: PageInfo)? {
        guard let entry = try await index.entry(for: url) else { return nil }
        return try await existingPublication(for: entry)
    }

    /// `entry` and its page, if the page still exists. The entry is the one the caller means;
    /// nothing is looked up by file path.
    public func existingPublication(for entry: PublishedEntry) async throws -> (entry: PublishedEntry, page: PageInfo)? {
        guard let page = try await livePage(for: entry) else { return nil }
        return (entry, page)
    }

    /// Uploads the plan as a new page. `hostAsSite` serves the zip as a website.
    public func publish(_ plan: PublishPlan, name: String? = nil, hostAsSite: Bool = false) async throws -> PublishOutcome {
        try await withUpload(plan) { upload in
            let result = try await client.publish(upload, name: name, hostAsSite: hostAsSite)
            if let id = result.id {
                // The slug is the name, or the id when the page has no name.
                return await finish(
                    plan, result: result, id: id, name: result.slug == id ? nil : result.slug, hostAsSite: hostAsSite)
            }
            // A server that does not send the page id: read the page. The client just cleared
            // its cache, so this is one `GET /pages/{slug}`. If it fails the page is live
            // anyway; only the history is missing.
            do {
                let page = try await client.page(result.slug)
                return await finish(plan, result: result, id: page.id, name: page.name, hostAsSite: hostAsSite)
            } catch {
                return PublishOutcome(
                    result: result, entry: nil,
                    historyError: (error as? UptfError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }

    /// Re-uploads the plan to the page recorded in `entry`; the URL stays the same. The page is
    /// found, and replaced, by id, so it works even after the page was renamed on the website.
    public func update(_ plan: PublishPlan, entry: PublishedEntry) async throws -> PublishOutcome {
        guard let page = try await livePage(for: entry) else {
            throw UptfError.unexpected(
                "The link \(entry.url) isn't in your account anymore, so there is nothing to replace. Get a new link for it instead.")
        }
        return try await withUpload(plan) { upload in
            let result = try await client.replace(upload, page: page, hostAsSite: entry.hostedAsSite)
            return await finish(plan, result: result, id: page.id, name: page.name, hostAsSite: entry.hostedAsSite)
        }
    }

    private func finish(
        _ plan: PublishPlan, result: PublishResult, id: String, name: String?, hostAsSite: Bool
    ) async -> PublishOutcome {
        do {
            let entry = try await index.record(
                fileURL: plan.url, id: id, name: name, url: result.url, kind: plan.kind,
                hostedAsSite: hostAsSite,
                sha256: Fingerprint.sha256(of: plan.url, includeHidden: plan.includeHidden))
            return PublishOutcome(result: result, entry: entry, historyError: nil)
        } catch {
            return PublishOutcome(result: result, entry: nil, historyError: error.localizedDescription)
        }
    }

    /// Zips folders into a temporary file for the duration of `body`.
    private func withUpload<T>(_ plan: PublishPlan, _ body: (URL) async throws -> T) async throws -> T {
        switch plan.kind {
        case .file:
            return try await body(plan.url)
        case .folder:
            let zip = try await FolderZipper.zip(folder: plan.url, includeHidden: plan.includeHidden)
            defer { try? FileManager.default.removeItem(at: zip.url.deletingLastPathComponent()) }
            return try await body(zip.url)
        }
    }
}

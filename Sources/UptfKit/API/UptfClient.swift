public import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Reads dates with or without fractional seconds, writes them without.
struct FlexibleDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return try Date.ISO8601FormatStyle().parse(string)
    }
}

/// A friendly, typed wrapper over the generated OpenAPI client. Every method signs requests
/// with the stored token (refreshing it as needed) and throws ``UptfError``.
public struct UptfClient: Sendable {
    /// Largest file the app uploads (the API's buffered upload limit): 50 MB.
    public static let maxUploadBytes: Int64 = 50 * 1024 * 1024
    /// How many pages one `GET /pages` asks for (the API's maximum). A list shorter than this is complete.
    public static let listLimit = 1000

    public let config: UptfConfig
    private let client: Client
    /// Shared by every copy of this client.
    let cache: PageCache

    /// The normal way to build a client: Keychain tokens, `URLSession` for transport and refresh.
    public init(
        config: UptfConfig, store: any TokenStore = KeychainTokenStore(),
        session: URLSession = .uptfDefault()
    ) {
        let tokens = TokenManager(
            origin: config.origin, store: store,
            refresher: OAuthClient(config: config, loader: session))
        self.init(config: config, tokens: tokens, transport: URLSessionTransport(configuration: .init(session: session)))
    }

    /// Full control over token handling and transport (tests, custom stacks).
    init(config: UptfConfig, tokens: TokenManager, transport: any ClientTransport, cache: PageCache = PageCache()) {
        self.config = config
        self.cache = cache
        self.client = Client(
            serverURL: config.apiBase,
            configuration: Configuration(dateTranscoder: FlexibleDateTranscoder()),
            transport: transport,
            middlewares: [
                ErrorMappingMiddleware(),
                ExplicitNullExpiryMiddleware(),
                AuthMiddleware(tokens: tokens),
            ])
    }

    // MARK: Reading
    //
    // Free accounts only get 20 reads and 20 writes per hour, so reading is deliberately thrifty:
    // one `GET /pages` fills an in-memory cache that `pages()` and `page(_:)` serve from, and the
    // per-page settings are only fetched when asked for. Nothing is retried automatically.

    /// All your pages and sites, newest first (up to 1000), from one request. The result is kept
    /// in memory until `refresh` is true or a write changes something.
    public func pages(refresh: Bool = false) async throws -> [PageInfo] {
        if !refresh, let cached = await cache.current() { return cached }
        let output = try await call { try await client.listPages(.init(query: .init(limit: Self.listLimit))) }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        let pages = try ok.body.json.data.pages.map(PageInfo.init)
        await cache.store(pages)
        return pages
    }

    /// One page, by name or id. Served from the cached list when it is there, otherwise one request.
    public func page(_ slug: String) async throws -> PageInfo {
        if let hit = await cache.find(slug) { return hit }
        let output = try await call { try await client.getPage(.init(path: .init(slug: slug))) }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        return PageInfo(try ok.body.json.data.page)
    }

    /// A page, and with `includeSettings` its password, email-gate and display state too.
    /// What the page itself carries (a current server puts all three in the list) costs nothing;
    /// each one it lacks costs one more request (one after the other, so a rate limit stops the
    /// rest), so ask only for the one page the user is looking at.
    /// Settings the server won't tell us (for example plan limits) come back nil.
    public func details(_ slug: String, includeSettings: Bool = false) async throws -> PageDetails {
        let page = try await page(slug)
        var details = PageDetails(
            page: page, passwordProtected: page.passwordProtected,
            emailGateEnabled: page.emailGateEnabled, displayMode: page.displayMode)
        guard includeSettings else { return details }
        if details.passwordProtected == nil {
            details.passwordProtected = try await optional { try await passwordProtected(slug) }
        }
        // The message needs the read, so only a gate known to be off skips it.
        if details.emailGateEnabled != false {
            let gate = try await optional { try await emailGate(slug) }
            details.emailGateEnabled = gate?.enabled ?? details.emailGateEnabled
            details.emailGateMessage = gate?.message
        }
        if details.displayMode == nil {
            details.displayMode = try await optional { try await displayMode(slug) }
        }
        return details
    }

    /// nil when the server refuses this one setting; rate limits and sign-in problems still throw.
    private func optional<T: Sendable>(_ read: () async throws -> T) async throws -> T? {
        do {
            return try await read()
        } catch UptfError.server {
            return nil
        }
    }

    public func passwordProtected(_ slug: String) async throws -> Bool {
        let output = try await call { try await client.getPagePassword(.init(path: .init(slug: slug))) }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        return try ok.body.json.data.protected
    }

    public func emailGate(_ slug: String) async throws -> (enabled: Bool, message: String?) {
        let output = try await call { try await client.getEmailGate(.init(path: .init(slug: slug))) }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        let data = try ok.body.json.data
        return (data.enabled, data.message)
    }

    public func displayMode(_ slug: String) async throws -> DisplayMode {
        let output = try await call { try await client.getPageDisplay(.init(path: .init(slug: slug))) }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        return DisplayMode(rawValue: try ok.body.json.data.mode.rawValue) ?? .preview
    }

    // MARK: Publishing

    /// Uploads a file as a new page. `hostAsSite` serves a `.zip` as a website instead of a download.
    /// Files over ``maxUploadBytes`` are refused before anything is sent.
    public func publish(_ fileURL: URL, name: String? = nil, hostAsSite: Bool = false) async throws -> PublishResult {
        let file = try Self.loadUpload(fileURL)
        var parts: [Components.Schemas.UploadCreateForm] = [
            .file(.init(payload: .init(body: HTTPBody(file.data)), filename: file.fileName))
        ]
        if let name, !name.isEmpty {
            parts.append(.name(.init(payload: .init(body: HTTPBody(name)))))
        }
        if hostAsSite {
            parts.append(.host(.init(payload: .init(body: HTTPBody("true")))))
        }
        let output = try await uploadCall(size: file.size) {
            try await client.createPage(.init(body: .multipartForm(MultipartBody(parts))))
        }
        guard case .created(let created) = output else { throw unexpected(output) }
        await cache.invalidate()
        return PublishResult(try created.body.json)
    }

    /// Replaces the file behind an existing link. The URL stays the same. The page is addressed
    /// by its id, so a name that changed or moved to another page can't redirect the upload;
    /// the name goes along for servers that find the page by name only.
    public func replace(_ fileURL: URL, page: PageInfo, hostAsSite: Bool = false) async throws -> PublishResult {
        let file = try Self.loadUpload(fileURL)
        var parts: [Components.Schemas.UploadUpdateForm] = [
            .file(.init(payload: .init(body: HTTPBody(file.data)), filename: file.fileName)),
            .id(.init(payload: .init(body: HTTPBody(page.id)))),
            .name(.init(payload: .init(body: HTTPBody(page.slug)))),
        ]
        if hostAsSite {
            parts.append(.host(.init(payload: .init(body: HTTPBody("true")))))
        }
        let output = try await uploadCall(size: file.size) {
            try await client.updatePage(.init(body: .multipartForm(MultipartBody(parts))))
        }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        await cache.invalidate()
        return PublishResult(try ok.body.json)
    }

    // MARK: Managing

    /// Renames the public link. The old URL stops working.
    public func rename(_ slug: String, to name: String) async throws -> PageInfo {
        let output = try await call {
            try await client.renamePage(.init(path: .init(slug: slug), body: .json(.init(name: name))))
        }
        guard case .ok(let ok) = output else { throw unexpected(output) }
        let page = PageInfo(try ok.body.json.data.page)
        await cache.replace(page)
        return page
    }

    /// Deletes the page and its link.
    public func unpublish(_ slug: String) async throws {
        let output = try await call { try await client.deletePage(.init(path: .init(slug: slug))) }
        guard case .ok = output else { throw unexpected(output) }
        await cache.remove(slug)
    }

    /// Protects the link with a password (6–72 characters). Needs a plan that includes it.
    public func setPassword(_ password: String, for slug: String) async throws {
        guard (6...72).contains(password.count) else {
            throw UptfError.unexpected("A password must be 6 to 72 characters long.")
        }
        let output = try await call {
            try await client.setPagePassword(.init(path: .init(slug: slug), body: .json(.init(password: password))))
        }
        guard case .ok = output else { throw unexpected(output) }
        await cache.update(slug) { $0.passwordProtected = true }
    }

    public func removePassword(for slug: String) async throws {
        let output = try await call { try await client.removePagePassword(.init(path: .init(slug: slug))) }
        guard case .ok = output else { throw unexpected(output) }
        await cache.update(slug) { $0.passwordProtected = false }
    }

    /// Turns the email gate on or off. `message` is the prompt shown to visitors; nil leaves it
    /// unchanged, an empty string clears it.
    public func setEmailGate(_ slug: String, enabled: Bool, message: String? = nil) async throws {
        let output = try await call {
            try await client.setEmailGate(
                .init(path: .init(slug: slug), body: .json(.init(enabled: enabled, message: message))))
        }
        guard case .ok = output else { throw unexpected(output) }
        await cache.update(slug) { $0.emailGateEnabled = enabled }
    }

    /// Sets when the link stops working; nil = never.
    public func setExpiry(_ slug: String, _ date: Date?) async throws {
        let output = try await call {
            try await client.setPageExpiry(.init(path: .init(slug: slug), body: .json(.init(expiresAt: date))))
        }
        guard case .ok = output else { throw unexpected(output) }
        await cache.update(slug) { $0.expiresAt = date }
    }

    public func setDisplay(_ slug: String, mode: DisplayMode) async throws {
        guard let apiMode = Components.Schemas.DisplayMode(rawValue: mode.rawValue) else {
            throw UptfError.unexpected("Unknown display mode \(mode.rawValue).")
        }
        let output = try await call {
            try await client.setPageDisplay(.init(path: .init(slug: slug), body: .json(.init(mode: apiMode))))
        }
        guard case .ok = output else { throw unexpected(output) }
        await cache.update(slug) { $0.displayMode = mode }
    }

    // MARK: Plumbing

    private struct LoadedFile {
        var data: Data
        var fileName: String
        var size: Int64
    }

    private static func loadUpload(_ fileURL: URL) throws -> LoadedFile {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        } catch {
            throw UptfError.unexpected("Can't read \(fileURL.path): \(error.localizedDescription)")
        }
        if values.isDirectory == true {
            throw UptfError.unexpected("\(fileURL.lastPathComponent) is a folder, not a file.")
        }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maxUploadBytes else { throw UptfError.tooLarge(bytes: size) }
        do {
            return LoadedFile(data: try Data(contentsOf: fileURL), fileName: fileURL.lastPathComponent, size: size)
        } catch {
            throw UptfError.unexpected("Can't read \(fileURL.path): \(error.localizedDescription)")
        }
    }

    /// Like `call`, but a 413 becomes ``UptfError/tooLarge(bytes:)`` for this upload.
    private func uploadCall<T>(size: Int64, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await call(operation)
        } catch UptfError.server(413, _) {
            throw UptfError.tooLarge(bytes: size)
        }
    }

    /// Runs a generated-client call and converts whatever it throws into ``UptfError``.
    private func call<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as UptfError {
            throw error
        } catch let error as ClientError {
            if let inner = error.underlyingError as? UptfError { throw inner }
            if error.underlyingError is URLError {
                throw UptfError.network(error.underlyingError)
            }
            throw UptfError.unexpected("Upload the File sent back something we couldn't read: \(error.causeDescription)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UptfError.network(error)
        }
    }

    private func unexpected<T>(_ output: T) -> UptfError {
        .unexpected("Upload the File sent back something we couldn't read.")
    }
}

extension PublishResult {
    init(_ result: Components.Schemas.UploadResultEnvelope) {
        self.init(url: result.data.url, slug: result.data.slug, hasHtml: result.data.hasHtml, id: result.data.id)
    }
}

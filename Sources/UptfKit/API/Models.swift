public import Foundation

/// How a single-file page is shown to visitors.
public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case preview
    case previewDownload = "preview_download"
    case download
}

/// A page or site published on upload.tf.
public struct PageInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Public custom name (the subdomain label); nil for an id-only link.
    public var name: String?
    public var url: String
    public var fileName: String
    /// `site` for a hosted ZIP, otherwise the file type (`html`, `zip`, `pdf`, ...).
    public var kind: String
    public var sizeBytes: Int64
    public var fileCount: Int
    public var createdAt: Date
    /// nil = never expires.
    public var expiresAt: Date?
    public var chatEnabled: Bool
    /// Protection state the list carries. Each is nil when the server's answer does not have it
    /// (an older server): nil means "not known", not "off".
    public var passwordProtected: Bool?
    public var emailGateEnabled: Bool?
    public var displayMode: DisplayMode?

    /// What the API calls the page in URLs: the name, or the id when there is no name.
    public var slug: String { name ?? id }

    public init(
        id: String, name: String?, url: String, fileName: String, kind: String, sizeBytes: Int64,
        fileCount: Int, createdAt: Date, expiresAt: Date?, chatEnabled: Bool,
        passwordProtected: Bool? = nil, emailGateEnabled: Bool? = nil, displayMode: DisplayMode? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.fileName = fileName
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.chatEnabled = chatEnabled
        self.passwordProtected = passwordProtected
        self.emailGateEnabled = emailGateEnabled
        self.displayMode = displayMode
    }

    init(_ page: Components.Schemas.ApiPage) {
        self.init(
            id: page.id, name: page.name, url: page.url, fileName: page.fileName, kind: page.kind,
            sizeBytes: page.sizeBytes, fileCount: page.fileCount, createdAt: page.createdAt,
            expiresAt: page.expiresAt, chatEnabled: page.chatEnabled,
            passwordProtected: page.passwordProtected, emailGateEnabled: page.emailGateEnabled,
            displayMode: page.displayMode.flatMap { DisplayMode(rawValue: $0.rawValue) })
    }
}

/// A page plus its protection settings. Settings the server would not tell us (for example
/// because the plan does not include the feature) are nil.
public struct PageDetails: Codable, Sendable, Equatable {
    public var page: PageInfo
    public var passwordProtected: Bool?
    public var emailGateEnabled: Bool?
    public var emailGateMessage: String?
    public var displayMode: DisplayMode?
}

/// The result of publishing or replacing a file.
public struct PublishResult: Codable, Sendable, Equatable {
    public var url: String
    public var slug: String
    /// Whether the page/site has an `index.html`.
    public var hasHtml: Bool
    /// The page's id. Nil when the server's answer does not carry one (an older server).
    public var id: String?
}

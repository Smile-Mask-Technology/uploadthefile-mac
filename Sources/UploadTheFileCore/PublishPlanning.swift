import Foundation
import UptfKit

// What has to be decided before a file or folder is uploaded, kept apart from any UI so the rules
// (refuse, warn, list, ask) can be tested without a window.

/// Why a link is being made: dropping something new, or the "Replace File" button on a row.
public enum PublishIntent: Sendable, Equatable {
    /// A file or folder the user chose. It may turn out to be published already.
    case publish
    /// Replace the content behind the file's existing link.
    case updateLink
}

/// The exact list a folder upload contains, for the confirmation.
public struct FolderListing: Equatable, Sendable {
    /// How many names the confirmation lists before saying "and N more" (same as the CLI).
    public static let displayLimit = 200
    /// What is never sent from a folder (same wording as the CLI).
    public static let leftOutNote = "Left out: hidden files, files that hold passwords or keys, and developer folders such as .git and node_modules."

    public var folderName: String
    public var entries: [String]
    /// True when the folder has an `index.html` at its top level, so it opens as a website.
    public var servedAsWebsite: Bool

    public init(folderName: String, entries: [String], servedAsWebsite: Bool) {
        self.folderName = folderName
        self.entries = entries
        self.servedAsWebsite = servedAsWebsite
    }

    public var shown: [String] { Array(entries.prefix(Self.displayLimit)) }
    public var hiddenCount: Int { max(0, entries.count - Self.displayLimit) }
    public var summary: String {
        "\(entries.count) file\(entries.count == 1 ? "" : "s") will go online"
    }
}

/// A link that already exists for a local file or folder.
public struct ExistingPublication: Equatable, Sendable {
    public var entry: PublishedEntry
    public var pageURL: String
    /// The local copy differs from what was uploaded.
    public var changed: Bool

    public init(entry: PublishedEntry, pageURL: String, changed: Bool) {
        self.entry = entry
        self.pageURL = pageURL
        self.changed = changed
    }
}

/// What the user can pick in a confirmation.
public enum PublishChoice: Sendable, Equatable {
    /// Put it online again with a new link.
    case publishNew
    /// Replace what is behind the existing link; the link stays the same.
    case updateExisting
    /// Do not upload; copy the link that already exists.
    case copyExistingLink
}

public struct PublishOption: Equatable, Sendable {
    public var choice: PublishChoice
    public var title: String
    public var isPrimary: Bool
}

/// An upload the app is about to do.
public struct UploadRequest: Equatable, Sendable {
    public var plan: PublishPlan
    /// The entry whose link is kept, or nil for a new page.
    public var update: PublishedEntry?

    public init(plan: PublishPlan, update: PublishedEntry? = nil) {
        self.plan = plan
        self.update = update
    }

    public var isUpdate: Bool { update != nil }
    /// A folder with a top-level index.html is a website (as with the CLI); updates keep the setting.
    public var hostAsSite: Bool {
        if let update { return update.hostedAsSite }
        return plan.kind == .folder && plan.hasRootIndexHtml
    }
}

/// Everything the confirmation sheet shows. Built when something needs a human decision.
public struct PublishConfirmation: Equatable, Sendable, Identifiable {
    public var url: URL
    public var plan: PublishPlan
    public var intent: PublishIntent
    /// Sensitive-path and hidden-path warnings, already phrased for the user.
    public var warnings: [String]
    public var folder: FolderListing?
    public var existing: ExistingPublication?

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(
        url: URL, plan: PublishPlan, intent: PublishIntent, warnings: [String],
        folder: FolderListing?, existing: ExistingPublication?
    ) {
        self.url = url
        self.plan = plan
        self.intent = intent
        self.warnings = warnings
        self.folder = folder
        self.existing = existing
    }

    public var title: String {
        if !warnings.isEmpty { return "Publish “\(name)”? It may be sensitive" }
        switch (intent, existing) {
        case (.updateLink, _):
            return "Replace “\(name)” and keep the same link?"
        case (.publish, let existing?):
            return existing.changed
                ? "“\(name)” is already online and has changed"
                : "“\(name)” is already online"
        case (.publish, nil):
            return "Publish “\(name)”?"
        }
    }

    /// The buttons, primary first. Cancel is always there too and is not listed.
    public var options: [PublishOption] {
        let replace = plan.kind == .folder ? "Replace Folder" : "Replace File"
        switch (intent, existing) {
        case (.updateLink, _?):
            return [PublishOption(choice: .updateExisting, title: replace, isPrimary: true)]
        case (.updateLink, nil):
            return []
        case (.publish, let existing?):
            let newLink = PublishOption(choice: .publishNew, title: "Publish as a New Link", isPrimary: false)
            if existing.changed {
                return [PublishOption(choice: .updateExisting, title: replace, isPrimary: true), newLink]
            }
            return [PublishOption(choice: .copyExistingLink, title: "Copy Link", isPrimary: true), newLink]
        case (.publish, nil):
            return [PublishOption(choice: .publishNew, title: "Publish", isPrimary: true)]
        }
    }

    /// The upload a choice leads to; nil when the choice uploads nothing.
    public func request(for choice: PublishChoice) -> UploadRequest? {
        switch choice {
        case .publishNew: return UploadRequest(plan: plan, update: nil)
        case .updateExisting: return existing.map { UploadRequest(plan: plan, update: $0.entry) }
        case .copyExistingLink: return nil
        }
    }
}

public enum PublishAssessment: Equatable, Sendable {
    /// Cannot be put online; the message says why (too large, nothing inside, missing, ...).
    case refused(String)
    /// Needs the user's decision first.
    case confirm(PublishConfirmation)
    /// Plain case: a normal file that is not published yet, or an explicit update of one.
    case upload(UploadRequest)
}

/// Looks at a file or folder and decides what happens next: refuse it, ask first, or upload.
public struct PublishAssessor: Sendable {
    public typealias Prepare = @Sendable (_ url: URL, _ allowSensitive: Bool) throws -> PublishPlan
    public typealias Lookup = @Sendable (_ url: URL) async throws -> ExistingPublication?

    private let prepare: Prepare
    private let lookup: Lookup
    private let home: URL

    public init(
        prepare: @escaping Prepare, lookup: @escaping Lookup,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.prepare = prepare
        self.lookup = lookup
        self.home = home
    }

    /// The real wiring: `Publisher.prepare`, and the existing link found in the index (which costs
    /// at most one cached list read when something is recorded for the path).
    public init(publisher: Publisher) {
        self.init(
            prepare: { url, allow in try publisher.prepare(url, allowSensitive: allow) },
            lookup: { url in
                guard let found = try await publisher.existingPublication(for: url) else { return nil }
                let changed = (try? await publisher.index.changedSincePublish(url)) ?? true
                return ExistingPublication(entry: found.entry, pageURL: found.page.url, changed: changed)
            })
    }

    public func assess(_ url: URL, intent: PublishIntent) async -> PublishAssessment {
        // The size limit and the empty-folder rule apply even to places we would only warn about.
        let plan: PublishPlan
        do {
            plan = try prepare(url, true)
        } catch {
            return .refused(UserMessage.text(for: error))
        }

        let existing: ExistingPublication?
        do {
            existing = try await lookup(url)
        } catch {
            return .refused(UserMessage.text(for: error))
        }
        if intent == .updateLink && existing == nil {
            return .refused(
                "The link for “\(url.lastPathComponent)” isn't in your account anymore, so there is nothing to replace. Get a new link for it instead.")
        }

        let warnings = Self.warnings(for: url, home: home)
        var folder: FolderListing?
        if plan.kind == .folder {
            folder = FolderListing(
                folderName: url.lastPathComponent, entries: plan.entries, servedAsWebsite: plan.hasRootIndexHtml)
        }
        let alreadyPublished = intent == .publish && existing != nil
        if warnings.isEmpty && folder == nil && !alreadyPublished {
            return .upload(UploadRequest(plan: plan, update: intent == .updateLink ? existing?.entry : nil))
        }
        return .confirm(
            PublishConfirmation(
                url: url, plan: plan, intent: intent, warnings: warnings, folder: folder, existing: existing))
    }

    /// Why this path deserves a second look: credential locations, secret-looking names, hidden paths.
    public static func warnings(for url: URL, home: URL) -> [String] {
        let name = url.lastPathComponent
        if let reason = SensitivePath.reason(for: url, home: home) {
            return ["Careful with “\(name)”: \(reason)."]
        }
        if let hidden = hiddenComponent(of: url, home: home) {
            return hidden == name
                ? ["Careful with “\(name)”: it is a hidden file or folder."]
                : ["Careful with “\(name)”: it is inside the hidden folder “\(hidden)”."]
        }
        return []
    }

    /// The first path component (below the home folder when inside it) that starts with a dot.
    static func hiddenComponent(of url: URL, home: URL) -> String? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = home.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let relevant = target.starts(with: base) ? Array(target.dropFirst(base.count)) : target
        return relevant.first { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }
}

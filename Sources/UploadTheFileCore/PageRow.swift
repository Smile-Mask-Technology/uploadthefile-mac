import Foundation
import UptfKit

/// What the list knows about the local copy of a published page.
public enum LocalFileState: Sendable, Equatable {
    /// Not published from this Mac (or the index has nothing for it).
    case notTracked
    /// Published from here but the file or folder can no longer be found.
    case missing
    case unchanged
    /// The contents differ from what was uploaded.
    case changed
}

/// One line in the menu bar list.
public struct PageRow: Identifiable, Equatable, Sendable {
    public var page: PageInfo
    public var entry: PublishedEntry?
    public var local: LocalFileState
    public var localURL: URL?

    public init(page: PageInfo, entry: PublishedEntry?, local: LocalFileState, localURL: URL?) {
        self.page = page
        self.entry = entry
        self.local = local
        self.localURL = localURL
    }

    public var id: String { page.id }
    public var title: String { page.slug }

    /// "Website" for a folder that opens as a website, otherwise the file type in capitals (PDF, HTML, ...).
    public var kindLabel: String {
        page.kind == "site" ? "Website" : page.kind.uppercased()
    }

    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: page.sizeBytes, countStyle: .file)
    }

    public var subtitle: String { "\(kindLabel) · \(sizeLabel)" }

    /// The link as the list shows it: without "https://" and a trailing slash,
    /// for example `launch-notes.upload.tf`.
    public var linkLabel: String { LinkLabel.short(page.url) }

    /// The local file changed since it went online: show the replace button.
    public var needsUpdate: Bool { local == .changed }

    /// The row's replace button: a folder is replaced as a whole.
    public var replaceTitle: String { entry?.kind == .folder ? "Replace Folder" : "Replace File" }

    /// "Show in Finder" is offered when the index knows the file and it still exists.
    public var canReveal: Bool { localURL != nil && (local == .changed || local == .unchanged) }

    /// Display mode only means something for a single file, not for a website.
    public var supportsDisplayMode: Bool { page.kind != "site" }
}

public enum LinkLabel {
    /// `https://launch-notes.upload.tf/` → `launch-notes.upload.tf`. Only the scheme and trailing
    /// slashes go; anything that is not an http(s) link comes back as it is.
    public static func short(_ link: String) -> String {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
            break
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? link : text
    }
}

public enum PageRows {
    /// Rows for `pages`, newest first. `localState` is asked only for pages the index knows.
    public static func make(
        pages: [PageInfo], entries: [PublishedEntry],
        localState: (PublishedEntry) -> (state: LocalFileState, url: URL?)
    ) -> [PageRow] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pages.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt { return lhs.element.createdAt > rhs.element.createdAt }
                return lhs.offset < rhs.offset
            }
            .map { _, page in
                guard let entry = byID[page.id] else {
                    return PageRow(page: page, entry: nil, local: .notTracked, localURL: nil)
                }
                let local = localState(entry)
                return PageRow(page: page, entry: entry, local: local.state, localURL: local.url)
            }
    }
}

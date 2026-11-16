import Foundation

/// The one question asked when more than one file or folder arrives at once (dropped on the icon,
/// picked in the file panel, or sent from Finder): without it every plain file would go online, each
/// with its own public link, the moment it was dropped. Nothing is checked or uploaded until the
/// user says yes; no publishes none of them.
public struct BatchConfirmation: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var url: URL
        public var isFolder: Bool
        public var name: String { url.lastPathComponent }
    }

    /// How many names are listed before "and N more" (the same limit as a folder's list).
    public static let displayLimit = FolderListing.displayLimit

    public private(set) var items: [Item]
    /// Where the items came from; the publish that follows is started with the same origin.
    public let origin: PublishSession.Origin

    /// A question is asked for a publish of more than one item. Replacing a link (one row at a
    /// time) never is.
    public static func isNeeded(itemCount: Int, intent: PublishIntent) -> Bool {
        intent == .publish && itemCount > 1
    }

    /// nil when no question is needed for these items.
    public init?(
        urls: [URL], intent: PublishIntent = .publish, origin: PublishSession.Origin = .menu,
        isFolder: (URL) -> Bool = BatchConfirmation.isFolderOnDisk
    ) {
        guard Self.isNeeded(itemCount: urls.count, intent: intent) else { return nil }
        self.origin = origin
        items = urls.map { Item(url: $0, isFolder: isFolder($0)) }
    }

    /// More items arrived while the question was open: they join it, so there is still one question.
    public mutating func add(_ urls: [URL], isFolder: (URL) -> Bool = BatchConfirmation.isFolderOnDisk) {
        items += urls.map { Item(url: $0, isFolder: isFolder($0)) }
    }

    public var urls: [URL] { items.map(\.url) }

    /// "Publish 3 files?", "Publish 2 folders?" or "Publish 4 files and folders?".
    public var title: String {
        let folders = items.filter(\.isFolder).count
        let noun: String
        switch folders {
        case 0: noun = "files"
        case items.count: noun = "folders"
        default: noun = "files and folders"
        }
        return "Publish \(items.count) \(noun)?"
    }

    public var detail: String { "Each one gets its own link." }

    public var shown: [String] { items.prefix(Self.displayLimit).map(\.name) }
    public var hiddenCount: Int { max(0, items.count - Self.displayLimit) }

    public static func isFolderOnDisk(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

import Foundation

/// What a drag onto the menu bar icon (or the popover) carries, reduced to what can be published.
/// Reading the pasteboard stays in the app; the decisions are here so they can be tested.
public enum DroppedItems {
    /// The file URLs of a drag, in the order they came: non-file items (web links, text) are
    /// ignored, file reference URLs become plain paths, and each file is kept once.
    public static func publishableFileURLs(from items: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for item in items where item.isFileURL {
            let file = ((item as NSURL).filePathURL ?? item).standardizedFileURL
            guard !file.path.isEmpty, seen.insert(file.path).inserted else { continue }
            result.append(file)
        }
        return result
    }

    /// Whether the drag is worth highlighting the icon for: at least one file URL.
    public static func isAcceptable(_ items: [URL]) -> Bool {
        items.contains { $0.isFileURL }
    }
}

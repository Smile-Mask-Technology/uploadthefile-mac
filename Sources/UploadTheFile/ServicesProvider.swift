import AppKit
import UploadTheFileCore

/// The two Finder entries (declared as NSServices in Info.plist). AppKit calls these on the main
/// thread with the selection on a pasteboard. Both are fire-and-forget: anything to say goes in the
/// app's own window, so `error` is not used.
final class ServicesProvider: NSObject {
    /// "Publish with Upload the File": the same flow as dropping the files on the menu bar icon,
    /// except that every item waits for the user's answer first (any app can call a Service).
    @objc func publishFiles(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = DroppedItems.publishableFileURLs(from: Self.fileURLs(on: pasteboard))
        MainActor.assumeIsolated {
            AppModel.shared.publish(urls, intent: .publish, origin: .finder)
        }
    }

    /// "Copy Upload the File Link": the link of something already published from this Mac.
    @objc func copyLink(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = Self.fileURLs(on: pasteboard)
        MainActor.assumeIsolated {
            AppModel.shared.copyLinks(for: urls)
        }
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}

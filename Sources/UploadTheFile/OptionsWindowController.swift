import AppKit
import SwiftUI

/// One Options window per page, opened from a row's menu. The menu bar popover's SwiftUI content
/// is not inside a scene, so `openWindow` is not available there: the windows are plain AppKit
/// around a SwiftUI view, like the publish window. A page that is already open is brought forward.
@MainActor
final class OptionsWindowController: NSObject, NSWindowDelegate {
    static let shared = OptionsWindowController()

    private var windows: [String: NSWindow] = [:]

    func open(pageID: String, appModel: AppModel) {
        if let existing = windows[pageID] {
            AppActivation.bringToFront()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let row = appModel.row(id: pageID) else { return }
        let controller = NSHostingController(rootView: OptionsWindowContent(
            appModel: appModel, pageID: pageID,
            close: { [weak self] in self?.close(pageID: pageID) }))
        // A fixed size the user can stretch (the grouped Form scrolls), never SwiftUI's ideal size:
        // letting the window chase the content is what looped the layout and crashed the publish
        // window during a drop (2026-11-16). The same rule holds here.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "Set up your link · \(row.page.slug)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 460, height: min(680, screenHeight - 80)))
        window.contentMinSize = NSSize(width: 460, height: 320)
        window.contentMaxSize = NSSize(width: 460, height: 10_000)
        window.center()
        windows[pageID] = window
        AppActivation.bringToFront()
        window.makeKeyAndOrderFront(nil)
    }

    func close(pageID: String) {
        windows[pageID]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

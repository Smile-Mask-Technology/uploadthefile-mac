import AppKit
import SwiftUI

/// "Upload the File" in the menu bar. No Dock icon (LSUIElement), no main window. The menu bar
/// icon, its popover and the Options windows are AppKit (see StatusItemController); SwiftUI only
/// needs a scene to start, and this one never shows anything.
struct UploadTheFileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()
    private let notificationDelegate = NotificationDelegate()
    private var statusItem: StatusItemController?
    private var updates: AppUpdates?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Also true when run without the app bundle's LSUIElement (for example from `swift run`).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updates = AppUpdates()
        self.updates = updates
        statusItem = StatusItemController(model: AppModel.shared, updates: updates)
        NSApp.servicesProvider = services
        // Make Finder notice the Services this app declares, without a logout.
        NSUpdateDynamicServices()
        Notifier.configure(delegate: notificationDelegate)
    }
}

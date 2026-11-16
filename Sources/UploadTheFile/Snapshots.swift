#if DEBUG
import AppKit
import SwiftUI
import UploadTheFileCore
import UptfKit

/// `UploadTheFile --render-snapshots <dir>` (debug builds only): draws every screen state of the
/// menu bar popover, the publish window and the Options window to PNG files, off screen, with
/// fixture data, then exits. Nothing is shown on the display (SwiftUI's `ImageRenderer` draws into
/// a bitmap), and nothing touches the network, the Keychain or the disk apart from the PNGs.
@MainActor
enum Snapshots {
    /// The directory after `--render-snapshots`, if the flag is there.
    static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--render-snapshots") else { return nil }
        let next = arguments.index(after: flag)
        return next < arguments.endIndex ? arguments[next] : ""
    }

    /// Renders everything. Returns the process exit status.
    static func run(into path: String) -> Int32 {
        guard !path.isEmpty else {
            FileHandle.standardError.write(Data("usage: UploadTheFile --render-snapshots <directory>\n".utf8))
            return 2
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Could not create \(path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        // A bitmap is all that is needed, but SwiftUI wants an NSApplication; keep it out of the Dock.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var failures = 0
        for shot in shots() {
            for (scheme, label) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
                let file = directory.appendingPathComponent("\(shot.name)-\(label).png")
                if render(shot.content(), scheme: scheme, to: file) {
                    print(file.path)
                } else {
                    FileHandle.standardError.write(Data("Could not render \(file.lastPathComponent)\n".utf8))
                    failures += 1
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Rendering

    /// `ImageRenderer` draws buttons, scroll views, forms and drop targets as yellow "no entry"
    /// placeholders (they are AppKit controls underneath), so the view is hosted in an
    /// `NSHostingView` inside a window that is never ordered onto the display, and the view's own
    /// drawing is copied into a 2x bitmap. Nothing on screen is read.
    ///
    /// A window that is not key draws prominent buttons grey and toggles inactive, which is not
    /// what a user sees in an open window, so the hosted window reports itself as key and the
    /// SwiftUI environment says the controls are active.
    private final class OffscreenWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    private static func render(_ content: AnyView, scheme: ColorScheme, to file: URL) -> Bool {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let framed = content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: framed)
        let window = OffscreenWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host

        // Let SwiftUI settle: layout, then one pass of the run loop for `.task` and state updates.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 1, size.height > 1 else { return false }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        let scale = 2
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        bitmap.size = size  // points; the extra pixels make it 2x
        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            data = bitmap.representation(using: .png, properties: [:])
        }
        window.contentView = nil
        guard let data else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    // MARK: The states

    private struct Shot {
        var name: String
        var content: () -> AnyView
    }

    private static func shots() -> [Shot] {
        var all: [Shot] = []
        func menu(_ name: String, _ state: AppModel.Snapshot) {
            all.append(Shot(name: "menu-\(name)") { AnyView(MenuContentView(model: AppModel(snapshot: state))) })
        }
        func publish(_ name: String, session: PublishSession = PublishSession(), notice: Notice? = nil) {
            let state = AppModel.Snapshot(account: .signedIn, session: session, notice: notice)
            all.append(Shot(name: "publish-\(name)") { AnyView(PublishWindowView(model: AppModel(snapshot: state))) })
        }
        func options(_ name: String, page: PageInfo, load: OptionsModel.Load = .loaded, settings: OptionsModel.Settings? = nil,
                     prepare: @escaping (OptionsModel) -> Void = { _ in }) {
            all.append(Shot(name: "options-\(name)") {
                let appModel = AppModel(snapshot: .init(account: .signedIn, rows: [Fixtures.row(for: page)], listState: .loaded))
                let model = OptionsModel(page: page, client: Fixtures.client)
                model.applySnapshot(load: load, settings: settings)
                prepare(model)
                return AnyView(OptionsView(model: model, appModel: appModel, close: {}))
            })
        }

        // Menu bar popover
        menu("signed-out", .init(account: .signedOut))
        menu("signing-in", .init(account: .signingIn))
        menu("signed-in-empty", .init(account: .signedIn, listState: .loaded))
        menu("signed-in-list", .init(account: .signedIn, rows: Fixtures.rows, listState: .loaded))
        menu("publishing", .init(
            account: .signedIn, rows: Fixtures.rows, listState: .loaded,
            session: Fixtures.session(.uploading, name: "launch-notes.html")))
        menu("just-published", .init(
            account: .signedIn, rows: Fixtures.rows, listState: .loaded,
            session: Fixtures.session(.published, name: "launch-notes.html")))
        menu("link-copied", .init(
            account: .signedIn, rows: Fixtures.rows, listState: .loaded, copiedPageID: Fixtures.rows[1].id))
        menu("error", .init(
            account: .signedIn, rows: Fixtures.rows, listState: .loaded,
            errorMessage: UptfError.rateLimited(retryAfter: 12 * 60).localizedDescription))
        menu("loading", .init(account: .signedIn, listState: .loading))
        menu("drop-targeted", .init(account: .signedIn, rows: Fixtures.rows, listState: .loaded, isDropTargeted: true))

        // Publish window
        publish("folder", session: Fixtures.session(.confirm(Fixtures.folderConfirmation), name: "trailhead", origin: .finder))
        publish("sensitive", session: Fixtures.session(.confirm(Fixtures.sensitiveConfirmation), name: ".ssh", origin: .finder))
        publish("already-published", session: Fixtures.session(
            .confirm(Fixtures.alreadyPublishedConfirmation(changed: false)), name: "q3-board-deck.pdf", origin: .finder))
        publish("already-published-changed", session: Fixtures.session(
            .confirm(Fixtures.alreadyPublishedConfirmation(changed: true)), name: "q3-board-deck.pdf", origin: .finder))
        publish("too-large", session: Fixtures.session(
            .refused(UptfError.tooLarge(bytes: 63_400_000).localizedDescription), name: "site-recording.mov", origin: .finder))
        publish("progress", session: Fixtures.session(.uploading, name: "q3-board-deck.pdf", origin: .finder))
        publish("done", session: Fixtures.session(.published, name: "q3-board-deck.pdf", origin: .finder))
        publish("notice-link-copied", notice: Notice(
            title: "Link copied", detail: "https://launch-notes.upload.tf", link: "https://launch-notes.upload.tf"))

        // Options window
        let free = Fixtures.pages[0]
        let site = Fixtures.pages[4]
        options("free", page: free, settings: .init())
        options("free-plan-messages", page: free, settings: .init()) { model in
            model.newPassword = "northern-lights-42"
            model.confirmPassword = "northern-lights-42"
            model.gateEnabled = true
            model.gateMessage = "Enter your email to view"
            model.neverExpires = false
            model.expiryDate = Fixtures.date(daysFromNow: 14)
            model.applySnapshot(
                load: .loaded,
                passwordStatus: .refused(UptfError.server(status: 403, message: "Password protection is available on Pro and above").localizedDescription),
                gateStatus: .refused(UptfError.server(status: 403, message: "Email capture is available on Pro and above").localizedDescription),
                expiryStatus: .refused(UptfError.server(status: 403, message: "A custom expiry is available on Pro and above").localizedDescription))
        }
        options("site", page: site, settings: .init(displayMode: nil))
        options("loading", page: free, load: .loading)
        return all
    }
}

// MARK: - Fixture data

@MainActor
private enum Fixtures {
    static let home = URL(fileURLWithPath: "/Users/alex", isDirectory: true)
    static let origin = "https://uploadthefile.com"
    /// Never called: the Options views only read the model's state in a snapshot.
    static let client = UptfClient(config: try! UptfConfig(), store: InMemoryTokenStore())

    static func date(daysFromNow days: Int) -> Date {
        Date().addingTimeInterval(TimeInterval(days) * 86_400)
    }

    private static func page(_ name: String, kind: String, bytes: Int64, files: Int = 1, hoursAgo: Double, fileName: String? = nil) -> PageInfo {
        PageInfo(
            id: "pg_" + String(name.hashValue.magnitude % 1_000_000), name: name, url: "https://\(name).upload.tf",
            fileName: fileName ?? "\(name).\(kind)", kind: kind, sizeBytes: bytes, fileCount: files,
            createdAt: Date().addingTimeInterval(-hoursAgo * 3600), expiresAt: nil, chatEnabled: false)
    }

    /// Six pages: site, html, pdf, png, zip, and one with a very long name.
    static let pages: [PageInfo] = [
        page("launch-notes", kind: "html", bytes: 18_400, hoursAgo: 1),
        page("q3-board-deck", kind: "pdf", bytes: 2_480_000, hoursAgo: 26),
        page("team-offsite-photo", kind: "png", bytes: 3_150_000, hoursAgo: 70),
        page("client-handoff-assets", kind: "zip", bytes: 18_900_000, files: 24, hoursAgo: 160),
        page("trailhead-guide", kind: "site", bytes: 1_240_000, files: 12, hoursAgo: 300, fileName: "trailhead.zip"),
        page("annual-report-draft-final-v2-with-comments-from-legal-and-finance", kind: "html", bytes: 96_000, hoursAgo: 900),
    ]

    private static func entry(for page: PageInfo) -> PublishedEntry {
        PublishedEntry(
            id: page.id, origin: origin, name: page.name, url: page.url, kind: page.kind == "site" ? .folder : .file,
            hostedAsSite: page.kind == "site", lastKnownPath: "/Users/alex/Documents/\(page.fileName)",
            sha256: String(repeating: "ab", count: 32), publishedAt: page.createdAt)
    }

    /// The first row's local file changed since it was published: "Update Link".
    static let rows: [PageRow] = pages.enumerated().map { offset, page in
        let url = URL(fileURLWithPath: "/Users/alex/Documents/\(page.fileName)")
        return PageRow(page: page, entry: entry(for: page), local: offset == 0 ? .changed : .unchanged, localURL: url)
    }

    static func row(for page: PageInfo) -> PageRow {
        PageRow(page: page, entry: entry(for: page), local: .unchanged, localURL: nil)
    }

    // MARK: Publish sessions

    enum Step {
        case uploading
        case published
        case refused(String)
        case confirm(PublishConfirmation)
    }

    /// Drives a real `PublishSession` to the state to show.
    static func session(_ step: Step, name: String, origin: PublishSession.Origin = .menu) -> PublishSession {
        var session = PublishSession()
        let url = home.appendingPathComponent("Documents/\(name)")
        _ = session.start([url], origin: origin)
        let request = UploadRequest(plan: PublishPlan(url: url, kind: .file, fileSize: 2_480_000))
        switch step {
        case .uploading:
            _ = session.assessed(.upload(request))
        case .published:
            _ = session.assessed(.upload(request))
            _ = session.uploaded(url: "https://\(url.deletingPathExtension().lastPathComponent).upload.tf")
        case .refused(let message):
            _ = session.assessed(.refused(message))
        case .confirm(let confirmation):
            _ = session.assessed(.confirm(confirmation))
        }
        return session
    }

    static let folderConfirmation: PublishConfirmation = {
        let url = home.appendingPathComponent("Sites/trailhead", isDirectory: true)
        let entries = [
            "index.html", "about.html", "contact.html", "css/site.css", "css/fonts.css", "js/map.js",
            "img/hero.jpg", "img/logo.svg", "img/trail-01.jpg", "img/trail-02.jpg", "img/trail-03.jpg",
            "docs/permits-2026.pdf",
        ]
        let plan = PublishPlan(url: url, kind: .folder, entries: entries)
        return PublishConfirmation(
            url: url, plan: plan, intent: .publish, warnings: [],
            folder: FolderListing(folderName: "trailhead", entries: entries, servedAsWebsite: plan.hasRootIndexHtml),
            existing: nil)
    }()

    static let sensitiveConfirmation: PublishConfirmation = {
        let url = home.appendingPathComponent(".ssh/config")
        return PublishConfirmation(
            url: url, plan: PublishPlan(url: url, kind: .file, fileSize: 1_024), intent: .publish,
            warnings: PublishAssessor.warnings(for: url, home: home), folder: nil, existing: nil)
    }()

    static func alreadyPublishedConfirmation(changed: Bool) -> PublishConfirmation {
        let url = home.appendingPathComponent("Documents/q3-board-deck.pdf")
        let page = pages[1]
        return PublishConfirmation(
            url: url, plan: PublishPlan(url: url, kind: .file, fileSize: page.sizeBytes), intent: .publish,
            warnings: [], folder: nil,
            existing: ExistingPublication(entry: entry(for: page), pageURL: page.url, changed: changed))
    }
}
#endif

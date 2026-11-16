import AppKit
import Foundation
import Observation
import UploadTheFileCore
import UptfKit

/// A short message shown in the app's window outside making a link (for example after
/// "Copy Upload the File Link" in Finder).
struct Notice: Equatable {
    var title: String
    var detail: String
    var link: String?
}

/// The app's state and the glue between the views and UptfKit. The rules live in
/// UploadTheFileCore; this class carries them out.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Account: Equatable { case signedOut, signingIn, signedIn }
    enum ListState: Equatable { case idle, loading, loaded, failed(String) }

    // MARK: State the views read

    private(set) var startupError: String?
    private(set) var account: Account = .signedOut
    private(set) var signInError: String?
    private(set) var rows: [PageRow] = []
    private(set) var listState: ListState = .idle
    private(set) var loadedAt: Date?
    private(set) var session = PublishSession()
    private(set) var notice: Notice?
    /// The row whose link was just copied; cleared after a moment.
    private(set) var copiedPageID: String?
    /// Something that went wrong outside making a link (deleting one, signing out ...), verbatim.
    var errorMessage: String?
    var isDropTargeted = false

    var siteLabel: String { backend?.siteLabel ?? "uploadthefile.com" }
    /// Where "See Plans" goes: the pricing page of the site the app is signed in to.
    var plansURL: URL {
        OptionsRules.pricingURL(origin: backend?.config.originURL ?? URL(string: "https://uploadthefile.com")!)
    }
    /// "Manage Files": the website's dashboard, for everything the app does not do.
    var dashboardURL: URL {
        OptionsRules.dashboardURL(origin: backend?.config.originURL ?? URL(string: "https://uploadthefile.com")!)
    }

    func openDashboard() {
        NSWorkspace.shared.open(dashboardURL)
    }
    var isSignedIn: Bool { account == .signedIn }

    // MARK: Private

    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var finishHandled = true
    /// The session phase after the last transition, to tell what just changed.
    @ObservationIgnored private var lastPhase: PublishSession.Phase = .idle
    /// Brings up the menu bar window (set by the status item controller). A link made from the
    /// menu bar side shows its progress and result there, also after the file picker closed it.
    @ObservationIgnored var presentStatus: (() -> Void)?
    /// Runs a modal alert without closing the menu bar popover (set by StatusItemController). An
    /// alert takes the focus, and a transient popover closes when it loses it: the user would have
    /// to reopen the list after every delete. Without a status item it just runs the alert.
    @ObservationIgnored var keepingStatusOpen: (@MainActor (() -> Bool) -> Bool)?

    func askKeepingStatusOpen(_ alert: () -> Bool) -> Bool {
        if let keepingStatusOpen { return keepingStatusOpen(alert) }
        return alert()
    }
    @ObservationIgnored private var windowSuppressed = false
    @ObservationIgnored private var isLoadingList = false
    @ObservationIgnored private let publishWindow = PublishWindowController()

    private init() {
        do {
            backend = try Backend()
        } catch {
            startupError = UserMessage.text(for: error)
        }
        refreshAccount()
    }

    #if DEBUG
    /// Fixed state for the off-screen snapshots (`--render-snapshots`). There is no backend, so
    /// nothing reads the Keychain, the disk or the network.
    struct Snapshot {
        var startupError: String?
        var account: Account = .signedOut
        var signInError: String?
        var rows: [PageRow] = []
        var listState: ListState = .idle
        var session = PublishSession()
        var notice: Notice?
        var copiedPageID: String?
        var errorMessage: String?
        var isDropTargeted = false
    }

    init(snapshot: Snapshot) {
        startupError = snapshot.startupError
        account = snapshot.account
        signInError = snapshot.signInError
        rows = snapshot.rows
        listState = snapshot.listState
        loadedAt = snapshot.listState == .loaded ? Date() : nil
        session = snapshot.session
        notice = snapshot.notice
        copiedPageID = snapshot.copiedPageID
        errorMessage = snapshot.errorMessage
        isDropTargeted = snapshot.isDropTargeted
    }
    #endif

    func row(id: String) -> PageRow? { rows.first { $0.id == id } }

    // MARK: Opening the menu bar window

    /// Called whenever the menu bar window appears. Reads the account state, and the page list only
    /// when it is older than ten minutes (free accounts get 20 reads an hour).
    func windowDidOpen() {
        if account == .signedOut { refreshAccount() }
        if isSignedIn, RefreshPolicy.isStale(loadedAt: loadedAt) {
            Task { await loadList() }
        }
    }

    private func refreshAccount() {
        guard account != .signingIn, let backend else { return }
        do {
            account = try backend.authenticator.isSignedIn() ? .signedIn : .signedOut
        } catch {
            account = .signedOut
            signInError = UserMessage.text(for: error)
        }
    }

    // MARK: Sign in and out

    func signIn() {
        guard let backend, account != .signingIn else { return }
        account = .signingIn
        signInError = nil
        signInTask = Task {
            do {
                try await backend.authenticator.signIn()
                account = .signedIn
                await loadList()
            } catch {
                account = .signedOut
                if !Task.isCancelled { signInError = UserMessage.text(for: error) }
            }
            signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func signOut() {
        guard let backend else { return }
        Task {
            do {
                let revoked = try await backend.authenticator.signOut()
                if !revoked {
                    errorMessage = "Signed out on this Mac. We couldn't reach Upload the File to finish signing out; you can remove “Upload the File for Mac” in your account settings."
                }
            } catch {
                errorMessage = UserMessage.text(for: error)
            }
            self.backend = backend.withFreshClient()
            rows = []
            loadedAt = nil
            listState = .idle
            account = .signedOut
            signInError = nil
        }
    }

    // MARK: The page list

    /// One `GET /pages` (served from the client's 10-minute cache when it is fresh).
    func loadList() async {
        guard let backend, isSignedIn, !isLoadingList else { return }
        isLoadingList = true
        defer { isLoadingList = false }
        if rows.isEmpty { listState = .loading }
        do {
            let pages = try await backend.client.pages()
            // Keep the local history in step with the website (renames, deleted pages), but only
            // with a complete list.
            if pages.count < UptfClient.listLimit { _ = try? await backend.index.reconcile(with: pages) }
            rows = await Self.makeRows(pages: pages, index: backend.index)
            loadedAt = Date()
            listState = .loaded
        } catch {
            handle(error, listFailure: true)
        }
    }

    private static func makeRows(pages: [PageInfo], index: PublishedIndex) async -> [PageRow] {
        let entries = (try? await index.entries()) ?? []
        let wanted = Set(pages.map(\.id))
        var states: [String: (state: LocalFileState, url: URL?)] = [:]
        for entry in entries where wanted.contains(entry.id) {
            guard let url = await index.currentURL(for: entry) else {
                states[entry.id] = (.missing, nil)
                continue
            }
            let changed = (try? await index.changedSincePublish(url)) ?? false
            states[entry.id] = (changed ? .changed : .unchanged, url)
        }
        return PageRows.make(pages: pages, entries: entries) { states[$0.id] ?? (.missing, nil) }
    }

    private func handle(_ error: Error, listFailure: Bool = false) {
        if UserMessage.requiresSignIn(error) {
            account = .signedOut
            signInError = "You were signed out. Sign in again to continue."
            return
        }
        let message = UserMessage.text(for: error)
        if listFailure && rows.isEmpty { listState = .failed(message) } else { errorMessage = message }
        if listFailure && !rows.isEmpty { listState = .loaded }
    }

    // MARK: Row actions

    func copyLink(_ row: PageRow) {
        copy(row.page.url)
        copiedPageID = row.id
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copiedPageID = nil }
        }
    }

    func openInBrowser(_ row: PageRow) { openLink(row.page.url) }

    /// Opens a link in the default browser.
    func openLink(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func reveal(_ row: PageRow) {
        guard let url = row.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func updateLink(_ row: PageRow) {
        guard let url = row.localURL else { return }
        publish([url], intent: .updateLink, origin: .menu)
    }

    /// Asks first, then deletes the file and its link.
    func delete(_ row: PageRow) async -> Bool {
        guard let backend, askKeepingStatusOpen({ Alerts.confirmDelete(name: row.title) }) else { return false }
        do {
            try await backend.client.unpublish(row.page.slug)
            try? await backend.index.remove(id: row.id)
            rows.removeAll { $0.id == row.id }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// After a rename, expiry change or similar from the Options window: take the fresh page.
    func replace(_ page: PageInfo) {
        guard let index = rows.firstIndex(where: { $0.id == page.id }) else { return }
        rows[index].page = page
        if let backend { Task { try? await backend.index.apply(page) } }
    }

    func remove(pageID: String) {
        rows.removeAll { $0.id == pageID }
    }

    var client: UptfClient? { backend?.client }

    // MARK: Publishing

    /// Starts (or joins) a publish. Used by drag and drop, the Choose File… button, the Finder
    /// service and "Update Link".
    func publish(_ urls: [URL], intent: PublishIntent = .publish, origin: PublishSession.Origin = .menu) {
        guard !urls.isEmpty else { return }
        refreshAccount()
        if !session.isActive {
            finishHandled = false
            windowSuppressed = false
            dismissTask?.cancel()
        }
        errorMessage = nil
        guard isSignedIn, backend != nil else {
            _ = session.start(urls, intent: intent, origin: origin)
            _ = session.assessed(.refused("Sign in to Upload the File first: click its icon in the menu bar."))
            afterTransition()
            return
        }
        Task { await Notifier.requestIfNeeded() }
        perform(session.start(urls, intent: intent, origin: origin))
    }

    func chooseAndPublish() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Publish"
        panel.message = "Choose the files or folders to publish."
        AppActivation.bringToFront()
        Task {
            if await panel.begin() == .OK { publish(panel.urls) }
        }
    }

    func choose(_ choice: PublishChoice) { perform(session.choose(choice)) }
    func decline() { perform(session.decline()) }
    func dismissSession() { session.dismiss(); afterTransition() }

    private func perform(_ effect: PublishEffect) {
        switch effect {
        case .none:
            break
        case .assess(let url, let intent):
            guard let backend else { break }
            Task {
                let verdict = await PublishAssessor(publisher: backend.publisher).assess(url, intent: intent)
                guard session.phase == .assessing(url) else { return }  // cancelled meanwhile
                perform(session.assessed(verdict))
            }
        case .upload(let request):
            guard let backend else { break }
            Task { await upload(request, backend: backend) }
        }
        afterTransition()
    }

    private func upload(_ request: UploadRequest, backend: Backend) async {
        do {
            let outcome: PublishOutcome
            if let entry = request.update {
                outcome = try await backend.publisher.update(request.plan, entry: entry)
            } else {
                outcome = try await backend.publisher.publish(request.plan, hostAsSite: request.hostAsSite)
            }
            perform(session.uploaded(url: outcome.result.url))
        } catch {
            if UserMessage.requiresSignIn(error) { handle(error) }
            perform(session.failed(UserMessage.text(for: error), stopsBatch: UserMessage.stopsBatch(error)))
        }
    }

    /// Window management and the end-of-session work, after every state change.
    private func afterTransition() {
        publishWindow.sync(with: self, suppressed: windowSuppressed)
        let old = lastPhase
        lastPhase = session.phase
        if PublishSession.presentsMenuBar(from: old, to: session.phase, origin: session.origin) {
            presentStatus?()
        }
        guard session.isFinished, !finishHandled else { return }
        finishHandled = true
        finishSession()
    }

    private func finishSession() {
        if let text = session.clipboardText { copy(text) }
        let uploaded = session.links.contains { $0.kind != .existing }
        if uploaded, let first = session.links.first {
            let body = session.links.count == 1 ? first.url : "\(session.links.count) links copied"
            Task { await Notifier.post(title: "Link copied", body: body) }
            Task { await loadList() }
        }
        // A finished session in the menu clears itself; one in its own window waits for "Done".
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled, session.isFinished, !session.wantsWindow { dismissSession() }
        }
    }

    /// The user closed the publish window with the red button.
    func publishWindowWasClosed() {
        switch session.phase {
        case .confirming:
            finishHandled = true
            session.cancelAll()
            session.dismiss()
        case .finished:
            session.dismiss()
        case .assessing, .uploading:
            windowSuppressed = true  // keep going, quietly; the menu shows the progress
        case .idle:
            break
        }
        notice = nil
        if session.phase == .idle { lastPhase = .idle }
    }

    // MARK: Finder services

    func copyLinks(for urls: [URL]) {
        guard let backend else { return }
        Task {
            var links: [String] = []
            var notPublished: [String] = []
            for url in urls {
                if let entry = try? await backend.index.entry(for: url) {
                    links.append(entry.url)
                } else {
                    notPublished.append(url.lastPathComponent)
                }
            }
            if links.isEmpty {
                let names = notPublished.joined(separator: ", ")
                show(Notice(
                    title: "Not published yet",
                    detail: "“\(names)” isn't published from this Mac yet. Choose “Publish with Upload the File” first.",
                    link: nil))
                return
            }
            copy(links.joined(separator: "\n"))
            var detail = links.count == 1 ? links[0] : "\(links.count) links are on the clipboard."
            if !notPublished.isEmpty { detail += "\nNot published yet: \(notPublished.joined(separator: ", "))." }
            show(Notice(title: "Link copied", detail: detail, link: links.count == 1 ? links[0] : nil))
            await Notifier.post(title: "Link copied", body: links.count == 1 ? links[0] : "\(links.count) links")
        }
    }

    private func show(_ notice: Notice) {
        windowSuppressed = false
        self.notice = notice
        afterTransition()
    }

    func dismissNotice() {
        notice = nil
        afterTransition()
    }

    // MARK: Helpers

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

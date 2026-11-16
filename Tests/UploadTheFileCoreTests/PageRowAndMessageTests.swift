import Foundation
import Testing
import UptfKit

@testable import UploadTheFileCore

@Suite("Page rows")
struct PageRowTests {
    @Test func rowsAreNewestFirstAndLabelled() throws {
        let old = makePage(id: "a", name: "old", kind: "pdf", size: 2_000_000, createdAt: Date(timeIntervalSince1970: 1_000))
        let new = makePage(id: "b", name: "new", kind: "site", size: 500, createdAt: Date(timeIntervalSince1970: 2_000))
        let rows = PageRows.make(pages: [old, new], entries: []) { _ in (.notTracked, nil) }
        #expect(rows.map(\.id) == ["b", "a"])
        #expect(rows[0].kindLabel == "Website")
        #expect(rows[1].kindLabel == "PDF")
        #expect(rows[1].subtitle == "PDF · 2 MB")
        #expect(rows[0].title == "new")
    }

    @Test func pageWithoutANameUsesItsID() {
        let row = PageRow(page: makePage(id: "abc123", name: nil), entry: nil, local: .notTracked, localURL: nil)
        #expect(row.title == "abc123")
    }

    @Test func changedLocalFileNeedsUpdate() throws {
        let entry = try makeEntry(id: "a", path: "/tmp/report.pdf")
        let local = URL(fileURLWithPath: "/tmp/report.pdf")
        let rows = PageRows.make(pages: [makePage(id: "a")], entries: [entry]) { _ in (.changed, local) }
        #expect(rows[0].needsUpdate)
        #expect(rows[0].canReveal)
        #expect(rows[0].local == .changed)
    }

    @Test func unchangedLocalFileDoesNotNeedUpdateButCanBeRevealed() throws {
        let entry = try makeEntry(id: "a")
        let local = URL(fileURLWithPath: "/tmp/report.pdf")
        let rows = PageRows.make(pages: [makePage(id: "a")], entries: [entry]) { _ in (.unchanged, local) }
        #expect(!rows[0].needsUpdate)
        #expect(rows[0].canReveal)
    }

    @Test func missingLocalFileCannotBeRevealedOrUpdated() throws {
        let entry = try makeEntry(id: "a")
        let rows = PageRows.make(pages: [makePage(id: "a")], entries: [entry]) { _ in (.missing, nil) }
        #expect(!rows[0].needsUpdate)
        #expect(!rows[0].canReveal)
    }

    @Test func changedFileOffersReplaceFile() throws {
        let entry = try makeEntry(id: "a")
        let rows = PageRows.make(pages: [makePage(id: "a")], entries: [entry]) { _ in (.changed, URL(fileURLWithPath: "/tmp/report.pdf")) }
        #expect(rows[0].replaceTitle == "Replace File")
    }

    @Test func pagesPublishedElsewhereHaveNoLocalActions() throws {
        let entry = try makeEntry(id: "other")
        var asked = 0
        let rows = PageRows.make(pages: [makePage(id: "a")], entries: [entry]) { _ in asked += 1; return (.changed, nil) }
        #expect(asked == 0)
        #expect(rows[0].entry == nil)
        #expect(!rows[0].needsUpdate)
        #expect(!rows[0].canReveal)
    }

    @Test func displayModeIsOnlyForSingleFiles() {
        #expect(PageRow(page: makePage(kind: "pdf"), entry: nil, local: .notTracked, localURL: nil).supportsDisplayMode)
        #expect(!PageRow(page: makePage(kind: "site"), entry: nil, local: .notTracked, localURL: nil).supportsDisplayMode)
    }

    @Test func rowsShowTheLinkWithoutTheScheme() {
        #expect(LinkLabel.short("https://launch-notes.upload.tf") == "launch-notes.upload.tf")
        #expect(LinkLabel.short("https://launch-notes.upload.tf/") == "launch-notes.upload.tf")
        #expect(LinkLabel.short("HTTPS://Launch-Notes.upload.tf") == "Launch-Notes.upload.tf")
        #expect(LinkLabel.short("http://localhost:3000/a/b/") == "localhost:3000/a/b")
        #expect(LinkLabel.short("  https://x.upload.tf \n") == "x.upload.tf")
        #expect(LinkLabel.short("not a link") == "not a link")
        #expect(LinkLabel.short("https://") == "https://")
        let row = PageRow(page: makePage(id: "a", name: "launch-notes"), entry: nil, local: .notTracked, localURL: nil)
        #expect(row.linkLabel == LinkLabel.short(row.page.url))
        #expect(!row.linkLabel.hasPrefix("http"))
    }
}

@Suite("Messages and policies")
struct MessageTests {
    @Test func rateLimitMessageSaysMinutes() {
        #expect(UserMessage.text(for: UptfError.rateLimited(retryAfter: 1_500)) == "Too many changes in a short time. Try again in 25 minutes.")
        #expect(UserMessage.text(for: UptfError.rateLimited(retryAfter: 30)) == "Too many changes in a short time. Try again in 1 minute.")
        #expect(UserMessage.text(for: UptfError.rateLimited(retryAfter: nil)) == "Too many changes in a short time. Try again later.")
    }

    @Test func serverMessagesAreShownVerbatim() {
        let message = "Password protection is available on Pro and above"
        #expect(UserMessage.text(for: UptfError.server(status: 403, message: message)) == message)
        #expect(UserMessage.isPlanRefusal(UptfError.server(status: 403, message: message)))
        #expect(!UserMessage.isPlanRefusal(UptfError.server(status: 500, message: "oops")))
        #expect(!UserMessage.isPlanRefusal(UptfError.rateLimited(retryAfter: nil)))
    }

    @Test func onlyA403WithAServerMessageIsAPlanRefusal() {
        // The plan messages the server sends for password, email gate and expiry.
        for message in [
            "Password protection is available on Pro and above",
            "Email capture is available on Pro and above",
            "A custom expiry is available on Pro and above",
        ] {
            #expect(UserMessage.isPlanRefusal(UptfError.server(status: 403, message: message)))
        }
        // A 403 with nothing to say is not a plan message.
        #expect(!UserMessage.isPlanRefusal(UptfError.server(status: 403, message: "")))
        #expect(!UserMessage.isPlanRefusal(UptfError.server(status: 403, message: "  \n")))
        // Real failures keep the error styling.
        #expect(!UserMessage.isPlanRefusal(UptfError.server(status: 400, message: "Invalid password")))
        #expect(!UserMessage.isPlanRefusal(UptfError.server(status: 401, message: "Unauthorized")))
        #expect(!UserMessage.isPlanRefusal(UptfError.notSignedIn))
        #expect(!UserMessage.isPlanRefusal(UptfError.network(URLError(.notConnectedToInternet))))
        #expect(!UserMessage.isPlanRefusal(UptfError.unexpected("Pro and above")))
        #expect(!UserMessage.isPlanRefusal(CancellationError()))
    }

    @Test func foreignErrorsNeverDumpTheirInternals() {
        struct Plain: Error {}
        let text = UserMessage.text(for: Plain())
        #expect(!text.contains("Plain("))
        #expect(!text.isEmpty)
        #expect(UserMessage.text(for: CancellationError()) == "Cancelled.")
    }

    @Test func onlyRepeatableFailuresStopABatch() {
        #expect(UserMessage.stopsBatch(UptfError.rateLimited(retryAfter: nil)))
        #expect(UserMessage.stopsBatch(UptfError.notSignedIn))
        #expect(!UserMessage.stopsBatch(UptfError.tooLarge(bytes: 1)))
        #expect(!UserMessage.stopsBatch(UptfError.server(status: 403, message: "x")))
        #expect(UserMessage.requiresSignIn(UptfError.notSignedIn))
        #expect(!UserMessage.requiresSignIn(UptfError.rateLimited(retryAfter: nil)))
    }

    @Test func listIsFetchedOnOpenOnlyWhenOlderThanTenMinutes() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(RefreshPolicy.isStale(loadedAt: nil, now: now))
        #expect(!RefreshPolicy.isStale(loadedAt: now.addingTimeInterval(-599), now: now))
        #expect(RefreshPolicy.isStale(loadedAt: now.addingTimeInterval(-600), now: now))
        #expect(!RefreshPolicy.isStale(loadedAt: now, now: now))
    }
}

@Suite("Options rules")
struct OptionsRulesTests {
    @Test func passwordNeedsSixToSeventyTwoCharactersTwice() {
        #expect(OptionsRules.passwordProblem("", confirmation: "") == nil)
        #expect(OptionsRules.passwordProblem("abc", confirmation: "") == "Use 6 to 72 characters.")
        #expect(OptionsRules.passwordProblem(String(repeating: "a", count: 73), confirmation: "") == "Use 6 to 72 characters.")
        #expect(OptionsRules.passwordProblem("secret1", confirmation: "secret2") == "The two passwords don't match.")
        #expect(OptionsRules.passwordProblem("secret1", confirmation: "") == nil)

        #expect(!OptionsRules.canSavePassword("secret1", confirmation: ""))
        #expect(!OptionsRules.canSavePassword("secret1", confirmation: "secret2"))
        #expect(!OptionsRules.canSavePassword("short", confirmation: "short"))
        #expect(OptionsRules.canSavePassword("secret1", confirmation: "secret1"))
        #expect(OptionsRules.canSavePassword(String(repeating: "a", count: 72), confirmation: String(repeating: "a", count: 72)))
    }

    @Test func namesFollowTheDocumentedRules() {
        #expect(OptionsRules.nameProblem("ab") == "Use 3 to 32 characters.")
        #expect(OptionsRules.nameProblem("My Page") == "Use lowercase letters, numbers and hyphens.")
        #expect(OptionsRules.nameProblem("my-page-2") == nil)
        #expect(OptionsRules.canRename(from: "old-name", to: "new-name"))
        #expect(!OptionsRules.canRename(from: "old-name", to: "old-name"))
        #expect(!OptionsRules.canRename(from: "old-name", to: "  "))
    }

    @Test func neverExpiresSendsNull() {
        let date = Date(timeIntervalSince1970: 5_000_000_000)
        #expect(OptionsRules.expiryToSend(neverExpires: true, date: date) == nil)
        #expect(OptionsRules.expiryToSend(neverExpires: false, date: date) == date)
    }

    @Test func expiryMustBeInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(OptionsRules.expiryProblem(neverExpires: false, date: now.addingTimeInterval(-1), now: now) == "Pick a time in the future.")
        #expect(OptionsRules.expiryProblem(neverExpires: false, date: now.addingTimeInterval(60), now: now) == nil)
        #expect(OptionsRules.expiryProblem(neverExpires: true, date: now.addingTimeInterval(-1), now: now) == nil)
    }

    @Test func gateMessageIsClamped() {
        #expect(OptionsRules.clampedGateMessage(String(repeating: "x", count: 250)).count == 200)
        #expect(OptionsRules.clampedGateMessage("hi") == "hi")
    }

    @Test func plansLinkIsThePricingPageOfTheSiteOrigin() {
        #expect(OptionsRules.pricingURL(origin: URL(string: "https://uploadthefile.com")!).absoluteString == "https://uploadthefile.com/pricing")
        #expect(OptionsRules.pricingURL(origin: URL(string: "https://uploadthefile.com/")!).absoluteString == "https://uploadthefile.com/pricing")
        #expect(OptionsRules.pricingURL(origin: URL(string: "http://localhost:3000")!).absoluteString == "http://localhost:3000/pricing")
        // "Manage Files" opens the website's dashboard on the same site.
        #expect(OptionsRules.dashboardURL(origin: URL(string: "https://uploadthefile.com")!).absoluteString == "https://uploadthefile.com/dashboard")
        #expect(OptionsRules.dashboardURL(origin: URL(string: "https://uploadthefile.com/")!).absoluteString == "https://uploadthefile.com/dashboard")
        #expect(OptionsRules.dashboardURL(origin: URL(string: "http://localhost:3000")!).absoluteString == "http://localhost:3000/dashboard")
    }
}

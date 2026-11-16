import Foundation
import Testing
import UptfKit

@testable import UploadTheFileCore

@Suite("PublishSession")
struct PublishSessionTests {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func startsIdleAndDoesNothingWithoutItems() {
        var session = PublishSession()
        #expect(session.phase == .idle)
        #expect(session.start([]) == .none)
        #expect(session.phase == .idle)
        #expect(!session.wantsWindow)
    }

    @Test func plainFileGoesAssessUploadFinished() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("a.txt", in: root)
            var session = PublishSession()
            #expect(session.start([file]) == .assess(file, .publish))
            #expect(session.phase == .assessing(file))
            #expect(session.isActive)

            let request = UploadRequest(plan: try makePlan(for: file, home: root))
            #expect(session.assessed(.upload(request)) == .upload(request))
            #expect(session.phase == .uploading(name: "a.txt", isUpdate: false))

            #expect(session.uploaded(url: "https://a.example.test") == .none)
            #expect(session.isFinished)
            #expect(session.clipboardText == "https://a.example.test")
            #expect(session.headline == "“a.txt” is published. Link copied.")
            #expect(!session.wantsWindow)  // menu origin, nothing to confirm: progress stays in the menu
        }
    }

    @Test func folderStopsForConfirmationThenUploads() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("site/index.html", in: root)
            let verdict = await makeAssessor(home: root).assess(site, intent: .publish)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm"); return }

            var session = PublishSession()
            _ = session.start([site])
            #expect(session.assessed(verdict) == .none)
            #expect(session.confirmation == confirmation)
            #expect(session.wantsWindow)  // confirmations always need room

            let effect = session.choose(.publishNew)
            guard case .upload(let request) = effect else { Issue.record("expected upload"); return }
            #expect(request.hostAsSite)
            _ = session.uploaded(url: "https://site.example.test")
            #expect(session.links == [PublishedLink(name: "site", url: "https://site.example.test", kind: .published)])
        }
    }

    @Test func decliningSkipsThatItemAndContinues() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("site/index.html", in: root)
            let other = try writeFile("other.txt", in: root)
            let folderVerdict = await makeAssessor(home: root).assess(site, intent: .publish)

            var session = PublishSession()
            _ = session.start([site, other])
            _ = session.assessed(folderVerdict)
            #expect(session.decline() == .assess(other, .publish))
            #expect(session.skipped == 1)
            _ = session.assessed(.upload(UploadRequest(plan: try makePlan(for: other, home: root))))
            _ = session.uploaded(url: "https://o.example.test")
            #expect(session.isFinished)
            #expect(session.links.count == 1)
            #expect(session.skipped == 1)
            #expect(session.headline == "1 link copied.")
        }
    }

    @Test func refusalIsRecordedAndTheBatchContinues() {
        var session = PublishSession()
        let items = urls("big.bin", "ok.txt")
        _ = session.start(items)
        #expect(session.assessed(.refused("This is 60 MB, which is over the 52.4 MB the app can upload.")) == .assess(items[1], .publish))
        #expect(session.problems == [.init(name: "big.bin", message: "This is 60 MB, which is over the 52.4 MB the app can upload.")])
    }

    @Test func singleRefusalShowsTheMessageVerbatim() {
        var session = PublishSession()
        _ = session.start(urls("big.bin"))
        _ = session.assessed(.refused("Too big."))
        #expect(session.isFinished)
        #expect(session.headline == "Too big.")
        #expect(session.clipboardText == nil)
    }

    @Test func rateLimitStopsTheRestOfTheBatch() async throws {
        try await withTempDirectory { root in
            let a = try writeFile("a.txt", in: root)
            let items = [a] + urls("b.txt", "c.txt")
            var session = PublishSession()
            _ = session.start(items)
            _ = session.assessed(.upload(UploadRequest(plan: try makePlan(for: a, home: root))))
            let message = UptfError.rateLimited(retryAfter: 600).localizedDescription
            #expect(UserMessage.stopsBatch(UptfError.rateLimited(retryAfter: 600)))
            #expect(session.failed(message, stopsBatch: true) == .none)
            #expect(session.isFinished)
            #expect(session.skipped == 2)
            #expect(session.problems.first?.message == "Too many changes in a short time. Try again in 10 minutes.")
        }
    }

    @Test func itemsAddedWhileBusyJoinTheQueue() {
        var session = PublishSession()
        let first = urls("a.txt")
        let second = urls("b.txt")
        _ = session.start(first)
        #expect(session.start(second) == .none)
        #expect(session.total == 2)
        _ = session.assessed(.refused("no"))
        #expect(session.phase == .assessing(second[0]))
    }

    @Test func aNewSessionStartsCleanAfterOneFinished() {
        var session = PublishSession()
        _ = session.start(urls("a.txt"))
        _ = session.assessed(.refused("no"))
        #expect(session.isFinished)
        let next = urls("b.txt")
        #expect(session.start(next) == .assess(next[0], .publish))
        #expect(session.problems.isEmpty)
        #expect(session.total == 1)
    }

    @Test func copyingAnExistingLinkUploadsNothing() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let entry = try makeEntry(path: file.path)
            let existing = ExistingPublication(entry: entry, pageURL: "https://my-page.example.test", changed: false)
            let verdict = await makeAssessor(home: root, existing: { _ in existing }).assess(file, intent: .publish)
            var session = PublishSession()
            _ = session.start([file])
            _ = session.assessed(verdict)
            #expect(session.choose(.copyExistingLink) == .none)
            #expect(session.isFinished)
            #expect(session.clipboardText == "https://my-page.example.test")
            #expect(session.headline == "The link for “report.pdf” is copied.")
        }
    }

    @Test func updateKeepsTheLinkAndSaysSo() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let entry = try makeEntry(path: file.path)
            var session = PublishSession()
            #expect(session.start([file], intent: .updateLink(entryID: "page-1")) == .assess(file, .updateLink(entryID: "page-1")))
            _ = session.assessed(.upload(UploadRequest(plan: try makePlan(for: file, home: root), update: entry)))
            #expect(session.phase == .uploading(name: "report.pdf", isUpdate: true))
            _ = session.uploaded(url: entry.url)
            #expect(session.headline == "“report.pdf” is updated. Link copied.")
        }
    }

    @Test func sessionsFromFinderAlwaysGetTheirOwnWindow() {
        var session = PublishSession()
        _ = session.start(urls("a.txt"), origin: .finder)
        #expect(session.wantsWindow)
        _ = session.assessed(.refused("Nope."))
        #expect(session.wantsWindow)  // the result is shown there too
        session.dismiss()
        #expect(session.phase == .idle)
        #expect(!session.wantsWindow)
    }

    @Test func cancellingAllDropsTheQueue() {
        var session = PublishSession()
        _ = session.start(urls("a.txt", "b.txt", "c.txt"))
        session.cancelAll()
        #expect(session.isFinished)
        #expect(session.skipped == 3)
    }

    @Test func multipleLinksAreCopiedOnePerLine() async throws {
        try await withTempDirectory { root in
            let a = try writeFile("a.txt", in: root)
            let b = try writeFile("b.txt", in: root)
            var session = PublishSession()
            _ = session.start([a, b])
            _ = session.assessed(.upload(UploadRequest(plan: try makePlan(for: a, home: root))))
            _ = session.uploaded(url: "https://a.example.test")
            _ = session.assessed(.upload(UploadRequest(plan: try makePlan(for: b, home: root))))
            _ = session.uploaded(url: "https://b.example.test")
            #expect(session.clipboardText == "https://a.example.test\nhttps://b.example.test")
            #expect(session.headline == "2 links copied.")
        }
    }

    // MARK: Showing the menu bar window

    @Test func menuBarSessionsPresentTheMenuBarWindowWhenTheyStartAndFinish() {
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        typealias S = PublishSession
        // Starts (also after a finished one), and finishes: the user sees progress and the link.
        #expect(S.presentsMenuBar(from: .idle, to: .assessing(url), origin: .menu))
        #expect(S.presentsMenuBar(from: .finished, to: .assessing(url), origin: .menu))
        #expect(S.presentsMenuBar(from: .uploading(name: "a.txt", isUpdate: false), to: .finished, origin: .menu))
        #expect(S.presentsMenuBar(from: .assessing(url), to: .finished, origin: .menu))
        // Nothing to bring up while it is just moving along, or when nothing changed.
        #expect(!S.presentsMenuBar(from: .assessing(url), to: .uploading(name: "a.txt", isUpdate: false), origin: .menu))
        #expect(!S.presentsMenuBar(from: .finished, to: .finished, origin: .menu))
        #expect(!S.presentsMenuBar(from: .uploading(name: "a.txt", isUpdate: false), to: .assessing(url), origin: .menu))
    }

    @Test func menuBarWindowComesBackAfterAConfirmationIsAnswered() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("site/index.html", in: root)
            let confirmation = PublishConfirmation(
                url: site, plan: try makePlan(for: site, home: root), intent: .publish, warnings: [],
                folder: nil, existing: nil)
            // The confirmation has its own window; the answer sends the work back to the menu bar.
            #expect(!PublishSession.presentsMenuBar(from: .assessing(site), to: .confirming(confirmation), origin: .menu))
            #expect(PublishSession.presentsMenuBar(
                from: .confirming(confirmation), to: .uploading(name: "site", isUpdate: false), origin: .menu))
        }
    }

    @Test func finderSessionsKeepTheirOwnWindow() {
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        #expect(!PublishSession.presentsMenuBar(from: .idle, to: .assessing(url), origin: .finder))
        #expect(!PublishSession.presentsMenuBar(from: .uploading(name: "a.txt", isUpdate: false), to: .finished, origin: .finder))
    }
}

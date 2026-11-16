import Foundation
import Testing
import UptfKit

@testable import UploadTheFileCore

@Suite("Finder confirmation")
struct FinderConfirmationTests {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func aPlainFileStillWaitsForAnswerWhenConfirmationIsRequired() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("Documents/report.pdf", in: root)
            let verdict = await makeAssessor(home: root).assess(file, intent: .publish, requireConfirmation: true)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm, got \(verdict)"); return }
            #expect(confirmation.title == "Publish “report.pdf”?")
            #expect(confirmation.options.map(\.title) == ["Publish"])
            #expect(confirmation.warnings.isEmpty)
            #expect(confirmation.request(for: .publishNew)?.update == nil)
        }
    }

    @Test func aFileThatCannotBePublishedIsRefusedWithoutAsking() async throws {
        try await withTempDirectory { root in
            let verdict = await makeAssessor(home: root)
                .assess(root.appendingPathComponent("nope.txt"), intent: .publish, requireConfirmation: true)
            guard case .refused = verdict else { Issue.record("expected refusal, got \(verdict)"); return }
        }
    }

    @Test func itemsFromTheFinderServiceAreAssessedWithConfirmationRequired() {
        var session = PublishSession()
        let items = urls("a.txt", "b.txt")
        #expect(session.start(items, origin: .finder) == .assess(items[0], .publish))
        #expect(session.assessmentRequiresConfirmation)
        _ = session.assessed(.refused("no"))
        #expect(session.phase == .assessing(items[1]))
        #expect(session.assessmentRequiresConfirmation)
    }

    @Test func itemsFromTheMenuBarAreNotAskedAgain() {
        var session = PublishSession()
        let items = urls("a.txt")
        _ = session.start(items, origin: .menu)
        #expect(!session.assessmentRequiresConfirmation)
    }

    @Test func aBatchTheUserAlreadyConfirmedIsNotAskedItemByItem() {
        var session = PublishSession()
        _ = session.start(urls("a.txt", "b.txt"), origin: .finder, confirmed: true)
        #expect(!session.assessmentRequiresConfirmation)
        _ = session.assessed(.refused("no"))
        #expect(!session.assessmentRequiresConfirmation)
    }

    @Test func aFinderItemJoiningAMenuQueueStillNeedsItsOwnAnswer() {
        var session = PublishSession()
        let menu = urls("a.txt")
        let finder = urls("b.txt")
        _ = session.start(menu, origin: .menu)
        #expect(!session.assessmentRequiresConfirmation)
        _ = session.start(finder, origin: .finder)
        _ = session.assessed(.refused("no"))
        #expect(session.phase == .assessing(finder[0]))
        #expect(session.assessmentRequiresConfirmation)
    }

    @Test func theServiceInputIsDeduplicatedLikeADrop() {
        let file = URL(fileURLWithPath: "/Users/alex/Documents/report.pdf")
        let same = URL(fileURLWithPath: "/Users/alex/Documents/./report.pdf")
        let items = DroppedItems.publishableFileURLs(from: [file, same, URL(string: "https://example.com/x")!])
        #expect(items.map(\.path) == [file.path])
    }
}

@Suite("Batch confirmation")
struct BatchConfirmationTests {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }
    private let noFolders: (URL) -> Bool = { _ in false }

    @Test func oneItemNeedsNoQuestion() {
        #expect(BatchConfirmation(urls: urls("a.txt"), isFolder: noFolders) == nil)
        #expect(BatchConfirmation(urls: [], isFolder: noFolders) == nil)
        #expect(!BatchConfirmation.isNeeded(itemCount: 1, intent: .publish))
    }

    @Test func moreThanOneItemAsksOnceAndListsThem() throws {
        let batch = try #require(BatchConfirmation(urls: urls("a.txt", "b.pdf", "c.png"), isFolder: noFolders))
        #expect(batch.title == "Publish 3 files?")
        #expect(batch.shown == ["a.txt", "b.pdf", "c.png"])
        #expect(batch.hiddenCount == 0)
        #expect(batch.urls == urls("a.txt", "b.pdf", "c.png"))
        #expect(batch.detail == "Each one gets its own link.")
    }

    @Test func replacingALinkNeverAsks() {
        #expect(BatchConfirmation(urls: urls("a.txt", "b.txt"), intent: .updateLink(entryID: "page-1"), isFolder: noFolders) == nil)
    }

    @Test func folderNamesAreCountedInTheTitle() throws {
        let isFolder: (URL) -> Bool = { $0.lastPathComponent.hasPrefix("dir") }
        let folders = try #require(BatchConfirmation(urls: urls("dir1", "dir2"), isFolder: isFolder))
        #expect(folders.title == "Publish 2 folders?")
        let mixed = try #require(BatchConfirmation(urls: urls("dir1", "a.txt"), isFolder: isFolder))
        #expect(mixed.title == "Publish 2 files and folders?")
    }

    @Test func aRealFolderIsRecognisedOnDisk() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("a.txt", in: root)
            let folder = root.appendingPathComponent("site", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(BatchConfirmation.isFolderOnDisk(folder))
            #expect(!BatchConfirmation.isFolderOnDisk(file))
            #expect(!BatchConfirmation.isFolderOnDisk(root.appendingPathComponent("missing")))
        }
    }

    @Test func longListsAreCutOffWithACount() throws {
        let names = (0..<250).map { URL(fileURLWithPath: "/tmp/file-\($0).txt") }
        let batch = try #require(BatchConfirmation(urls: names, isFolder: noFolders))
        #expect(batch.title == "Publish 250 files?")
        #expect(batch.shown.count == BatchConfirmation.displayLimit)
        #expect(batch.hiddenCount == 50)
    }

    @Test func itemsThatArriveWhileAskingJoinTheSameQuestion() throws {
        var batch = try #require(BatchConfirmation(urls: urls("a.txt", "b.txt"), isFolder: noFolders))
        batch.add(urls("c.txt"), isFolder: noFolders)
        #expect(batch.title == "Publish 3 files?")
        #expect(batch.urls.last?.lastPathComponent == "c.txt")
    }

    @Test func theAnswerIsTheOnlyThingThatStartsASession() throws {
        // Asking changes nothing in a session; the publish starts when the answer is yes, with the
        // items and origin of the question.
        let batch = try #require(BatchConfirmation(urls: urls("a.txt", "b.txt"), origin: .finder, isFolder: noFolders))
        var session = PublishSession()
        #expect(session.phase == .idle)
        #expect(batch.origin == .finder)
        let effect = session.start(batch.urls, intent: .publish, origin: batch.origin, confirmed: true)
        #expect(effect == .assess(batch.urls[0], .publish))
        #expect(session.total == 2)
    }
}

@Suite("Stopping a queue")
struct StopQueueTests {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func stopEndsTheQueueAfterTheItemInProgress() async throws {
        try await withTempDirectory { root in
            let a = try writeFile("a.txt", in: root)
            let items = [a] + urls("b.txt", "c.txt")
            var session = PublishSession()
            _ = session.start(items)
            #expect(session.canStop)
            _ = session.assessed(.upload(UploadRequest(plan: try makePlan(for: a, home: root))))
            #expect(session.canStop)

            session.stop()
            #expect(!session.canStop)
            #expect(session.total == 1)
            #expect(session.phase == .uploading(name: "a.txt", isUpdate: false))

            // The upload that was running finishes and its link is kept; nothing else starts.
            #expect(session.uploaded(url: "https://a.example.test") == .none)
            #expect(session.isFinished)
            #expect(session.links.map(\.url) == ["https://a.example.test"])
            #expect(session.headline == "“a.txt” is published. Link copied.")
        }
    }

    @Test func aSingleItemHasNothingToStop() {
        var session = PublishSession()
        _ = session.start(urls("a.txt"))
        #expect(!session.canStop)
    }

    @Test func aFinishedSessionCannotBeStopped() {
        var session = PublishSession()
        _ = session.start(urls("a.txt"))
        _ = session.assessed(.refused("no"))
        #expect(session.isFinished)
        #expect(!session.canStop)
    }
}

import Foundation
import Testing
import UptfKit

@testable import UploadTheFileCore

@Suite("PublishAssessor")
struct PublishAssessorTests {
    @Test func plainFileUploadsWithoutAsking() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("Documents/report.pdf", in: root)
            let verdict = await makeAssessor(home: root).assess(file, intent: .publish)
            guard case .upload(let request) = verdict else { Issue.record("expected upload, got \(verdict)"); return }
            #expect(request.plan.kind == .file)
            #expect(request.update == nil)
            #expect(!request.hostAsSite)
        }
    }

    @Test func fileOverFiftyMegabytesIsRefusedWithTheLibraryMessage() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("big.bin", in: root)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 51 * 1024 * 1024)  // sparse: no real disk use
            try handle.close()
            let verdict = await makeAssessor(home: root).assess(file, intent: .publish)
            let expected = UptfError.tooLarge(bytes: 51 * 1024 * 1024).localizedDescription
            #expect(verdict == .refused(expected))
            #expect(expected.contains("can send files up to"))
            #expect(expected.contains("Use the upload.tf website for larger files."))
        }
    }

    @Test func missingPathIsRefused() async throws {
        try await withTempDirectory { root in
            let verdict = await makeAssessor(home: root).assess(root.appendingPathComponent("nope.txt"), intent: .publish)
            guard case .refused(let message) = verdict else { Issue.record("expected refusal"); return }
            #expect(message.contains("No such file or folder"))
        }
    }

    @Test func folderAsksAndListsExactlyWhatIsUploaded() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("site/index.html", in: root)
            try writeFile("site/css/app.css", in: root)
            try writeFile("site/.env", in: root)
            try writeFile("site/.git/config", in: root)
            try writeFile("site/node_modules/x/index.js", in: root)
            let verdict = await makeAssessor(home: root).assess(site, intent: .publish)
            guard case .confirm(let confirmation) = verdict, let listing = confirmation.folder else {
                Issue.record("expected a folder confirmation, got \(verdict)"); return
            }
            #expect(listing.entries == ["css/app.css", "index.html"])
            #expect(listing.summary == "2 files will go online")
            #expect(listing.servedAsWebsite)
            #expect(listing.hiddenCount == 0)
            #expect(FolderListing.leftOutNote.contains(".git"))
            #expect(confirmation.options.map(\.choice) == [.publishNew])
            #expect(confirmation.title == "Publish “site”?")
            #expect(confirmation.options.map(\.title) == ["Publish"])
            #expect(confirmation.request(for: .publishNew)?.hostAsSite == true)
        }
    }

    @Test func longFolderListsAreCutOffWithACount() {
        let entries = (0..<250).map { "file-\($0).txt" }
        let listing = FolderListing(folderName: "f", entries: entries, servedAsWebsite: false)
        #expect(listing.shown.count == FolderListing.displayLimit)
        #expect(listing.hiddenCount == 50)
        #expect(FolderListing(folderName: "f", entries: ["a"], servedAsWebsite: false).summary == "1 file will go online")
    }

    @Test func emptyFolderIsRefused() async throws {
        try await withTempDirectory { root in
            let folder = root.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeFile("empty/.env", in: root)
            let verdict = await makeAssessor(home: root).assess(folder, intent: .publish)
            guard case .refused(let message) = verdict else { Issue.record("expected refusal, got \(verdict)"); return }
            #expect(message.contains("nothing to put online"))
        }
    }

    @Test func credentialFoldersNeedConfirmation() async throws {
        try await withTempDirectory { home in
            let file = try writeFile(".ssh/notes.txt", in: home)
            let verdict = await makeAssessor(home: home).assess(file, intent: .publish)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm, got \(verdict)"); return }
            #expect(confirmation.warnings.count == 1)
            #expect(confirmation.warnings[0].contains("~/.ssh"))
            #expect(confirmation.title == "Publish “notes.txt”? It may be sensitive")
        }
    }

    @Test func secretLookingFileNeedsConfirmation() async throws {
        try await withTempDirectory { home in
            let file = try writeFile("Documents/server.pem", in: home)
            let verdict = await makeAssessor(home: home).assess(file, intent: .publish)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm"); return }
            #expect(confirmation.warnings.first?.contains("looks like it holds a password or key") == true)
        }
    }

    @Test func hiddenPathsNeedConfirmation() async throws {
        try await withTempDirectory { home in
            let inside = try writeFile(".config/tool/settings.json", in: home)
            let verdict = await makeAssessor(home: home).assess(inside, intent: .publish)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm"); return }
            #expect(confirmation.warnings == ["Careful with “settings.json”: it is inside the hidden folder “.config”."])

            let hiddenFile = try writeFile(".notes", in: home)
            let direct = await makeAssessor(home: home).assess(hiddenFile, intent: .publish)
            guard case .confirm(let second) = direct else { Issue.record("expected confirm"); return }
            #expect(second.warnings == ["Careful with “.notes”: it is a hidden file or folder."])
        }
    }

    @Test func alreadyPublishedUnchangedOffersCopyOrNewLink() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let existing = ExistingPublication(entry: try makeEntry(path: file.path), pageURL: "https://my-page.example.test", changed: false)
            let verdict = await makeAssessor(home: root, existing: { _ in existing }).assess(file, intent: .publish)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm"); return }
            #expect(confirmation.options.map(\.choice) == [.copyExistingLink, .publishNew])
            #expect(confirmation.options.map(\.title) == ["Copy Link", "Publish as a New Link"])
            #expect(confirmation.options.first?.isPrimary == true)
            #expect(confirmation.title == "“report.pdf” is already online")
            #expect(confirmation.request(for: .copyExistingLink) == nil)
        }
    }

    @Test func alreadyPublishedAndChangedOffersUpdateOrNewLink() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let entry = try makeEntry(path: file.path)
            let existing = ExistingPublication(entry: entry, pageURL: entry.url, changed: true)
            let verdict = await makeAssessor(home: root, existing: { _ in existing }).assess(file, intent: .publish)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm"); return }
            #expect(confirmation.options.map(\.choice) == [.updateExisting, .publishNew])
            #expect(confirmation.options.map(\.title) == ["Replace File", "Publish as a New Link"])
            #expect(confirmation.request(for: .updateExisting)?.update == entry)
            #expect(confirmation.request(for: .publishNew)?.update == nil)
        }
    }

    @Test func updateLinkOnAPlainFileUploadsStraightAway() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let entry = try makeEntry(path: file.path)
            let existing = ExistingPublication(entry: entry, pageURL: entry.url, changed: true)
            let verdict = await makeAssessor(home: root, existing: { _ in existing }).assess(file, intent: .updateLink)
            guard case .upload(let request) = verdict else { Issue.record("expected upload, got \(verdict)"); return }
            #expect(request.update == entry)
            #expect(request.plan.kind == .file)
        }
    }

    @Test func updateLinkForAPageThatIsGoneIsRefused() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let verdict = await makeAssessor(home: root).assess(file, intent: .updateLink)
            guard case .refused(let message) = verdict else { Issue.record("expected refusal"); return }
            #expect(message.contains("isn't in your account anymore"))
        }
    }

    @Test func updateLinkForAFolderStillShowsTheList() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("site/index.html", in: root)
            let entry = try makeEntry(path: site.path, hostedAsSite: true)
            let existing = ExistingPublication(entry: entry, pageURL: entry.url, changed: true)
            let verdict = await makeAssessor(home: root, existing: { _ in existing }).assess(site, intent: .updateLink)
            guard case .confirm(let confirmation) = verdict else { Issue.record("expected confirm"); return }
            #expect(confirmation.options.map(\.choice) == [.updateExisting])
            #expect(confirmation.title == "Replace “site” and keep the same link?")
            #expect(confirmation.folder?.entries == ["index.html"])
        }
    }

    @Test func lookupFailuresSurfaceTheirOwnMessage() async throws {
        try await withTempDirectory { root in
            let file = try writeFile("report.pdf", in: root)
            let verdict = await makeAssessor(home: root, existing: { _ in throw UptfError.rateLimited(retryAfter: 125) })
                .assess(file, intent: .publish)
            #expect(verdict == .refused("Too many changes in a short time. Try again in 3 minutes."))
        }
    }
}

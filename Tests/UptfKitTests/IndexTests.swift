import Foundation
import Testing

@testable import UptfKit

@Suite("PublishedIndex")
struct IndexTests {
    private let origin = "https://uploadthefile.test"

    @Test func recordsRoundTripThroughTheFile() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("report.pdf", in: directory, contents: "v1")
            let indexURL = directory.appendingPathComponent("index/published-index.json")

            let index = PublishedIndex(fileURL: indexURL, origin: origin)
            let recorded = try await index.record(
                fileURL: file, id: "p1", name: "report", url: "https://report.upload.tf", kind: .file,
                publishedAt: Date(timeIntervalSince1970: 1_800_000_000))  // whole seconds: the file stores ISO 8601
            #expect(recorded.slug == "report")

            // A second instance (the app next to the CLI) sees the same data.
            let other = PublishedIndex(fileURL: indexURL, origin: origin)
            let entries = try await other.entries()
            #expect(entries == [recorded])
            #expect(entries[0].id == "p1")
            #expect(entries[0].name == "report")
            #expect(entries[0].lastKnownPath == file.path)
            #expect(entries[0].sha256 == (try Fingerprint.sha256(of: file)))
            #expect(try await other.entry(for: file) == recorded)
            #expect(try await other.entry(forID: "p1") == recorded)
            #expect(try await other.entry(matching: "report") == recorded)
            #expect(try await other.entry(matching: "p1") == recorded)
            #expect(try await other.entry(matching: "nope") == nil)
        }
    }

    @Test func idOnlyPagesUseTheIdAsSlug() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("a.txt", in: directory)
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)
            let entry = try await index.record(fileURL: file, id: "a1b2c3d4", name: nil, url: "https://a1b2c3d4.upload.tf", kind: .file)
            #expect(entry.slug == "a1b2c3d4")
            #expect(try await index.entry(matching: "a1b2c3d4")?.id == "a1b2c3d4")
        }
    }

    @Test func changeDetectionForFiles() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("page.html", in: directory, contents: "one")
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)

            #expect(try await index.changedSincePublish(file) == true)  // never published
            try await index.record(fileURL: file, id: "p1", name: "page", url: "https://page.upload.tf", kind: .file)
            #expect(try await index.changedSincePublish(file) == false)

            try Data("two".utf8).write(to: file)
            #expect(try await index.changedSincePublish(file) == true)

            try await index.record(fileURL: file, id: "p1", name: "page", url: "https://page.upload.tf", kind: .file)
            #expect(try await index.changedSincePublish(file) == false)
            #expect(try await index.entries().count == 1)  // same page, same path: replaced, not duplicated
        }
    }

    @Test func changeDetectionForFolders() async throws {
        try await withTempDirectory { directory in
            let site = directory.appendingPathComponent("site")
            try writeFile("site/index.html", in: directory, contents: "hello")
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)
            try await index.record(fileURL: site, id: "s1", name: "site", url: "https://site.upload.tf", kind: .folder, hostedAsSite: true)
            #expect(try await index.changedSincePublish(site) == false)

            // Files that never go into the zip do not count as changes.
            try writeFile("site/.env", in: directory, contents: "SECRET=1")
            try writeFile("site/node_modules/x.js", in: directory)
            try writeFile("site/.DS_Store", in: directory)
            #expect(try await index.changedSincePublish(site) == false)

            try writeFile("site/about.html", in: directory)
            #expect(try await index.changedSincePublish(site) == true)
        }
    }

    @Test func aMovedFileIsFoundThroughItsBookmark() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("old/report.pdf", in: directory)
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)
            try await index.record(fileURL: file, id: "p1", name: "report", url: "https://report.upload.tf", kind: .file)

            let moved = directory.appendingPathComponent("new/renamed.pdf")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: moved)

            #expect(try await index.entry(for: moved)?.id == "p1")
        }
    }

    @Test func reconcileFollowsRenamesByIdAndDropsDeletedPages() async throws {
        try await withTempDirectory { directory in
            let kept = try writeFile("kept.html", in: directory)
            let gone = try writeFile("gone.html", in: directory)
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)
            try await index.record(fileURL: kept, id: "p1", name: "old-name", url: "https://old-name.upload.tf", kind: .file)
            try await index.record(fileURL: gone, id: "p2", name: "gone", url: "https://gone.upload.tf", kind: .file)

            // The page p1 was renamed on the website; p2 was deleted there; p3 is somebody else's concern.
            let dropped = try await index.reconcile(with: [
                makePage(id: "p1", name: "new-name", url: "https://new-name.upload.tf"),
                makePage(id: "p3", name: "unrelated"),
            ])

            #expect(dropped.map(\.id) == ["p2"])
            let entries = try await index.entries()
            #expect(entries.map(\.id) == ["p1"])
            #expect(entries[0].name == "new-name")
            #expect(entries[0].slug == "new-name")
            #expect(entries[0].url == "https://new-name.upload.tf")
            // The local link survived the rename.
            #expect(try await index.entry(for: kept)?.id == "p1")
            #expect(try await index.entry(matching: "new-name")?.id == "p1")
            #expect(try await index.entry(matching: "old-name") == nil)
            #expect(try await index.entry(for: gone) == nil)
        }
    }

    @Test func reconcileKeepsOtherOriginsAlone() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("a.html", in: directory)
            let url = directory.appendingPathComponent("i.json")
            let production = PublishedIndex(fileURL: url, origin: origin)
            let dev = PublishedIndex(fileURL: url, origin: "http://localhost:3000")
            try await production.record(fileURL: file, id: "p1", name: "a", url: "https://a.upload.tf", kind: .file)
            try await dev.record(fileURL: file, id: "p1", name: "a", url: "http://a.localhost:3000", kind: .file)

            let dropped = try await production.reconcile(with: [])
            #expect(dropped.count == 1)
            #expect(try await production.entries().isEmpty)
            #expect(try await dev.entries().count == 1)
        }
    }

    @Test func applyUpdatesNameAndURLOfARecordedPage() async throws {
        try await withTempDirectory { directory in
            let file = try writeFile("a.html", in: directory)
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)
            try await index.record(fileURL: file, id: "p1", name: "before", url: "https://before.upload.tf", kind: .file)

            try await index.apply(makePage(id: "p1", name: "after"))
            #expect(try await index.entry(forID: "p1")?.name == "after")
            #expect(try await index.entry(forID: "p1")?.url == "https://after.upload.tf")

            try await index.apply(makePage(id: "unknown", name: "x"))  // not recorded: nothing happens
            #expect(try await index.entries().count == 1)
        }
    }

    @Test func removeForgetsOnlyThatPage() async throws {
        try await withTempDirectory { directory in
            let a = try writeFile("a.html", in: directory)
            let b = try writeFile("b.html", in: directory)
            let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: origin)
            try await index.record(fileURL: a, id: "p1", name: "a", url: "https://a.upload.tf", kind: .file)
            try await index.record(fileURL: b, id: "p2", name: "b", url: "https://b.upload.tf", kind: .file)
            try await index.remove(id: "p1")
            #expect(try await index.entries().map(\.id) == ["p2"])
        }
    }

    @Test func aHistoryFromBeforeIdKeyingIsIgnoredNotAnError() async throws {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("i.json")
            try Data(#"{"version":1,"entries":[{"origin":"https://uploadthefile.test","slug":"old"}]}"#.utf8).write(to: url)
            let index = PublishedIndex(fileURL: url, origin: origin)
            #expect(try await index.entries().isEmpty)
        }
    }

    @Test func aCorruptHistoryIsReportedNotOverwritten() async throws {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("i.json")
            try Data("not json".utf8).write(to: url)
            let index = PublishedIndex(fileURL: url, origin: origin)
            await #expect(throws: UptfError.self) { try await index.entries() }
            #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
        }
    }
}

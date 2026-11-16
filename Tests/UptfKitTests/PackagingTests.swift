import Foundation
import Testing

@testable import UptfKit

@Suite("Zipping and sensitive paths")
struct PackagingTests {
    private func makeSite(in root: URL) throws {
        try writeFile("index.html", in: root, contents: "<h1>hi</h1>")
        try writeFile("css/site.css", in: root)
        try writeFile("assets/img/logo.png", in: root)
        try writeFile("docs/guide/intro.md", in: root)
        // Everything below must stay out.
        try writeFile(".git/config", in: root)
        try writeFile(".git/objects/ab/cdef", in: root)
        try writeFile(".env", in: root, contents: "SECRET=1")
        try writeFile(".env.local", in: root, contents: "SECRET=2")
        try writeFile("node_modules/pkg/index.js", in: root)
        try writeFile("a.pem", in: root)
        try writeFile("certs/server.key", in: root)
        try writeFile("deploy/id_rsa", in: root)
        try writeFile(".DS_Store", in: root)
        try writeFile(".hidden", in: root)
        try writeFile(".config/settings.json", in: root)
    }

    @Test func previewLeavesOutSecretsHiddenFilesAndDependencies() async throws {
        try await withTempDirectory { root in
            try makeSite(in: root)
            let entries = try FolderZipper.previewEntries(folder: root)
            #expect(entries == ["assets/img/logo.png", "css/site.css", "docs/guide/intro.md", "index.html"])
        }
    }

    @Test func includingHiddenFilesStillKeepsSecretsAndVersionControlOut() async throws {
        try await withTempDirectory { root in
            try makeSite(in: root)
            let entries = try FolderZipper.previewEntries(folder: root, includeHidden: true)
            #expect(entries.contains(".hidden"))
            #expect(entries.contains(".config/settings.json"))
            for forbidden in [".git/config", ".env", ".env.local", "node_modules/pkg/index.js", "a.pem", "certs/server.key", "deploy/id_rsa", ".DS_Store"] {
                #expect(!entries.contains(forbidden), "\(forbidden) must never be included")
            }
        }
    }

    @Test func symbolicLinksAreNotFollowed() async throws {
        try await withTempDirectory { root in
            try writeFile("real.txt", in: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("real.txt"))
            #expect(try FolderZipper.previewEntries(folder: root) == ["real.txt"])
        }
    }

    @Test func theZipContainsExactlyThePreviewedFiles() async throws {
        try await withTempDirectory { root in
            try makeSite(in: root)
            let output = try await FolderZipper.zip(folder: root)
            defer { try? FileManager.default.removeItem(at: output.url.deletingLastPathComponent()) }

            #expect(output.bytes > 0)
            #expect(output.entries == (try FolderZipper.previewEntries(folder: root)))

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-Z1", output.url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(listing.split(separator: "\n").map(String.init).sorted() == output.entries)
        }
    }

    @Test func aFolderOfOnlyExcludedFilesCannotBeZipped() async throws {
        try await withTempDirectory { root in
            try writeFile(".env", in: root)
            try writeFile("node_modules/x.js", in: root)
            let error = await thrownUptfError { try await FolderZipper.zip(folder: root) }
            #expect(error?.localizedDescription.contains("nothing to put online") == true)
        }
    }

    @Test func secretNames() {
        for name in [".env", ".env.production", "a.pem", "KEY.PEM", "server.key", "id_rsa", "id_rsa.pub", "id_ed25519", "cert.p12", "login.keychain-db"] {
            #expect(ZipExclusions.isSecretName(name), "\(name) should count as secret")
        }
        for name in ["index.html", "environment.md", "monkey.txt", "keynote.pdf", "pem.txt"] {
            #expect(!ZipExclusions.isSecretName(name), "\(name) should be fine")
        }
    }

    @Test func sensitivePaths() async throws {
        try await withTempDirectory { home in
            try writeFile(".ssh/id_rsa", in: home)
            try writeFile(".aws/credentials", in: home)
            try writeFile("Library/Keychains/login.keychain-db", in: home)
            try writeFile("Sites/blog/index.html", in: home)
            try writeFile("Sites/blog/.env", in: home)

            // Inside a credentials folder.
            #expect(SensitivePath.reason(for: home.appendingPathComponent(".ssh/id_rsa"), home: home) != nil)
            #expect(SensitivePath.reason(for: home.appendingPathComponent(".ssh"), home: home) != nil)
            #expect(SensitivePath.reason(for: home.appendingPathComponent(".aws"), home: home) != nil)
            #expect(SensitivePath.reason(for: home.appendingPathComponent("Library/Keychains"), home: home) != nil)
            // A folder that contains one is refused outright, not just warned about.
            #expect(SensitivePath.containsProtectedFolder(home, home: home))
            #expect(SensitivePath.containsProtectedFolder(home.appendingPathComponent("Library"), home: home))
            #expect(SensitivePath.reason(for: home, home: home) == nil)
            // Secret-looking files anywhere.
            #expect(SensitivePath.reason(for: home.appendingPathComponent("Sites/blog/.env"), home: home) != nil)
            // Ordinary things.
            #expect(SensitivePath.reason(for: home.appendingPathComponent("Sites/blog"), home: home) == nil)
            #expect(SensitivePath.reason(for: home.appendingPathComponent("Sites/blog/index.html"), home: home) == nil)
        }
    }

    @Test func aSecretFolderNamedLikeAFileIsOnlyJudgedByItsContents() async throws {
        // A directory called "a.pem" is not a key file; its contents are filtered by the zipper.
        try await withTempDirectory { home in
            try writeFile("site/a.pem/readme.txt", in: home)
            #expect(SensitivePath.reason(for: home.appendingPathComponent("site/a.pem"), home: home) == nil)
        }
    }
}

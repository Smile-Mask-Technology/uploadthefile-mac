import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import UptfKit

// MARK: - Helpers

/// A sparse file that reports `bytes` as its size without using the disk space.
private func makeSparseFile(at url: URL, bytes: Int64) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
}

private func megabytes(_ count: Int64) -> Int64 { count * 1024 * 1024 }

/// Extracts `archive` with `/usr/bin/unzip` and returns each file's relative path and contents.
private func extract(_ archive: URL, into directory: URL) throws -> [String: String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", archive.path, "-d", directory.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    var files: [String: String] = [:]
    let walker = FileManager.default.enumerator(atPath: directory.path)
    while let relative = walker?.nextObject() as? String {
        let url = directory.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        files[relative] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
    return files
}

private func packagingPublisher(index: URL, transport: any ClientTransport) -> Publisher {
    let store = InMemoryTokenStore([
        testConfig.origin: StoredCredentials(
            accessToken: "test-access", refreshToken: "test-refresh",
            expiresAt: Date().addingTimeInterval(3600), clientId: "test-client")
    ])
    let tokens = TokenManager(origin: testConfig.origin, store: store, refresher: NoRefresh())
    let client = UptfClient(config: testConfig, tokens: tokens, transport: transport)
    return Publisher(client: client, index: PublishedIndex(fileURL: index, origin: testConfig.origin))
}

/// Answers an upload and the page lookup after it, and keeps what was sent.
private final class UploadCapturingTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentBodies: [Data] = []
    private var sentRequests: [String] = []

    var requests: [String] { lock.withLock { sentRequests } }
    var bodies: [Data] { lock.withLock { sentBodies } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let line = "\(request.method.rawValue) \(request.path ?? "")"
        let data: Data?
        if let body { data = try await Data(collecting: body, upTo: 200 * 1024 * 1024) } else { data = nil }
        lock.withLock {
            sentRequests.append(line)
            if let data { sentBodies.append(data) }
        }
        let reply: FakeReply
        switch line {
        case "POST /upload":
            reply = .json(#"{"success":true,"data":{"url":"https://fresh.upload.tf","slug":"fresh","hasHtml":true}}"#, status: 201)
        case "GET /pages/fresh":
            reply = .json(pageEnvelopeJSON(pageJSON(id: "p1", name: "fresh")))
        default:
            reply = .error(404, "nope")
        }
        var response = HTTPResponse(status: .init(code: reply.status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(reply.body))
    }
}

// MARK: - Protected folders

@Suite("Protected folders")
struct ProtectedFolderTests {
    @Test func foldersThatHoldAProtectedFolderAreRefusedWhateverElseIsAllowed() async throws {
        try await withTempDirectory { home in
            try writeFile(".ssh/id_rsa", in: home)
            try writeFile("Sites/blog/index.html", in: home)
            let publisher = packagingPublisher(index: home.appendingPathComponent("index.json"), transport: UploadCapturingTransport())

            for place in ["", "Library", ".config", "Library/Application Support"] {
                let url = place.isEmpty ? home : home.appendingPathComponent(place, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let error = await thrownUptfError { try publisher.prepare(url, allowSensitive: true, home: home) }
                #expect(error?.localizedDescription == SensitivePath.containsProtectedMessage, "\(place) must be refused")
            }
            // An ordinary folder in the same home is fine.
            let plan = try publisher.prepare(home.appendingPathComponent("Sites/blog"), allowSensitive: true, home: home)
            #expect(plan.entries == ["index.html"])
        }
    }

    @Test func theRefusalNamesWhatToDoInPlainWords() {
        let message = SensitivePath.containsProtectedMessage
        #expect(message.contains("private files"))
        #expect(message.contains("Choose a smaller folder"))
        for banned in ["host", "deploy", "URL", "token", "server", "zip"] {
            #expect(!message.contains(banned), "“\(banned)” is not a plain word")
        }
    }

    @Test func rootDisksAndTheHomeFolderCountAsHoldingOne() async throws {
        try await withTempDirectory { home in
            for path in ["/", "/Volumes", "/Volumes/Backup", "/Users"] {
                #expect(SensitivePath.containsProtectedFolder(URL(fileURLWithPath: path), home: URL(fileURLWithPath: "/Users/someone")), "\(path)")
            }
            #expect(SensitivePath.containsProtectedFolder(home, home: home))
            #expect(!SensitivePath.containsProtectedFolder(URL(fileURLWithPath: "/Volumes/Backup/photos"), home: home))
            #expect(!SensitivePath.containsProtectedFolder(home.appendingPathComponent("Documents"), home: home))
        }
    }

    @Test func ancestorsOfEveryProtectedPathAreRefused() async throws {
        try await withTempDirectory { home in
            for path in SensitivePath.protectedPaths {
                var parts = path.split(separator: "/").map(String.init)
                // Every folder on the way to a protected path holds it.
                while parts.count > 1 {
                    parts.removeLast()
                    let ancestor = home.appendingPathComponent(parts.joined(separator: "/"))
                    #expect(SensitivePath.containsProtectedFolder(ancestor, home: home), "\(parts.joined(separator: "/")) holds \(path)")
                }
            }
        }
    }

    @Test func folderAndFileNamesAreMatchedWhateverTheirCase() async throws {
        try await withTempDirectory { home in
            #expect(SensitivePath.reason(for: home.appendingPathComponent(".SSH/config"), home: home) != nil)
            #expect(SensitivePath.reason(for: home.appendingPathComponent("library/KEYCHAINS"), home: home) != nil)
            #expect(SensitivePath.containsProtectedFolder(home.appendingPathComponent("LIBRARY"), home: home))
            #expect(SensitivePath.containsProtectedFolder(home.appendingPathComponent(".Config"), home: home))
            #expect(SensitivePath.reason(for: home.appendingPathComponent("Sites/ID_RSA"), home: home) != nil)
        }
    }

    @Test func credentialAndBrowserFoldersAreProtected() async throws {
        try await withTempDirectory { home in
            for path in [
                ".config/gh/hosts.yml", ".netrc", ".docker/config.json", ".kube/config", ".git-credentials", ".npmrc",
                ".pgpass", ".config/gcloud/credentials.db", ".azure/accessTokens.json",
                "Library/Application Support/Google/Chrome/Default/Cookies",
                "Library/Application Support/Firefox/Profiles/x/cookies.sqlite",
                "Library/Application Support/BraveSoftware/Brave-Browser/Default",
                "Library/Application Support/Microsoft Edge/Default", "Library/Application Support/Arc/StorableSidebar.json",
                "Library/Mail/V10/x.emlx", "Library/Messages/chat.db", "Library/Cookies/Cookies.binarycookies",
                "Library/Safari/History.db", "Library/Application Support/UploadTheFile/index.json",
            ] {
                #expect(SensitivePath.reason(for: home.appendingPathComponent(path), home: home) != nil, "\(path) must be protected")
            }
            #expect(SensitivePath.reason(for: home.appendingPathComponent(".config/settings.json"), home: home) == nil)
            #expect(SensitivePath.reason(for: home.appendingPathComponent(".docker/other.json"), home: home) == nil)
        }
    }

    @Test func aLinkIsJudgedByTheNameOfWhatItPointsTo() async throws {
        try await withTempDirectory { root in
            let secret = try writeFile("keys/.env", in: root, contents: "A=1")
            let link = root.appendingPathComponent("notes.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
            #expect(SensitivePath.reason(for: link, home: root.appendingPathComponent("elsewhere")) != nil)
        }
    }
}

// MARK: - Exclusions

@Suite("Exclusions")
struct ExclusionTests {
    @Test func moreSecretNamesAreRecognised() {
        for name in [
            "id_ecdsa", "id_dsa.pub", "cert.pfx", "store.jks", "release.keystore", "putty.ppk", "vault.kdbx", "work.ovpn",
            "terraform.tfstate", "terraform.tfstate.backup", "prod.tfvars", "app.mobileprovision", "credentials.json",
            "service-account-prod.json", ".envrc", ".netrc", ".npmrc", ".pgpass", ".htpasswd", ".git-credentials",
            "ID_RSA", "Server.KEY", ".ENV",
        ] {
            #expect(ZipExclusions.isSecretName(name), "\(name) should count as secret")
        }
        for name in ["credentials-guide.md", "service.json", "variables.tf", "keys.html", "profile.png"] {
            #expect(!ZipExclusions.isSecretName(name), "\(name) should be fine")
        }
    }

    @Test func hiddenFilesIncludedOnRequestStillNeverHoldSecrets() async throws {
        try await withTempDirectory { root in
            try writeFile("index.html", in: root)
            try writeFile(".visible", in: root)
            for secret in [
                ".GIT/config", ".Aws/credentials", ".gnupg/pubring.kbx", ".KUBE/config", ".docker/config.json",
                ".azure/profile", "Node_Modules/x.js", ".NPMRC", ".netrc", ".envrc", ".pgpass", ".git-credentials",
                "deploy/id_ecdsa", "keys/a.PFX", ".ssh/known_hosts", "cfg/credentials.json", "infra/prod.tfvars",
            ] {
                try writeFile(secret, in: root)
            }
            let entries = try FolderZipper.previewEntries(folder: root, includeHidden: true)
            #expect(entries == [".visible", "index.html"])
        }
    }
}

// MARK: - Limits

@Suite("Folder limits")
struct FolderLimitTests {
    private func makeFiles(_ count: Int, in root: URL, prefix: String = "f") throws {
        for number in 0..<count {
            FileManager.default.createFile(atPath: root.appendingPathComponent("\(prefix)\(number).txt").path, contents: Data("x".utf8))
        }
    }

    @Test func aFolderOfMoreThanTenThousandFilesIsRefused() async throws {
        try await withTempDirectory { root in
            try makeFiles(FolderLimits.maxFiles, in: root)
            #expect(try FolderZipper.previewEntries(folder: root).count == FolderLimits.maxFiles)
            try makeFiles(1, in: root, prefix: "extra")
            let error = await thrownUptfError { try FolderZipper.previewEntries(folder: root) }
            #expect(error?.localizedDescription.contains("more than \(FolderLimits.maxFiles.formatted()) files") == true)
            #expect(error?.localizedDescription.contains("Choose a smaller folder") == true)
        }
    }

    @Test func aFolderOverFiveHundredMegabytesIsRefusedWithoutReadingTheRest() async throws {
        try await withTempDirectory { root in
            try makeSparseFile(at: root.appendingPathComponent("a.bin"), bytes: megabytes(300))
            try makeSparseFile(at: root.appendingPathComponent("b.bin"), bytes: megabytes(300))
            let error = await thrownUptfError { try FolderZipper.previewEntries(folder: root) }
            #expect(error?.localizedDescription.contains("500 MB") == true)
        }
    }

    @Test func aFolderBelowTheLimitsIsListedWhole() async throws {
        try await withTempDirectory { root in
            try makeSparseFile(at: root.appendingPathComponent("big.bin"), bytes: megabytes(100))
            try makeFiles(600, in: root)
            #expect(try FolderZipper.previewEntries(folder: root).count == 601)
        }
    }

    @Test func aWebsiteFolderUsesTheWebsiteFileCount() async throws {
        try await withTempDirectory { root in
            try writeFile("index.html", in: root)
            try makeFiles(FolderLimits.websiteMaxFiles - 1, in: root)
            #expect(try FolderZipper.previewEntries(folder: root).count == FolderLimits.websiteMaxFiles)
            try makeFiles(1, in: root, prefix: "extra")
            let error = await thrownUptfError { try FolderZipper.previewEntries(folder: root) }
            #expect(error?.localizedDescription.contains("up to \(FolderLimits.websiteMaxFiles.formatted()) files") == true)
            #expect(error?.localizedDescription.contains("opens as a website") == true)
        }
    }

    @Test func aWebsiteFolderUsesTheWebsiteFileSize() async throws {
        try await withTempDirectory { root in
            try writeFile("index.html", in: root)
            try makeSparseFile(at: root.appendingPathComponent("movie.mp4"), bytes: megabytes(21))
            let error = await thrownUptfError { try FolderZipper.previewEntries(folder: root) }
            #expect(error?.localizedDescription.contains("movie.mp4") == true)
            #expect(error?.localizedDescription.contains("20 MB") == true)
        }
    }

    @Test func aWebsiteFolderUsesTheWebsiteTotalSize() async throws {
        try await withTempDirectory { root in
            try writeFile("index.html", in: root)
            for name in ["a.bin", "b.bin", "c.bin"] {
                try makeSparseFile(at: root.appendingPathComponent(name), bytes: megabytes(15))
            }
            let error = await thrownUptfError { try FolderZipper.previewEntries(folder: root) }
            #expect(error?.localizedDescription.contains("40 MB") == true)
        }
    }

    @Test func theSameBigFilesAreFineWithoutAnIndexPage() async throws {
        try await withTempDirectory { root in
            for name in ["a.bin", "b.bin", "c.bin"] {
                try makeSparseFile(at: root.appendingPathComponent(name), bytes: megabytes(15))
            }
            #expect(try FolderZipper.previewEntries(folder: root).count == 3)
        }
    }

    @Test func aFolderAboveTheUploadLimitIsRefusedBeforeZipping() async throws {
        try await withTempDirectory { root in
            try makeSparseFile(at: root.appendingPathComponent("big.bin"), bytes: megabytes(60))
            let error = await thrownUptfError { try await FolderZipper.zip(folder: root, entries: ["big.bin"]) }
            #expect(error?.localizedDescription.contains("50 MB") == true)
            #expect(error?.localizedDescription.contains("Choose a smaller folder") == true)
        }
    }

    @Test func aPathTooLongForZipIsRefusedNotSilentlyDropped() async throws {
        try await withTempDirectory { root in
            try writeFile("short.txt", in: root)
            try writeFile("a-name-that-is-longer-than-the-limit-given.txt", in: root)
            let error = await thrownUptfError { try FolderZipper.previewEntries(folder: root, includeHidden: false, maxPathBytes: 20) }
            #expect(error?.localizedDescription.contains("too long") == true)
            #expect(try FolderZipper.previewEntries(folder: root).count == 2)
        }
    }
}

// MARK: - Single files

@Suite("Single files")
struct SingleFileTests {
    private func makePublisher(in root: URL) -> Publisher {
        packagingPublisher(index: root.appendingPathComponent("index.json"), transport: UploadCapturingTransport())
    }

    @Test func aLinkToAHugeFileIsSizedAsTheFile() async throws {
        try await withTempDirectory { root in
            let target = root.appendingPathComponent("outside/huge.bin")
            try makeSparseFile(at: target, bytes: megabytes(60))
            let link = root.appendingPathComponent("small.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let error = await thrownUptfError { try makePublisher(in: root).prepare(link, home: root.appendingPathComponent("home")) }
            guard case .tooLarge(let bytes)? = error else {
                Issue.record("expected tooLarge, got \(String(describing: error))")
                return
            }
            #expect(bytes == megabytes(60))
        }
    }

    @Test func aLinkToAFileReportsTheFilesSize() async throws {
        try await withTempDirectory { root in
            let target = try writeFile("outside/real.txt", in: root, contents: "12345")
            let link = root.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let plan = try makePublisher(in: root).prepare(link, home: root.appendingPathComponent("home"))
            #expect(plan.kind == .file)
            #expect(plan.fileSize == 5)
        }
    }

    @Test func aNamedPipeIsRefused() async throws {
        try await withTempDirectory { root in
            let pipe = root.appendingPathComponent("pipe")
            #expect(mkfifo(pipe.path, 0o600) == 0)
            let link = root.appendingPathComponent("link-to-pipe")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pipe)
            for url in [pipe, link] {
                let error = await thrownUptfError { try makePublisher(in: root).prepare(url, home: root.appendingPathComponent("home")) }
                #expect(error?.localizedDescription.contains("isn't a file or folder") == true, "\(url.lastPathComponent)")
            }
        }
    }

    @Test func aDeviceIsRefused() async throws {
        let error = await thrownUptfError {
            try Publisher(
                client: UptfClient(config: testConfig, store: InMemoryTokenStore()),
                index: PublishedIndex(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json"), origin: testConfig.origin)
            ).prepare(URL(fileURLWithPath: "/dev/zero"), allowSensitive: true)
        }
        #expect(error?.localizedDescription.contains("isn't a file or folder") == true)
    }

    @Test func aMissingPathIsStillReported() async throws {
        try await withTempDirectory { root in
            let error = await thrownUptfError { try makePublisher(in: root).prepare(root.appendingPathComponent("nope")) }
            #expect(error?.localizedDescription.contains("No such file or folder") == true)
        }
    }

    @Test func aLinkToAFolderIsListedAsThatFolder() async throws {
        try await withTempDirectory { root in
            try writeFile("real/index.html", in: root)
            let link = root.appendingPathComponent("site")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
            let plan = try makePublisher(in: root).prepare(link, home: root.appendingPathComponent("home"))
            #expect(plan.kind == .folder)
            #expect(plan.entries == ["index.html"])
        }
    }
}

// MARK: - Zipping the approved list

@Suite("Zipping the approved list")
struct ApprovedListTests {
    @Test func onlyTheGivenEntriesAreZipped() async throws {
        try await withTempDirectory { root in
            try writeFile("a.txt", in: root, contents: "a")
            try writeFile("b.txt", in: root, contents: "b")
            let output = try await FolderZipper.zip(folder: root, entries: ["a.txt"])
            defer { try? FileManager.default.removeItem(at: output.url.deletingLastPathComponent()) }
            #expect(output.entries == ["a.txt"])
            let extracted = try extract(output.url, into: root.appendingPathComponent("out"))
            #expect(extracted == ["a.txt": "a"])
        }
    }

    @Test func publishingSendsTheApprovedFilesNotANewListing() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("approved-one.txt", in: site)
            let transport = UploadCapturingTransport()
            let publisher = packagingPublisher(index: root.appendingPathComponent("index.json"), transport: transport)
            let plan = try publisher.prepare(site, home: root.appendingPathComponent("home"))
            // Arrives after the person looked at the list.
            try writeFile("late-arrival.txt", in: site)

            _ = try await publisher.publish(plan)
            let sent = try #require(transport.bodies.first)
            #expect(sent.range(of: Data("approved-one.txt".utf8)) != nil)
            #expect(sent.range(of: Data("late-arrival.txt".utf8)) == nil)
        }
    }

    @Test func aFileSwappedForALinkAfterApprovalIsNotSent() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("page.html", in: site)
            try writeFile("other.txt", in: site)
            let outside = try writeFile("private/notes.txt", in: root, contents: "private")
            let transport = UploadCapturingTransport()
            let publisher = packagingPublisher(index: root.appendingPathComponent("index.json"), transport: transport)
            let plan = try publisher.prepare(site, home: root.appendingPathComponent("home"))

            try FileManager.default.removeItem(at: site.appendingPathComponent("page.html"))
            try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("page.html"), withDestinationURL: outside)

            let error = await thrownUptfError { try await publisher.publish(plan) }
            #expect(error?.localizedDescription.contains("changed while the folder was being prepared") == true)
            #expect(transport.requests.isEmpty, "nothing is uploaded")
        }
    }

    @Test func entriesThatAreNoLongerRegularFilesInsideTheFolderAreSkipped() async throws {
        try await withTempDirectory { root in
            let site = root.appendingPathComponent("site")
            try writeFile("keep.txt", in: site, contents: "keep")
            try writeFile("swapped.txt", in: site)
            try writeFile("gone.txt", in: site)
            let outside = try writeFile("outside/secret.txt", in: root, contents: "secret")
            try FileManager.default.removeItem(at: site.appendingPathComponent("swapped.txt"))
            try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("swapped.txt"), withDestinationURL: outside)
            try FileManager.default.removeItem(at: site.appendingPathComponent("gone.txt"))
            // A folder replaced by a link to somewhere else.
            try writeFile("dir/inner.txt", in: root.appendingPathComponent("elsewhere"))
            try FileManager.default.createSymbolicLink(
                at: site.appendingPathComponent("dir"), withDestinationURL: root.appendingPathComponent("elsewhere/dir"))

            let output = try await FolderZipper.zip(
                folder: site, entries: ["keep.txt", "swapped.txt", "gone.txt", "dir/inner.txt", "../outside/secret.txt", "/etc/hosts"])
            defer { try? FileManager.default.removeItem(at: output.url.deletingLastPathComponent()) }
            #expect(output.entries == ["keep.txt"])
            #expect(Set(output.skipped) == ["swapped.txt", "gone.txt", "dir/inner.txt", "../outside/secret.txt", "/etc/hosts"])
            #expect(try extract(output.url, into: root.appendingPathComponent("out")) == ["keep.txt": "keep"])
        }
    }

    @Test func zippingNothingThatCheckedOutIsAnError() async throws {
        try await withTempDirectory { root in
            let error = await thrownUptfError { try await FolderZipper.zip(folder: root, entries: ["missing.txt"]) }
            #expect(error?.localizedDescription.contains("nothing to put online") == true)
        }
    }
}

// MARK: - Running zip

@Suite("Running zip")
struct ZipProcessTests {
    @Test func oddFileNamesAreStoredAsThemselves() async throws {
        try await withTempDirectory { root in
            let names = ["-", "-rf", " a", "a b", "*.txt", "[x].txt", "-q", "--", "é.txt", "real.txt"]
            for name in names { try writeFile(name, in: root, contents: "content of \(name)") }
            let entries = try FolderZipper.previewEntries(folder: root)
            #expect(Set(entries) == Set(names))

            let output = try await FolderZipper.zip(folder: root, entries: entries)
            defer { try? FileManager.default.removeItem(at: output.url.deletingLastPathComponent()) }
            let extracted = try extract(output.url, into: root.appendingPathComponent("out", isDirectory: true))
            #expect(extracted == Dictionary(uniqueKeysWithValues: names.map { ($0, "content of \($0)") }))
        }
    }

    @Test func aLongFolderNameStillGivesAWritableArchive() async throws {
        #expect(FolderZipper.archiveName(for: String(repeating: "a", count: 255)).utf8.count <= 255)
        #expect(FolderZipper.archiveName(for: String(repeating: "é", count: 200)).utf8.count <= 255)
        #expect(FolderZipper.archiveName(for: "photos") == "photos.zip")
        #expect(FolderZipper.archiveName(for: "") == "site.zip")
        try await withTempDirectory { root in
            let folder = root.appendingPathComponent(String(repeating: "n", count: 252), isDirectory: true)
            try writeFile("a.txt", in: folder)
            let output = try await FolderZipper.zip(folder: folder, entries: ["a.txt"])
            defer { try? FileManager.default.removeItem(at: output.url.deletingLastPathComponent()) }
            #expect(output.bytes > 0)
        }
    }

    private func quietInput(in root: URL) throws -> URL {
        try writeFile("empty-input", in: root, contents: "")
    }

    @Test func aLotOfErrorOutputDoesNotStopTheProcess() async throws {
        try await withTempDirectory { root in
            let result = try await FolderZipper.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 400000 /dev/zero | tr '\\0' x >&2"],
                directory: root, input: try quietInput(in: root), errorFile: root.appendingPathComponent("errors.txt"), timeout: 30)
            #expect(result.status == 0)
            #expect(result.errorText.utf8.count == 4000)
        }
    }

    @Test func aProcessThatRunsTooLongIsStopped() async throws {
        try await withTempDirectory { root in
            let started = Date()
            let error = await thrownUptfError {
                try await FolderZipper.run(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                    directory: root, input: try quietInput(in: root), errorFile: root.appendingPathComponent("errors.txt"), timeout: 0.5)
            }
            #expect(error?.localizedDescription.contains("took too long") == true)
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }

    @Test func cancellingTheTaskStopsTheProcess() async throws {
        try await withTempDirectory { root in
            let input = try quietInput(in: root)
            let errors = root.appendingPathComponent("errors.txt")
            let started = Date()
            let task = Task {
                try await FolderZipper.run(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                    directory: root, input: input, errorFile: errors, timeout: 60)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            task.cancel()
            let result = await task.result
            guard case .failure(let error) = result else {
                Issue.record("expected the cancelled run to fail")
                return
            }
            #expect(error is CancellationError)
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }

    @Test func zipOptionsFromTheEnvironmentAreIgnored() async throws {
        // zip reads extra options from ZIPOPT; a stray value must not change what is packed.
        setenv("ZIPOPT", "-x a.txt", 1)
        defer { unsetenv("ZIPOPT") }
        try await withTempDirectory { root in
            try writeFile("a.txt", in: root, contents: "a")
            let output = try await FolderZipper.zip(folder: root, entries: ["a.txt"])
            defer { try? FileManager.default.removeItem(at: output.url.deletingLastPathComponent()) }
            #expect(try extract(output.url, into: root.appendingPathComponent("out")) == ["a.txt": "a"])
        }
    }
}

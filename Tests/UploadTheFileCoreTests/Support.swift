import Foundation
import UptfKit

@testable import UploadTheFileCore

/// Runs `body` with a fresh empty directory (symlinks resolved, so paths compare equal).
func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("utf-core-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory.resolvingSymlinksInPath())
}

@discardableResult
func writeFile(_ relativePath: String, in root: URL, contents: String = "x") throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

/// A page as the server describes it.
func makePage(
    id: String = "page-1", name: String? = "my-page", kind: String = "pdf", size: Int64 = 1_500_000,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    passwordProtected: Bool? = nil, emailGateEnabled: Bool? = nil, displayMode: DisplayMode? = nil,
    displayModeApplies: Bool? = nil
) -> PageInfo {
    PageInfo(
        id: id, name: name, url: "https://\(name ?? id).example.test", fileName: "file.\(kind)", kind: kind,
        sizeBytes: size, fileCount: 1, createdAt: createdAt, expiresAt: nil, chatEnabled: false,
        passwordProtected: passwordProtected, emailGateEnabled: emailGateEnabled, displayMode: displayMode,
        displayModeApplies: displayModeApplies)
}

/// A publish-history entry (decoded from JSON, since its initializer is not public).
func makeEntry(
    id: String = "page-1", path: String = "/tmp/report.pdf", url: String = "https://my-page.example.test",
    hostedAsSite: Bool = false
) throws -> PublishedEntry {
    let json = """
        {"id":"\(id)","origin":"https://example.test","name":"my-page","url":"\(url)","kind":"file",
         "hostedAsSite":\(hostedAsSite),"lastKnownPath":"\(path)","sha256":"abc","publishedAt":"2026-01-01T00:00:00Z"}
        """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PublishedEntry.self, from: Data(json.utf8))
}

/// A real plan for `url`, from the library's own rules.
func makePlan(for url: URL, home: URL) throws -> PublishPlan {
    let client = UptfClient(config: try UptfConfig(origin: "https://example.test"), store: InMemoryTokenStore())
    let index = PublishedIndex(fileURL: home.appendingPathComponent("unused-index.json"), origin: "https://example.test")
    return try Publisher(client: client, index: index).prepare(url, allowSensitive: true)
}

/// An assessor wired to the real `FolderZipper`/size rules (through `Publisher.prepare`) but with
/// a fake lookup, so nothing touches the network.
func makeAssessor(
    home: URL, existing: @escaping @Sendable (URL) async throws -> ExistingPublication? = { _ in nil }
) -> PublishAssessor {
    let client = UptfClient(config: try! UptfConfig(origin: "https://example.test"), store: InMemoryTokenStore())
    let index = PublishedIndex(fileURL: home.appendingPathComponent("unused-index.json"), origin: "https://example.test")
    let publisher = Publisher(client: client, index: index)
    return PublishAssessor(
        prepare: { url, allow in try publisher.prepare(url, allowSensitive: allow) },
        lookup: { url, _ in try await existing(url) }, home: home)
}

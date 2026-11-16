import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import UptfKit

/// A transport that answers from a closure and remembers each request line and body.
private final class RecordingTransport: ClientTransport, @unchecked Sendable {
    struct Seen {
        var line: String
        var body: String
    }

    private let lock = NSLock()
    private var recorded: [Seen] = []
    private let handler: @Sendable (_ method: String, _ path: String) -> FakeReply

    init(_ handler: @escaping @Sendable (_ method: String, _ path: String) -> FakeReply) {
        self.handler = handler
    }

    var requests: [String] { lock.withLock { recorded.map(\.line) } }

    /// The body of the one request with this line, as text.
    func body(of line: String) -> String? { lock.withLock { recorded.first { $0.line == line }?.body } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        let data = try await BodyBuffer.collect(body, upTo: 1 << 20) ?? Data()
        lock.withLock {
            recorded.append(Seen(line: "\(request.method.rawValue) \(path)", body: String(decoding: data, as: UTF8.self)))
        }
        let reply = handler(request.method.rawValue, path)
        var response = HTTPResponse(status: .init(code: reply.status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(reply.body))
    }
}

private func makeRecordingClient(_ transport: RecordingTransport) -> UptfClient {
    let store = InMemoryTokenStore([
        testConfig.origin: StoredCredentials(
            accessToken: "test-access", refreshToken: "test-refresh",
            expiresAt: Date().addingTimeInterval(3600), clientId: "test-client")
    ])
    let tokens = TokenManager(origin: testConfig.origin, store: store, refresher: NoRefresh())
    return UptfClient(config: testConfig, tokens: tokens, transport: transport)
}

/// The value of a text field in a multipart body.
private func formValue(_ field: String, in body: String) -> String? {
    guard let header = body.range(of: "name=\"\(field)\"") else { return nil }
    guard let start = body.range(of: "\r\n\r\n", range: header.upperBound..<body.endIndex) else { return nil }
    let rest = body[start.upperBound...]
    guard let end = rest.range(of: "\r\n--") else { return nil }
    return String(rest[..<end.lowerBound])
}

private func uploadReply(id: String?, slug: String, url: String) -> String {
    let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
    return #"{"success":true,"data":{\#(idField)"url":"\#(url)","slug":"\#(slug)","hasHtml":false}}"#
}

@Suite("Publisher")
struct PublisherTests {
    private func makePublisher(_ client: UptfClient, in directory: URL) -> (Publisher, PublishedIndex) {
        let index = PublishedIndex(fileURL: directory.appendingPathComponent("i.json"), origin: testConfig.origin)
        return (Publisher(client: client, index: index), index)
    }

    // MARK: A page that is not in the list

    @Test func aPageMissingFromTheListIsAskedForByIdAndItsEntryStays() async throws {
        try await withTempDirectory { directory in
            // A list that does not hold the page: another account's, or one that was cut short.
            let transport = RecordingTransport { method, path in
                if path.hasPrefix("/pages?") { return .json(listJSON([])) }
                if path == "/pages/p1" { return .json(pageEnvelopeJSON(pageJSON(id: "p1", name: "renamed"))) }
                return .error(404, "nope")
            }
            let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("a.pdf", in: directory)
            let entry = try await index.record(fileURL: file, id: "p1", name: "one", url: "https://one.upload.tf", kind: .file)

            let page = try await publisher.livePage(for: entry)

            #expect(page?.id == "p1")
            #expect(transport.requests == ["GET /pages?limit=1000", "GET /pages/p1"])
            let stored = try #require(try await index.entry(forID: "p1"))
            #expect(stored.name == "renamed")
            #expect(stored.lastKnownPath == file.path)
        }
    }

    @Test func aPageNotInThisAccountIsReportedMissingAndItsEntryStays() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { _, path in
                path.hasPrefix("/pages?") ? .json(listJSON([])) : .error(404, "Page not found")
            }
            let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("a.pdf", in: directory)
            let entry = try await index.record(fileURL: file, id: "p1", name: "one", url: "https://one.upload.tf", kind: .file)

            #expect(try await publisher.livePage(for: entry) == nil)
            #expect(try await index.entries().map(\.id) == ["p1"])
        }
    }

    @Test func aFailedReadNeverDropsAnEntry() async throws {
        try await withTempDirectory { directory in
            let listFails = RecordingTransport { _, _ in .error(500, "Something went wrong") }
            let byIDFails = RecordingTransport { _, path in
                path.hasPrefix("/pages?") ? .json(listJSON([])) : .error(500, "Something went wrong")
            }
            let file = try writeFile("a.pdf", in: directory)
            for transport in [listFails, byIDFails] {
                let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)
                let entry = try await index.record(fileURL: file, id: "p1", name: "one", url: "https://one.upload.tf", kind: .file)

                let error = await thrownUptfError { try await publisher.livePage(for: entry) }

                #expect(error?.statusCode == 500)
                #expect(try await index.entries().map(\.id) == ["p1"])
            }
        }
    }

    // MARK: Replace targets the entry that was meant

    @Test func replaceTargetsTheEntryNotWhicheverEntryOwnsThePath() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { method, path in
                switch (method, path) {
                case ("GET", let p) where p.hasPrefix("/pages?"):
                    return .json(listJSON([pageJSON(id: "p1", name: "one"), pageJSON(id: "p2", name: "two")]))
                case ("PUT", "/upload"):
                    return .json(uploadReply(id: "p1", slug: "one", url: "https://one.upload.tf"))
                default: return .error(404, "nope")
                }
            }
            let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)

            // p1 came from A.pdf, p2 from B.pdf. Then B.pdf was deleted and A.pdf renamed to B.pdf:
            // p2's entry records the path B.pdf, and p1's bookmark now leads to B.pdf as well.
            let a = try writeFile("A.pdf", in: directory, contents: "from A")
            let b = try writeFile("B.pdf", in: directory, contents: "from B")
            let one = try await index.record(fileURL: a, id: "p1", name: "one", url: "https://one.upload.tf", kind: .file)
            _ = try await index.record(fileURL: b, id: "p2", name: "two", url: "https://two.upload.tf", kind: .file)
            try FileManager.default.removeItem(at: b)
            try FileManager.default.moveItem(at: a, to: b)

            // The path alone leads to the wrong page...
            #expect(try await index.entry(for: b)?.id == "p2")
            // ...while the row's entry still finds its own file and its own page.
            #expect(await index.currentURL(for: one).map { $0.resolvingSymlinksInPath().path } == b.path)
            let found = try #require(try await publisher.existingPublication(for: one))
            #expect(found.entry.id == "p1")
            #expect(found.page.id == "p1")

            let plan = try publisher.prepare(b)
            let outcome = try await publisher.update(plan, entry: one)

            let upload = try #require(transport.body(of: "PUT /upload"))
            #expect(formValue("id", in: upload) == "p1")
            #expect(outcome.entry?.id == "p1")
            #expect(try await index.entry(forID: "p1")?.lastKnownPath == b.path)
        }
    }

    @Test func replaceSendsThePageIdAndTheName() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { method, path in
                switch (method, path) {
                case ("GET", let p) where p.hasPrefix("/pages?"):
                    return .json(listJSON([pageJSON(id: "p1", name: "one")]))
                case ("PUT", "/upload"):
                    return .json(uploadReply(id: "p1", slug: "one", url: "https://one.upload.tf"))
                default: return .error(404, "nope")
                }
            }
            let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("named.pdf", in: directory)
            let entry = try await index.record(fileURL: file, id: "p1", name: "one", url: "https://one.upload.tf", kind: .file)

            _ = try await publisher.update(try publisher.prepare(file), entry: entry)

            let upload = try #require(transport.body(of: "PUT /upload"))
            #expect(formValue("id", in: upload) == "p1")
            #expect(formValue("name", in: upload) == "one")
        }
    }

    @Test func replaceOfAnUnnamedPageSendsItsIdInTheIdField() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { method, path in
                switch (method, path) {
                case ("GET", let p) where p.hasPrefix("/pages?"):
                    return .json(listJSON([pageJSON(id: "p2", name: nil, kind: "pdf")]))
                case ("PUT", "/upload"):
                    return .json(uploadReply(id: "p2", slug: "p2", url: "https://p2.upload.tf"))
                default: return .error(404, "nope")
                }
            }
            let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("unnamed.pdf", in: directory)
            let entry = try await index.record(fileURL: file, id: "p2", name: nil, url: "https://p2.upload.tf", kind: .file)

            _ = try await publisher.update(try publisher.prepare(file), entry: entry)

            let upload = try #require(transport.body(of: "PUT /upload"))
            #expect(formValue("id", in: upload) == "p2")
        }
    }

    // MARK: A publish costs no extra read

    @Test func aPublishUsesTheIdFromTheUploadAnswer() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { method, path in
                (method, path) == ("POST", "/upload")
                    ? .json(uploadReply(id: "p9", slug: "fresh", url: "https://fresh.upload.tf"), status: 201)
                    : .error(404, "nope")
            }
            let (publisher, index) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("note.html", in: directory)

            let outcome = try await publisher.publish(try publisher.prepare(file))

            #expect(transport.requests == ["POST /upload"])
            #expect(outcome.entry?.id == "p9")
            #expect(outcome.entry?.name == "fresh")
            #expect(outcome.entry?.url == "https://fresh.upload.tf")
            #expect(try await index.entry(forID: "p9")?.lastKnownPath == file.path)
        }
    }

    @Test func aPageWithoutANameIsRecordedWithoutOne() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { _, _ in
                .json(uploadReply(id: "a1b2c3d4", slug: "a1b2c3d4", url: "https://a1b2c3d4.upload.tf"), status: 201)
            }
            let (publisher, _) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("note.html", in: directory)

            let outcome = try await publisher.publish(try publisher.prepare(file))

            #expect(outcome.entry?.id == "a1b2c3d4")
            #expect(outcome.entry?.name == nil)
        }
    }

    @Test func aServerWithoutAnIdInTheAnswerCostsOneRead() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { method, path in
                switch (method, path) {
                case ("POST", "/upload"):
                    return .json(uploadReply(id: nil, slug: "fresh", url: "https://fresh.upload.tf"), status: 201)
                case ("GET", "/pages/fresh"):
                    return .json(pageEnvelopeJSON(pageJSON(id: "p9", name: "fresh")))
                default: return .error(404, "nope")
                }
            }
            let (publisher, _) = makePublisher(makeRecordingClient(transport), in: directory)
            let file = try writeFile("note.html", in: directory)

            let outcome = try await publisher.publish(try publisher.prepare(file))

            #expect(transport.requests == ["POST /upload", "GET /pages/fresh"])
            #expect(outcome.entry?.id == "p9")
        }
    }

    @Test func droppingThreeFilesCostsThreeUploadsAndOneListRead() async throws {
        try await withTempDirectory { directory in
            let transport = RecordingTransport { method, path in
                switch (method, path) {
                case ("POST", "/upload"):
                    return .json(uploadReply(id: "p\(Int.random(in: 100...999))", slug: "x", url: "https://x.upload.tf"), status: 201)
                case ("GET", let p) where p.hasPrefix("/pages?"):
                    return .json(listJSON([]))
                default: return .error(404, "nope")
                }
            }
            let client = makeRecordingClient(transport)
            let (publisher, _) = makePublisher(client, in: directory)

            for name in ["a.html", "b.html", "c.html"] {
                let file = try writeFile(name, in: directory)
                _ = try await publisher.publish(try publisher.prepare(file))
            }
            // The list the app reloads once the drop is done.
            _ = try await client.pages()

            #expect(transport.requests == ["POST /upload", "POST /upload", "POST /upload", "GET /pages?limit=1000"])
        }
    }
}

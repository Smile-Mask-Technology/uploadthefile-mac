import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import UptfKit

/// Runs `body` with a fresh empty directory and removes it afterwards.
func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("uptf-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Resolve /var -> /private/var so paths compare equal to what the code under test records.
    return try await body(directory.resolvingSymlinksInPath())
}

/// Writes a file (creating parent folders) and returns its URL.
@discardableResult
func writeFile(_ relativePath: String, in root: URL, contents: String = "x") throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

/// The error an operation throws, if it throws a ``UptfError``.
func thrownUptfError<T>(_ operation: () async throws -> T) async -> UptfError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as UptfError {
        return error
    } catch {
        return .unexpected("not an UptfError: \(error)")
    }
}

// MARK: - Fake network

struct FakeReply: Sendable {
    var status: Int
    var body: String
    var headers: [String: String] = [:]

    static func json(_ body: String, status: Int = 200) -> FakeReply {
        FakeReply(status: status, body: body)
    }

    static func error(_ status: Int, _ message: String, retryAfter: String? = nil) -> FakeReply {
        FakeReply(
            status: status, body: #"{"success":false,"error":"\#(message)"}"#,
            headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    }
}

/// A transport that answers from a closure and remembers every request it saw.
final class FakeTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private let handler: @Sendable (_ method: String, _ path: String) -> FakeReply

    init(_ handler: @escaping @Sendable (_ method: String, _ path: String) -> FakeReply) {
        self.handler = handler
    }

    /// `"GET /pages?limit=1000"` for every request, in order.
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    private func record(_ line: String) {
        lock.withLock { seen.append(line) }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        record("\(request.method.rawValue) \(path)")

        let reply = handler(request.method.rawValue, path)
        var response = HTTPResponse(status: .init(code: reply.status))
        response.headerFields[.contentType] = "application/json"
        for (name, value) in reply.headers {
            response.headerFields[HTTPField.Name(name)!] = value
        }
        return (response, HTTPBody(reply.body))
    }
}

struct NoRefresh: TokenRefresher {
    func refresh(refreshToken: String, clientId: String) async throws -> OAuthTokens {
        throw UptfError.unexpected("The tests must not refresh tokens.")
    }
}

let testConfig = try! UptfConfig(origin: "https://uploadthefile.test")

/// A client whose requests go to `transport` with a valid, far-from-expiry token.
func makeClient(_ transport: FakeTransport) -> UptfClient {
    let store = InMemoryTokenStore([
        testConfig.origin: StoredCredentials(
            accessToken: "test-access", refreshToken: "test-refresh",
            expiresAt: Date().addingTimeInterval(3600), clientId: "test-client")
    ])
    let tokens = TokenManager(
        origin: testConfig.origin, store: store, refresher: NoRefresh(), lockFileURL: { nil })
    return UptfClient(config: testConfig, tokens: tokens, transport: transport)
}

func pageJSON(id: String, name: String?, kind: String = "site") -> String {
    let nameJSON = name.map { "\"\($0)\"" } ?? "null"
    return """
        {"id":"\(id)","name":\(nameJSON),"url":"https://\(name ?? id).upload.tf","fileName":"index.html",\
        "kind":"\(kind)","sizeBytes":100,"fileCount":2,"createdAt":"2026-01-02T03:04:05Z",\
        "expiresAt":null,"chatEnabled":false}
        """
}

func listJSON(_ pages: [String]) -> String {
    #"{"success":true,"data":{"pages":[\#(pages.joined(separator: ","))],"limit":1000}}"#
}

func pageEnvelopeJSON(_ page: String) -> String {
    #"{"success":true,"data":{"page":\#(page)}}"#
}

func makePage(id: String, name: String?, url: String? = nil) -> PageInfo {
    PageInfo(
        id: id, name: name, url: url ?? "https://\(name ?? id).upload.tf", fileName: "index.html", kind: "site",
        sizeBytes: 100, fileCount: 2, createdAt: Date(timeIntervalSince1970: 1_767_000_000), expiresAt: nil,
        chatEnabled: false)
}

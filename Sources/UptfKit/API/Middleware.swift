import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Reads a whole request/response body into memory (bounded).
enum BodyBuffer {
    static func collect(_ body: HTTPBody?, upTo limit: Int) async throws -> Data? {
        guard let body else { return nil }
        return Data(try await ArraySlice<UInt8>(collecting: body, upTo: limit))
    }
}

/// Adds `Authorization: Bearer`, refreshes the token shortly before it expires, and retries
/// once after a 401 with a freshly refreshed token. Refreshes are serialised by ``TokenManager``.
struct AuthMiddleware: ClientMiddleware {
    /// Upload bodies are buffered so a request can be replayed after a refresh.
    static let maxBufferedRequestBytes = 64 * 1024 * 1024

    let tokens: TokenManager

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let payload = try await BodyBuffer.collect(body, upTo: Self.maxBufferedRequestBytes)
        let token = try await tokens.accessToken()

        let (response, responseBody) = try await send(request, payload, baseURL, token, next)
        guard response.status.code == 401 else { return (response, responseBody) }

        let fresh = try await tokens.accessToken(replacing: token)
        return try await send(request, payload, baseURL, fresh, next)
    }

    private func send(
        _ request: HTTPRequest, _ payload: Data?, _ baseURL: URL, _ token: String,
        _ next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        request.headerFields[.userAgent] = "UploadTheFile-mac/\(UptfKitVersion.value)"
        return try await next(request, payload.map { HTTPBody($0) }, baseURL)
    }
}

/// Turns every non-2xx answer into a ``UptfError``, using the envelope's `error` string.
struct ErrorMappingMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard !(200..<300).contains(response.status.code) else { return (response, responseBody) }
        let data = (try? await BodyBuffer.collect(responseBody, upTo: 64 * 1024)) ?? nil
        let retryAfter = HTTPField.Name("Retry-After").flatMap { response.headerFields[$0] }
        throw ApiErrorMapper.map(status: response.status.code, retryAfter: retryAfter, body: data ?? Data())
    }
}

enum ApiErrorMapper {
    private struct Envelope: Decodable {
        var error: String?
    }

    /// The server's `{success:false, error:"…"}` string, if the body has one.
    static func envelopeMessage(_ body: Data) -> String? {
        guard let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error,
            !message.isEmpty
        else { return nil }
        return message
    }

    static func map(status: Int, retryAfter: String?, body: Data) -> UptfError {
        if status == 401 { return .notSignedIn }
        if status == 429 { return .rateLimited(retryAfter: RetryAfter.seconds(from: retryAfter)) }
        if status == 404 { return .server(status: 404, message: "This link isn't in your account anymore.") }
        let message = envelopeMessage(body) ?? "Something went wrong on our side. Try again in a moment."
        return .server(status: status, message: message)
    }
}

/// The generated client omits `expiresAt` when it is nil, but the API reads `null` as
/// "never expires". Make that explicit on the wire.
struct ExplicitNullExpiryMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == "setPageExpiry",
            let data = try await BodyBuffer.collect(body, upTo: 1024 * 1024)
        else {
            return try await next(request, body, baseURL)
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["expiresAt"] == nil
        else {
            return try await next(request, HTTPBody(data), baseURL)
        }
        object["expiresAt"] = NSNull()
        let rewritten = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var request = request
        request.headerFields[.contentLength] = String(rewritten.count)
        return try await next(request, HTTPBody(rewritten), baseURL)
    }
}

public import Foundation

/// Why an authorization callback was rejected.
public enum CallbackError: Error, Equatable, LocalizedError {
    /// The `state` parameter is missing or is not the one we sent.
    case stateMismatch
    /// The server (or the user) refused: `?error=access_denied` and friends.
    case denied(error: String, description: String?)
    /// Neither `code` nor `error` is present.
    case missingCode

    public var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "The sign-in answer didn't match this request."
        case .denied(let error, let description):
            if error == "access_denied" { return "Access was denied." }
            return description.map { "\(error): \($0)" } ?? error
        case .missingCode:
            return "The sign-in answer was incomplete."
        }
    }
}

/// The query of a redirect to `http://127.0.0.1:<port>/callback`.
public struct AuthorizationCallback: Sendable, Equatable {
    public var code: String?
    public var error: String?
    public var errorDescription: String?
    public var state: String?

    public static let path = "/callback"

    /// Parses a request target such as `/callback?code=abc&state=xyz`.
    /// Returns nil when the target is not the callback path.
    public static func parse(target: String) -> AuthorizationCallback? {
        guard let components = URLComponents(string: "http://127.0.0.1" + target),
            components.path == path
        else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        return AuthorizationCallback(
            code: value("code"), error: value("error"),
            errorDescription: value("error_description"), state: value("state"))
    }

    /// Checks `state` first (a response we can't tie to our request is never trusted), then
    /// surfaces an `error`, and returns the authorization code.
    public func validated(expectedState: String) throws(CallbackError) -> String {
        guard let state, Self.constantTimeEquals(state, expectedState) else { throw .stateMismatch }
        if let error, !error.isEmpty { throw .denied(error: error, description: errorDescription) }
        guard let code, !code.isEmpty else { throw .missingCode }
        return code
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for (l, r) in zip(x, y) { diff |= l ^ r }
        return diff == 0
    }
}

/// The request line of an HTTP/1.x request.
struct HTTPRequestLine: Equatable {
    var method: String
    var target: String
    var host: String?

    /// Parses the head (everything before the blank line).
    static func parse(_ head: String) -> HTTPRequestLine? {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return nil }
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        return HTTPRequestLine(method: String(first[0]), target: String(first[1]), host: host)
    }
}

public import Foundation

/// The single error type surfaced by UptfKit.
public enum UptfError: Error, LocalizedError, CustomStringConvertible {
    /// No stored credentials, or the server no longer accepts them (refresh failed, token revoked).
    case notSignedIn
    /// The server refused or failed the request. `message` is the server's own `error` string,
    /// verbatim (for example "Password protection is available on Pro and above").
    case server(status: Int, message: String)
    /// HTTP 429. Free accounts get 20 API reads and 20 writes per hour, shared by all of the
    /// account's apps. Nothing is ever retried automatically. `retryAfter` is the server's
    /// `Retry-After` in seconds, when it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// The file is bigger than the app's upload limit (see ``UptfClient/maxUploadBytes``).
    case tooLarge(bytes: Int64)
    /// The request never completed (offline, DNS, TLS, timeout, ...).
    case network(any Error)
    /// Browser sign-in failed or was cancelled.
    case signInFailed(String)
    /// Something we did not expect: bad local state, a response we could not decode, Keychain errors.
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in. Sign in with `uptf login` (or from the Upload the File app)."
        case .server(_, let message):
            return message
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Too many changes in a short time. Try again later." }
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "Too many changes in a short time. Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .tooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: UptfClient.maxUploadBytes, countStyle: .file)
            return "This is \(size), and the app can send files up to \(limit). "
                + "Use the upload.tf website for larger files."
        case .network(let underlying):
            return "Couldn't connect to Upload the File: \(underlying.localizedDescription)"
        case .signInFailed(let message):
            return "Sign-in failed: \(message)"
        case .unexpected(let message):
            return message
        }
    }

    public var description: String { errorDescription ?? "Unknown error" }

    /// HTTP status for `.server` errors, `401` for `.notSignedIn`, `429` for `.rateLimited`.
    public var statusCode: Int? {
        switch self {
        case .server(let status, _): return status
        case .notSignedIn: return 401
        case .rateLimited: return 429
        default: return nil
        }
    }
}

/// Parses a `Retry-After` header: delta-seconds or an HTTP date.
enum RetryAfter {
    static func seconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

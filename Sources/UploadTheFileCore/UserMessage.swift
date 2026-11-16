import Foundation
import UptfKit

/// How errors are put in front of the user: the library's own messages, word for word.
public enum UserMessage {
    /// The text to show. `UptfError` messages are used verbatim (a rate limit already says how many
    /// minutes to wait); anything else shows its own description, never a raw dump of the error.
    public static func text(for error: Error) -> String {
        if let uptf = error as? UptfError { return uptf.localizedDescription }
        if error is CancellationError { return "Cancelled." }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return description.isEmpty ? "Something went wrong." : description
    }

    /// Errors after which the rest of a batch would fail the same way, so it is not attempted.
    public static func stopsBatch(_ error: Error) -> Bool {
        switch error as? UptfError {
        case .rateLimited?, .notSignedIn?, .network?: return true
        default: return false
        }
    }

    /// True when the stored sign-in is no longer accepted and the window should go back to "Sign in".
    public static func requiresSignIn(_ error: Error) -> Bool {
        if case .notSignedIn? = error as? UptfError { return true }
        return false
    }

    /// True when the server refused a setting because of the plan: HTTP 403 together with a message
    /// of its own (for example "Password protection is available on Pro and above"). The message
    /// belongs under the control that was refused, shown as a calm note with a link to the plans
    /// rather than as an error. A 403 without a message says nothing about a plan, so it stays an
    /// error, like every other status and every network or validation failure.
    public static func isPlanRefusal(_ error: Error) -> Bool {
        guard case .server(let status, let message)? = error as? UptfError else { return false }
        return status == 403 && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// When the page list may be fetched again. Free accounts have 20 reads an hour, so the list is
/// loaded when the window opens only if it is older than this.
public enum RefreshPolicy {
    public static let minimumInterval: TimeInterval = 10 * 60

    public static func isStale(loadedAt: Date?, now: Date = Date()) -> Bool {
        guard let loadedAt else { return true }
        return now.timeIntervalSince(loadedAt) >= minimumInterval
    }
}

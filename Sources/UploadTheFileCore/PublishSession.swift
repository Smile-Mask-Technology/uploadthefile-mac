import Foundation
import UptfKit

/// A link the session produced or found.
public struct PublishedLink: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case published
        case updated
        /// The file was already online; its link was copied and nothing was sent.
        case existing
    }

    public var name: String
    public var url: String
    public var kind: Kind

    public init(name: String, url: String, kind: Kind) {
        self.name = name
        self.url = url
        self.kind = kind
    }
}

/// What the runner (the app model) has to do next.
public enum PublishEffect: Equatable, Sendable {
    case none
    case assess(URL, PublishIntent)
    case upload(UploadRequest)
}

/// The publish flow as a state machine. Files and folders come in (dropped, picked, or sent by
/// the Finder service), are looked at one at a time, may stop for a confirmation, and end up as
/// links or problems. Pure value type: the model feeds it events and carries out the effects.
public struct PublishSession: Equatable, Sendable {
    public enum Origin: Sendable, Equatable {
        /// Dropped on, or picked in, the menu bar window: progress shows inside it.
        case menu
        /// Sent from Finder: nothing is open, so the session gets its own window.
        case finder
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case assessing(URL)
        case confirming(PublishConfirmation)
        case uploading(name: String, isUpdate: Bool)
        case finished
    }

    public struct Problem: Equatable, Sendable {
        public var name: String
        public var message: String
    }

    public private(set) var phase: Phase = .idle
    public private(set) var origin: Origin = .menu
    public private(set) var links: [PublishedLink] = []
    public private(set) var problems: [Problem] = []
    /// Items the user said no to (or that were skipped after a failure that stops the batch).
    public private(set) var skipped = 0
    public private(set) var total = 0
    /// The item in `.assessing` has to be confirmed even when it is a plain file (it came from
    /// the Finder Service and nobody has said yes to it yet).
    public private(set) var assessmentRequiresConfirmation = false

    private var pending: [(url: URL, intent: PublishIntent, requireConfirmation: Bool)] = []

    public init() {}

    public static func == (lhs: PublishSession, rhs: PublishSession) -> Bool {
        lhs.phase == rhs.phase && lhs.origin == rhs.origin && lhs.links == rhs.links
            && lhs.problems == rhs.problems && lhs.skipped == rhs.skipped && lhs.total == rhs.total
            && lhs.assessmentRequiresConfirmation == rhs.assessmentRequiresConfirmation
            && lhs.pending.map(\.url) == rhs.pending.map(\.url)
    }

    // MARK: Reading

    public var isActive: Bool {
        switch phase {
        case .idle, .finished: return false
        default: return true
        }
    }

    public var isFinished: Bool { phase == .finished }

    /// Items are still waiting behind the one in progress, so "Stop" has something to end.
    public var canStop: Bool { isActive && !pending.isEmpty }

    /// The confirmation being asked, if any.
    public var confirmation: PublishConfirmation? {
        if case .confirming(let confirmation) = phase { return confirmation }
        return nil
    }

    /// 1-based position of the item in progress, for "2 of 5".
    public var position: Int {
        min(total, links.count + problems.count + skipped + (isActive ? 1 : 0))
    }

    /// A confirmation needs room (list of files, warnings), so it opens its own window; a session
    /// that came from Finder also shows there, because no other window is open to show progress.
    public var wantsWindow: Bool {
        guard phase != .idle else { return false }
        return confirmation != nil || origin == .finder
    }

    /// What to put on the clipboard once the session finished: the links, one per line.
    public var clipboardText: String? {
        links.isEmpty ? nil : links.map(\.url).joined(separator: "\n")
    }

    /// One sentence for the result.
    public var headline: String {
        if links.count == 1, problems.isEmpty, skipped == 0, let link = links.first {
            switch link.kind {
            case .published: return "“\(link.name)” is published. Link copied."
            case .updated: return "“\(link.name)” is updated. Link copied."
            case .existing: return "The link for “\(link.name)” is copied."
            }
        }
        if links.isEmpty {
            if problems.count == 1, let problem = problems.first { return problem.message }
            return problems.isEmpty ? "Nothing was published." : "Nothing was published: \(problems.count) failed."
        }
        var text = "\(links.count) link\(links.count == 1 ? "" : "s") copied"
        if !problems.isEmpty { text += ", \(problems.count) failed" }
        return text + "."
    }

    // MARK: Events

    /// Whether the menu bar window should be brought up when the session moves from `old` to `new`.
    /// A link made from the menu bar side (file picker, right-click menu, drop on the icon, the
    /// Replace button) must show its progress and its result there, even though the window closed
    /// itself when the file picker opened. It is shown when the work starts, when it resumes after a
    /// confirmation, and when it finishes. A session from Finder has its own window, and a
    /// confirmation has one too, so neither presents the menu bar window.
    public static func presentsMenuBar(from old: Phase, to new: Phase, origin: Origin) -> Bool {
        guard origin == .menu else { return false }
        switch (old, new) {
        case (.idle, .assessing), (.finished, .assessing): return true
        case (.confirming, .uploading): return true
        case (_, .finished): return old != .finished
        default: return false
        }
    }

    /// Adds files or folders. While a session is running they join its queue; after one finished a
    /// fresh session begins. Items from the Finder Service each need a confirmation of their own
    /// (`assessmentRequiresConfirmation`) unless `confirmed`: the user already said yes to the
    /// whole list in a batch confirmation.
    public mutating func start(
        _ urls: [URL], intent: PublishIntent = .publish, origin: Origin = .menu, confirmed: Bool = false
    ) -> PublishEffect {
        guard !urls.isEmpty else { return .none }
        let ask = origin == .finder && !confirmed
        if isActive {
            pending += urls.map { ($0, intent, ask) }
            total += urls.count
            return .none
        }
        self = PublishSession()
        self.origin = origin
        pending = urls.map { ($0, intent, ask) }
        total = urls.count
        return advance()
    }

    /// The assessor's verdict for the item in `.assessing`.
    public mutating func assessed(_ assessment: PublishAssessment) -> PublishEffect {
        guard case .assessing(let url) = phase else { return .none }
        switch assessment {
        case .refused(let message):
            problems.append(Problem(name: url.lastPathComponent, message: message))
            return advance()
        case .confirm(let confirmation):
            phase = .confirming(confirmation)
            return .none
        case .upload(let request):
            return begin(request)
        }
    }

    /// The user answered the confirmation.
    public mutating func choose(_ choice: PublishChoice) -> PublishEffect {
        guard case .confirming(let confirmation) = phase else { return .none }
        if choice == .copyExistingLink, let existing = confirmation.existing {
            links.append(PublishedLink(name: confirmation.name, url: existing.pageURL, kind: .existing))
            return advance()
        }
        guard let request = confirmation.request(for: choice) else { return .none }
        return begin(request)
    }

    /// The user said no to the item being asked about; the rest of the queue goes on.
    public mutating func decline() -> PublishEffect {
        guard case .confirming = phase else { return .none }
        skipped += 1
        return advance()
    }

    /// Stops asking: the item being asked about and everything queued is dropped.
    public mutating func cancelAll() {
        switch phase {
        case .confirming, .assessing:
            skipped += 1 + pending.count
            pending = []
            phase = .finished
        case .uploading:
            // The upload in flight cannot be taken back; only what has not started is dropped.
            skipped += pending.count
            pending = []
        case .idle, .finished:
            break
        }
    }

    /// Ends the queue after the item in progress: whatever has not started is dropped and no
    /// longer counts, the item being worked on (asked about, checked or uploading) goes on.
    public mutating func stop() {
        total -= pending.count
        pending = []
    }

    public mutating func uploaded(url: String) -> PublishEffect {
        guard case .uploading(let name, let isUpdate) = phase else { return .none }
        links.append(PublishedLink(name: name, url: url, kind: isUpdate ? .updated : .published))
        return advance()
    }

    /// The upload (or the assessment) failed. With `stopsBatch` the rest of the queue is dropped,
    /// because it would fail the same way (rate limit, signed out, offline).
    public mutating func failed(_ message: String, stopsBatch: Bool = false) -> PublishEffect {
        let name: String
        switch phase {
        case .uploading(let uploadName, _): name = uploadName
        case .assessing(let url): name = url.lastPathComponent
        default: return .none
        }
        problems.append(Problem(name: name, message: message))
        if stopsBatch {
            skipped += pending.count
            pending = []
        }
        return advance()
    }

    /// Clears a finished session ("Done").
    public mutating func dismiss() {
        if phase == .finished { self = PublishSession() }
    }

    // MARK: Private

    private mutating func begin(_ request: UploadRequest) -> PublishEffect {
        phase = .uploading(name: request.plan.url.lastPathComponent, isUpdate: request.isUpdate)
        return .upload(request)
    }

    private mutating func advance() -> PublishEffect {
        guard !pending.isEmpty else {
            phase = .finished
            assessmentRequiresConfirmation = false
            return .none
        }
        let next = pending.removeFirst()
        phase = .assessing(next.url)
        assessmentRequiresConfirmation = next.requireConfirmation
        return .assess(next.url, next.intent)
    }
}

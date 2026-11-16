import Foundation
import UptfKit

/// What reading one setting of a link gave. A setting that could not be read is not the same as a
/// setting that is off: writing the window's default back would turn a live setting off.
public enum SettingRead<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    /// The plan does not include it (HTTP 403): there is nothing to show, and a save is answered
    /// by the server with its own message.
    case notOnPlan
    /// The read failed (a server error, the link is gone ...): the sentence to show.
    case failed(String)

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    public var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// Saving is offered for what was read, and where the server has to refuse it anyway; never
    /// for what could not be read.
    public var allowsSaving: Bool { failure == nil }
}

public struct EmailGateSetting: Sendable, Equatable {
    public var enabled: Bool
    public var message: String?

    public init(enabled: Bool, message: String?) {
        self.enabled = enabled
        self.message = message
    }
}

/// The settings of one link, as far as they could be read.
public struct PageSettings: Sendable, Equatable {
    public var password: SettingRead<Bool>
    public var emailGate: SettingRead<EmailGateSetting>
    /// nil when it was not read because the link is a website, which has no such setting.
    public var display: SettingRead<DisplayMode>?
    /// False when the list said the gate is off and the gate was not read: its message is then
    /// unknown rather than empty, so a save must not overwrite it with nothing.
    public var gateMessageKnown: Bool

    public init(
        password: SettingRead<Bool>, emailGate: SettingRead<EmailGateSetting>, display: SettingRead<DisplayMode>?,
        gateMessageKnown: Bool = true
    ) {
        self.password = password
        self.emailGate = emailGate
        self.display = display
        self.gateMessageKnown = gateMessageKnown
    }
}

/// What the page list already said about a link. A nil field was not in the list (an older
/// server) and has to be read.
public struct KnownSettings: Sendable, Equatable {
    public var passwordProtected: Bool?
    public var emailGateEnabled: Bool?
    public var displayMode: DisplayMode?

    public init(passwordProtected: Bool? = nil, emailGateEnabled: Bool? = nil, displayMode: DisplayMode? = nil) {
        self.passwordProtected = passwordProtected
        self.emailGateEnabled = emailGateEnabled
        self.displayMode = displayMode
    }

    public init(page: PageInfo) {
        self.init(
            passwordProtected: page.passwordProtected, emailGateEnabled: page.emailGateEnabled,
            displayMode: page.displayMode)
    }
}

public enum SettingsReader {
    /// Whether "How it opens" exists for a page of this kind: for a single file, not a website.
    public static func supportsDisplayMode(kind: String) -> Bool { kind != "site" }

    /// Whether "How it opens" is shown for this page: a single file, and one the server says the
    /// choice applies to (an archive only downloads). An older server doesn't say: kind alone.
    public static func supportsDisplayMode(_ page: PageInfo) -> Bool {
        supportsDisplayMode(kind: page.kind) && page.displayModeApplies != false
    }

    /// The settings of a link, one read after the other (a rate limit stops the rest). What
    /// `known` already holds is used without a read; the email gate is read unless the list
    /// says it is off, because its message is only in the read. A server that says no to one of
    /// them (403, or any other error) is recorded for that setting; rate limits, sign-in problems
    /// and a network that is down throw, as for every other request.
    /// The display read is skipped when `readsDisplay` is false: a website has no such setting.
    public static func read(
        readsDisplay: Bool,
        known: KnownSettings = KnownSettings(),
        password: @Sendable () async throws -> Bool,
        emailGate: @Sendable () async throws -> EmailGateSetting,
        display: @Sendable () async throws -> DisplayMode
    ) async throws -> PageSettings {
        let passwordRead: SettingRead<Bool>
        if let protected = known.passwordProtected {
            passwordRead = .value(protected)
        } else {
            passwordRead = try await readOne(password)
        }
        let gateRead: SettingRead<EmailGateSetting>
        var gateMessageKnown = true
        if known.emailGateEnabled == false {
            gateRead = .value(EmailGateSetting(enabled: false, message: nil))
            gateMessageKnown = false
        } else {
            gateRead = try await readOne(emailGate)
        }
        var displayRead: SettingRead<DisplayMode>?
        if readsDisplay {
            if let mode = known.displayMode {
                displayRead = .value(mode)
            } else {
                displayRead = try await readOne(display)
            }
        }
        return PageSettings(
            password: passwordRead, emailGate: gateRead, display: displayRead, gateMessageKnown: gateMessageKnown)
    }

    private static func readOne<Value: Sendable & Equatable>(
        _ read: @Sendable () async throws -> Value
    ) async throws -> SettingRead<Value> {
        do {
            return .value(try await read())
        } catch UptfError.server(let status, let message) {
            if status == 403 { return .notOnPlan }
            let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason.isEmpty ? "Couldn't read this setting." : "Couldn't read this setting. \(reason)")
        }
    }
}

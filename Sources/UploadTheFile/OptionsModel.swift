import Foundation
import Observation
import UploadTheFileCore
import UptfKit

/// State of one Options window. Settings are read when the window opens (the page, then its
/// password, email and, for a single file, display setting, one after the other), never before;
/// every control saves on its own and reports under itself. A setting that could not be read is
/// shown as such and cannot be saved over.
@MainActor
@Observable
final class OptionsModel {
    enum Status: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
        /// The server said the plan does not include this (HTTP 403 with its own message). Not an
        /// error: shown as a calm note with a link to the plans.
        case refused(String)

        var failure: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
        var isWorking: Bool { self == .working }
    }

    enum Load: Equatable { case loading, loaded, failed(String), refused(String) }

    let pageID: String
    private let client: UptfClient
    private(set) var page: PageInfo
    private(set) var load: Load = .loading
    /// What reading the page's settings gave; nil until they were read (or when reading stopped
    /// early), so nothing can be saved over a value that was never seen.
    private(set) var settings: PageSettings?

    // Name
    var nameDraft: String
    private(set) var nameStatus: Status = .idle

    // Password
    private(set) var passwordProtected: Bool?
    var newPassword = ""
    var confirmPassword = ""
    private(set) var passwordStatus: Status = .idle

    // Email gate
    var gateEnabled = false
    var gateMessage = ""
    private(set) var gateStatus: Status = .idle

    // Expiry
    var neverExpires = true
    var expiryDate = Date().addingTimeInterval(7 * 24 * 3600)
    private(set) var expiryStatus: Status = .idle

    // Display
    var displayMode: DisplayMode = .preview
    /// What the server has; the picker saves when it differs.
    private(set) var savedDisplay: DisplayMode = .preview
    private(set) var displayStatus: Status = .idle

    init(page: PageInfo, client: UptfClient) {
        self.page = page
        self.client = client
        pageID = page.id
        nameDraft = page.slug
        apply(expiry: page.expiresAt)
    }

    #if DEBUG
    /// Puts the model in a given state without any request, for the off-screen snapshots.
    func applySnapshot(
        load: Load, settings: Settings? = nil, passwordStatus: Status = .idle,
        gateStatus: Status = .idle, expiryStatus: Status = .idle
    ) {
        self.load = load
        if let settings {
            passwordProtected = settings.passwordProtected
            gateEnabled = settings.gateEnabled
            gateMessage = settings.gateMessage
            if let mode = settings.displayMode {
                displayMode = mode
                savedDisplay = mode
            }
            self.settings = PageSettings(
                password: settings.passwordProtected.map { SettingRead<Bool>.value($0) } ?? .notOnPlan,
                emailGate: .value(EmailGateSetting(enabled: settings.gateEnabled, message: settings.gateMessage)),
                display: settings.displayMode.map { SettingRead<DisplayMode>.value($0) })
        }
        self.passwordStatus = passwordStatus
        self.gateStatus = gateStatus
        self.expiryStatus = expiryStatus
    }

    /// The settings the server reports for a page (`PageDetails` has no public initializer).
    struct Settings {
        var passwordProtected: Bool? = false
        var gateEnabled = false
        var gateMessage = ""
        var displayMode: DisplayMode? = .preview
    }
    #endif

    // MARK: Derived

    var passwordProblem: String? { OptionsRules.passwordProblem(newPassword, confirmation: confirmPassword) }
    var canSavePassword: Bool { OptionsRules.canSavePassword(newPassword, confirmation: confirmPassword) && !passwordStatus.isWorking }
    var nameProblem: String? { OptionsRules.nameProblem(nameDraft) }
    var canRename: Bool { OptionsRules.canRename(from: page.slug, to: nameDraft) && !nameStatus.isWorking }
    var expiryProblem: String? { OptionsRules.expiryProblem(neverExpires: neverExpires, date: expiryDate) }
    var canSaveExpiry: Bool { expiryProblem == nil && !expiryStatus.isWorking }
    /// Email: only for a setting that was read (or that the plan keeps from us and the server will
    /// answer for), so Save never writes "off" over a gate that could not be read.
    var canEditGate: Bool { settings?.emailGate.allowsSaving ?? false }
    var canSaveGate: Bool { canEditGate && !gateStatus.isWorking }
    var canChangeDisplay: Bool { settings?.display?.allowsSaving ?? false }
    /// Why a setting is not shown: the sentence to put in its place.
    var passwordReadError: String? { settings?.password.failure }
    var gateReadError: String? { settings?.emailGate.failure }
    var displayReadError: String? { settings?.display?.failure }

    // MARK: Loading

    func open() async {
        load = .loading
        settings = nil
        do {
            let fetched = try await client.page(pageID)
            page = fetched
            apply(expiry: fetched.expiresAt)
            let api = client
            let id = pageID
            let read = try await SettingsReader.read(
                readsDisplay: SettingsReader.supportsDisplayMode(kind: fetched.kind),
                password: { try await api.passwordProtected(id) },
                emailGate: {
                    let gate = try await api.emailGate(id)
                    return EmailGateSetting(enabled: gate.enabled, message: gate.message)
                },
                display: { try await api.displayMode(id) })
            settings = read
            passwordProtected = read.password.value
            if let gate = read.emailGate.value {
                gateEnabled = gate.enabled
                gateMessage = gate.message ?? ""
            }
            if let mode = read.display?.value {
                displayMode = mode
                savedDisplay = mode
            }
            load = .loaded
        } catch {
            let message = UserMessage.text(for: error)
            load = UserMessage.isPlanRefusal(error) ? .refused(message) : .failed(message)
        }
    }

    private func apply(expiry: Date?) {
        neverExpires = expiry == nil
        if let expiry { expiryDate = expiry }
    }

    // MARK: Saving

    func rename() async {
        let proposed = nameDraft.trimmingCharacters(in: .whitespaces)
        await save(\.nameStatus, saved: "Renamed. The old link stops working.") {
            let renamed = try await client.rename(pageID, to: proposed)
            page = renamed
            nameDraft = renamed.slug
            AppModel.shared.replace(renamed)
        }
    }

    func setPassword() async {
        let password = newPassword
        await save(\.passwordStatus, saved: "Password set.") {
            try await client.setPassword(password, for: pageID)
            passwordProtected = true
            newPassword = ""
            confirmPassword = ""
        }
    }

    func removePassword() async {
        await save(\.passwordStatus, saved: "Password removed.") {
            try await client.removePassword(for: pageID)
            passwordProtected = false
        }
    }

    func saveGate() async {
        guard canSaveGate else { return }
        let enabled = gateEnabled
        let message = OptionsRules.clampedGateMessage(gateMessage)
        await save(\.gateStatus, saved: enabled ? "People will be asked for their email first." : "People can open it without giving their email.") {
            try await client.setEmailGate(pageID, enabled: enabled, message: message)
        }
    }

    func saveExpiry() async {
        let date = OptionsRules.expiryToSend(neverExpires: neverExpires, date: expiryDate)
        await save(\.expiryStatus, saved: date == nil ? "Your link stays online until you delete it." : "Saved. Your link stays online until then.") {
            try await client.setExpiry(pageID, date)
            page.expiresAt = date
            AppModel.shared.replace(page)
        }
    }

    func saveDisplay() async {
        let mode = displayMode
        await save(\.displayStatus, saved: "Saved") {
            try await client.setDisplay(pageID, mode: mode)
            savedDisplay = mode
        }
    }

    /// Runs one save and reports under its control. A plan refusal (HTTP 403 with the server's own
    /// message) is a note, not an error; anything else is an error. Both show the server's text and
    /// leave the control usable.
    private func save(
        _ field: ReferenceWritableKeyPath<OptionsModel, Status>, saved: String,
        _ work: () async throws -> Void
    ) async {
        self[keyPath: field] = .working
        do {
            try await work()
            self[keyPath: field] = .done(saved)
        } catch {
            let message = UserMessage.text(for: error)
            self[keyPath: field] = UserMessage.isPlanRefusal(error) ? .refused(message) : .failed(message)
        }
    }
}

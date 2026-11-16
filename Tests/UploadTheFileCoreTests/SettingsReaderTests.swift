import Foundation
import Testing
import UptfKit

@testable import UploadTheFileCore

/// Counts the reads a test made (the closures are `@Sendable`).
private actor Reads {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

@Suite("Reading a link's settings")
struct SettingsReaderTests {
    private func read(
        readsDisplay: Bool = true, known: KnownSettings = KnownSettings(), reads: Reads = Reads(),
        password: @escaping @Sendable () async throws -> Bool = { true },
        gate: @escaping @Sendable () async throws -> EmailGateSetting = { EmailGateSetting(enabled: true, message: "Hi") },
        display: @escaping @Sendable () async throws -> DisplayMode = { .download }
    ) async throws -> PageSettings {
        try await SettingsReader.read(
            readsDisplay: readsDisplay,
            known: known,
            password: { await reads.record("password"); return try await password() },
            emailGate: { await reads.record("gate"); return try await gate() },
            display: { await reads.record("display"); return try await display() })
    }

    @Test func everythingReadIsReturned() async throws {
        let settings = try await read()
        #expect(settings.password == .value(true))
        #expect(settings.emailGate == .value(EmailGateSetting(enabled: true, message: "Hi")))
        #expect(settings.display == .value(.download))
        #expect(settings.emailGate.allowsSaving)
    }

    @Test func aGateThatCouldNotBeReadIsNotOffAndCannotBeSavedOver() async throws {
        let settings = try await read(gate: { throw UptfError.server(status: 500, message: "Something went wrong.") })
        #expect(settings.emailGate == .failed("Couldn't read this setting. Something went wrong."))
        #expect(settings.emailGate.value == nil)
        #expect(settings.emailGate.failure == "Couldn't read this setting. Something went wrong.")
        #expect(!settings.emailGate.allowsSaving)
        // The other settings are still shown.
        #expect(settings.password == .value(true))
        #expect(settings.display == .value(.download))
    }

    @Test func aMissingPageIsAFailureToo() async throws {
        let settings = try await read(password: { throw UptfError.server(status: 404, message: "") })
        #expect(settings.password == .failed("Couldn't read this setting."))
        #expect(!settings.password.allowsSaving)
    }

    @Test func aPlanThatLeavesASettingOutIsNotAnError() async throws {
        let settings = try await read(gate: { throw UptfError.server(status: 403, message: "Email capture is available on Pro and above") })
        #expect(settings.emailGate == .notOnPlan)
        #expect(settings.emailGate.failure == nil)
        #expect(settings.emailGate.allowsSaving)  // the server answers a save with its own message
    }

    @Test func aWebsiteDoesNotReadTheDisplaySetting() async throws {
        let reads = Reads()
        let settings = try await read(readsDisplay: false, reads: reads)
        #expect(settings.display == nil)
        #expect(await reads.names == ["password", "gate"])
        #expect(SettingsReader.supportsDisplayMode(kind: "pdf"))
        #expect(!SettingsReader.supportsDisplayMode(kind: "site"))
    }

    @Test func aSingleFileReadsAllThreeOneAfterTheOther() async throws {
        let reads = Reads()
        _ = try await read(reads: reads)
        #expect(await reads.names == ["password", "gate", "display"])
    }

    @Test func aRateLimitStopsTheRestAndThrows() async throws {
        let reads = Reads()
        await #expect(throws: UptfError.self) {
            _ = try await read(reads: reads, gate: { throw UptfError.rateLimited(retryAfter: 60) })
        }
        #expect(await reads.names == ["password", "gate"])
    }

    @Test func aSignedOutAccountThrows() async throws {
        await #expect(throws: UptfError.self) {
            _ = try await read(password: { throw UptfError.notSignedIn })
        }
    }

    @Test func aFailedDisplayReadDoesNotLetThePickerSave() async throws {
        let settings = try await read(display: { throw UptfError.server(status: 500, message: "Try again later.") })
        #expect(settings.display?.failure == "Couldn't read this setting. Try again later.")
        #expect(settings.display?.allowsSaving == false)
    }

    // MARK: What the list already said

    @Test func aListThatCarriesEverythingAndNoEmailGateCostsNoReads() async throws {
        let reads = Reads()
        let known = KnownSettings(passwordProtected: true, emailGateEnabled: false, displayMode: .previewDownload)
        let settings = try await read(known: known, reads: reads)
        #expect(await reads.names == [])
        #expect(settings.password == .value(true))
        #expect(settings.emailGate == .value(EmailGateSetting(enabled: false, message: nil)))
        #expect(settings.display == .value(.previewDownload))
        #expect(!settings.gateMessageKnown)
    }

    @Test func anEmailGateThatIsOnIsStillReadForItsMessage() async throws {
        let reads = Reads()
        let known = KnownSettings(passwordProtected: false, emailGateEnabled: true, displayMode: .preview)
        let settings = try await read(known: known, reads: reads)
        #expect(await reads.names == ["gate"])
        #expect(settings.emailGate == .value(EmailGateSetting(enabled: true, message: "Hi")))
        #expect(settings.password == .value(false))
        #expect(settings.display == .value(.preview))
        #expect(settings.gateMessageKnown)
    }

    @Test func aListWithoutTheFieldsReadsAllThreeAsBefore() async throws {
        let reads = Reads()
        let settings = try await read(known: KnownSettings(page: makePage()), reads: reads)
        #expect(await reads.names == ["password", "gate", "display"])
        #expect(settings.gateMessageKnown)
    }

    @Test func onlyWhatTheListLeavesOutIsRead() async throws {
        let reads = Reads()
        _ = try await read(known: KnownSettings(passwordProtected: true), reads: reads)
        #expect(await reads.names == ["gate", "display"])

        let more = Reads()
        _ = try await read(known: KnownSettings(emailGateEnabled: false, displayMode: .download), reads: more)
        #expect(await more.names == ["password"])
    }

    @Test func aWebsiteWithEverythingKnownStillReadsNothingForDisplay() async throws {
        let reads = Reads()
        let known = KnownSettings(passwordProtected: false, emailGateEnabled: false, displayMode: .preview)
        let settings = try await read(readsDisplay: false, known: known, reads: reads)
        #expect(await reads.names == [])
        #expect(settings.display == nil)
    }

    @Test func aGateThatIsOnAndCannotBeReadStaysUnsavableWhateverTheListSaid() async throws {
        let known = KnownSettings(passwordProtected: true, emailGateEnabled: true, displayMode: .preview)
        let settings = try await read(known: known, gate: { throw UptfError.server(status: 500, message: "") })
        #expect(settings.emailGate.failure != nil)
        #expect(!settings.emailGate.allowsSaving)
        #expect(settings.password == .value(true))
    }

    @Test func knownSettingsComeFromThePage() {
        let page = makePage(passwordProtected: true, emailGateEnabled: false, displayMode: .download)
        #expect(KnownSettings(page: page) == KnownSettings(passwordProtected: true, emailGateEnabled: false, displayMode: .download))
        #expect(KnownSettings(page: makePage()) == KnownSettings())
    }
}

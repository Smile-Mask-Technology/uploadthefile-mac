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
        readsDisplay: Bool = true, reads: Reads = Reads(),
        password: @escaping @Sendable () async throws -> Bool = { true },
        gate: @escaping @Sendable () async throws -> EmailGateSetting = { EmailGateSetting(enabled: true, message: "Hi") },
        display: @escaping @Sendable () async throws -> DisplayMode = { .download }
    ) async throws -> PageSettings {
        try await SettingsReader.read(
            readsDisplay: readsDisplay,
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
}

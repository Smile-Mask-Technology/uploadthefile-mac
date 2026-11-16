import Foundation
import Testing

@testable import UptfKit

/// The password, email-gate and display state that a current server puts on every page.
@Suite("Page state from the list")
struct PageStateTests {
    private static let state = #","passwordProtected":true,"emailGateEnabled":false,"displayMode":"preview_download""#
    private static let gateOnState = #","passwordProtected":false,"emailGateEnabled":true,"displayMode":"download""#

    private static let passwordRead = #"{"success":true,"data":{"protected":true,"entitled":true}}"#
    private static let gateRead =
        #"{"success":true,"data":{"enabled":true,"message":"Hi","consentRequired":false,"captureCount":3,"entitled":true}}"#
    private static let displayRead = #"{"success":true,"data":{"mode":"download","applies":true}}"#

    /// A server whose list carries `pages`; every per-page read and write is answered too.
    private static func transport(pages: [String]) -> FakeTransport {
        FakeTransport { method, path in
            switch (method, path) {
            case ("GET", let p) where p.hasPrefix("/pages?"): return .json(listJSON(pages))
            case ("GET", "/pages/mysite/password"): return .json(passwordRead)
            case ("GET", "/pages/mysite/email-gate"): return .json(gateRead)
            case ("GET", "/pages/mysite/display"): return .json(displayRead)
            case ("PUT", "/pages/mysite/password"), ("DELETE", "/pages/mysite/password"):
                return .json(#"{"success":true,"data":{"protected":true}}"#)
            case ("PUT", "/pages/mysite/email-gate"):
                return .json(
                    #"{"success":true,"data":{"enabled":true,"message":null,"consentRequired":false,"captureCount":0}}"#)
            case ("PUT", "/pages/mysite/display"): return .json(#"{"success":true,"data":{"mode":"download"}}"#)
            default: return .error(404, "nope")
            }
        }
    }

    // MARK: Decoding

    @Test func theListCarriesTheThreeFields() async throws {
        let client = makeClient(Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.state)]))
        let page = try #require(try await client.pages().first)
        #expect(page.passwordProtected == true)
        #expect(page.emailGateEnabled == false)
        #expect(page.displayMode == .previewDownload)
    }

    @Test func aServerWithoutTheFieldsLeavesThemUnknown() async throws {
        let client = makeClient(Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf")]))
        let page = try #require(try await client.pages().first)
        #expect(page.passwordProtected == nil)
        #expect(page.emailGateEnabled == nil)
        #expect(page.displayMode == nil)
    }

    @Test func aSinglePageAnswerCarriesThemToo() async throws {
        let transport = FakeTransport { _, _ in
            .json(pageEnvelopeJSON(pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.gateOnState)))
        }
        let page = try await makeClient(transport).page("mysite")
        #expect(page.passwordProtected == false)
        #expect(page.emailGateEnabled == true)
        #expect(page.displayMode == .download)
    }

    @Test func unknownFieldsStayOutOfTheJSONThePageIsWrittenAs() throws {
        let encoder = JSONEncoder()
        let bare = String(decoding: try encoder.encode(makePage(id: "a", name: "one")), as: UTF8.self)
        #expect(!bare.contains("passwordProtected"))
        #expect(!bare.contains("emailGateEnabled"))
        #expect(!bare.contains("displayMode"))

        var page = makePage(id: "a", name: "one")
        page.passwordProtected = true
        let written = String(decoding: try encoder.encode(page), as: UTF8.self)
        #expect(written.contains("\"passwordProtected\":true"))
    }

    // MARK: Reads

    @Test func detailsFromAListWithTheFieldsCostNoReadsWhenTheGateIsOff() async throws {
        let transport = Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.state)])
        let client = makeClient(transport)
        _ = try await client.pages()

        let details = try await client.details("mysite", includeSettings: true)
        #expect(details.passwordProtected == true)
        #expect(details.emailGateEnabled == false)
        #expect(details.displayMode == .previewDownload)
        #expect(transport.requests == ["GET /pages?limit=1000"])
    }

    @Test func aGateThatIsOnIsTheOnlyReadNeededForItsMessage() async throws {
        let transport = Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.gateOnState)])
        let client = makeClient(transport)
        _ = try await client.pages()

        let details = try await client.details("mysite", includeSettings: true)
        #expect(details.emailGateEnabled == true)
        #expect(details.emailGateMessage == "Hi")
        #expect(details.passwordProtected == false)  // from the list, not read
        #expect(transport.requests == ["GET /pages?limit=1000", "GET /pages/mysite/email-gate"])
    }

    @Test func detailsWithoutSettingsShowWhatTheListCarries() async throws {
        let transport = Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.state)])
        let client = makeClient(transport)
        _ = try await client.pages()
        let details = try await client.details("mysite")
        #expect(details.passwordProtected == true)
        #expect(transport.requests.count == 1)
    }

    @Test func anOlderServerStillGetsAllThreeReads() async throws {
        let transport = Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf")])
        let client = makeClient(transport)
        _ = try await client.pages()

        let details = try await client.details("mysite", includeSettings: true)
        #expect(details.passwordProtected == true)
        #expect(details.emailGateEnabled == true)
        #expect(details.displayMode == .download)
        #expect(
            transport.requests == [
                "GET /pages?limit=1000", "GET /pages/mysite/password", "GET /pages/mysite/email-gate",
                "GET /pages/mysite/display",
            ])
    }

    // MARK: The cached page after a change

    @Test func changingTheSettingsPatchesTheCachedPageWithoutARefetch() async throws {
        let transport = Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.state)])
        let client = makeClient(transport)
        _ = try await client.pages()

        try await client.removePassword(for: "mysite")
        #expect(try await client.page("mysite").passwordProtected == false)

        try await client.setPassword("long enough", for: "mysite")
        #expect(try await client.page("p1").passwordProtected == true)

        try await client.setEmailGate("mysite", enabled: true, message: nil)
        #expect(try await client.page("mysite").emailGateEnabled == true)

        try await client.setDisplay("mysite", mode: .download)
        let page = try await client.page("mysite")
        #expect(page.displayMode == .download)
        #expect(try await client.pages().first == page)

        #expect(
            transport.requests == [
                "GET /pages?limit=1000", "DELETE /pages/mysite/password", "PUT /pages/mysite/password",
                "PUT /pages/mysite/email-gate", "PUT /pages/mysite/display",
            ])
    }

    @Test func aRefusedChangeLeavesTheCachedPageAlone() async throws {
        let transport = FakeTransport { method, path in
            if method == "GET" { return .json(listJSON([pageJSON(id: "p1", name: "mysite", kind: "pdf", state: Self.state)])) }
            return .error(403, "Password protection is available on Pro and above")
        }
        let client = makeClient(transport)
        _ = try await client.pages()
        _ = await thrownUptfError { try await client.removePassword(for: "mysite") }
        #expect(try await client.page("mysite").passwordProtected == true)
    }

    @Test func aSettingChangeOnAnOlderServerDoesNotInventTheOthers() async throws {
        let transport = Self.transport(pages: [pageJSON(id: "p1", name: "mysite", kind: "pdf")])
        let client = makeClient(transport)
        _ = try await client.pages()
        try await client.setPassword("long enough", for: "mysite")
        let page = try await client.page("mysite")
        #expect(page.passwordProtected == true)
        #expect(page.emailGateEnabled == nil)
        #expect(page.displayMode == nil)
    }
}

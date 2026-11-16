import Foundation
import Testing
import UptfKit

/// The files the app bundle is assembled from (scripts/build-app.sh) are checked here, so a typo
/// in Info.plist is caught by the test run rather than by a Finder menu that silently lacks an entry.
@Suite("App bundle resources")
struct BundleResourceTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func versionFileMatchesTheLibraryVersion() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == UptfKitVersion.value)
    }

    @Test func infoPlistDescribesAMenuBarApp() throws {
        let plist = try infoPlist()
        #expect(plist["CFBundleIdentifier"] as? String == "com.smilemasktechnology.uploadthefile")
        #expect(plist["CFBundleName"] as? String == "Upload the File")
        #expect(plist["CFBundleExecutable"] as? String == "UploadTheFile")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plist["NSHumanReadableCopyright"] as? String == "Copyright © 2026 Smile Mask Technology")
    }

    @Test func finderServicesAreDeclaredForFilesAndFolders() throws {
        let services = try #require(try infoPlist()["NSServices"] as? [[String: Any]])
        #expect(services.count == 2)
        let byMessage = Dictionary(uniqueKeysWithValues: services.compactMap { service -> (String, [String: Any])? in
            guard let message = service["NSMessage"] as? String else { return nil }
            return (message, service)
        })
        let titles = Dictionary(uniqueKeysWithValues: byMessage.map { message, service in
            (message, (service["NSMenuItem"] as? [String: String])?["default"])
        })
        // These selectors are implemented by ServicesProvider in the app target.
        #expect(titles["publishFiles"] == "Publish with Upload the File")
        #expect(titles["copyLink"] == "Copy Upload the File Link")
        for service in services {
            #expect(service["NSPortName"] as? String == "UploadTheFile")  // the executable's name
            let types = service["NSSendFileTypes"] as? [String] ?? []
            #expect(types.contains("public.item"))
            #expect(types.contains("public.folder"))
        }
    }

    @Test func entitlementsAreAValidPropertyList() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/UploadTheFile.entitlements"))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let entitlements = try #require(object as? [String: Any])
        // No App Sandbox in version 1 (see "Sandbox" in docs/DEVELOPMENT.md).
        #expect(entitlements["com.apple.security.app-sandbox"] == nil)
    }

    /// Every name MenuBarIcon asks the bundle for exists as a PDF (the app falls back to an SF
    /// Symbol silently, so a missing file would only show as the wrong icon).
    @Test func menuBarIconArtworkIsComplete() throws {
        var names = ["idle", "signedOut", "dropTarget"]
        names += (1...12).map { String(format: "busy-%02d", $0) }
        for name in names {
            let url = Self.root.appendingPathComponent("Resources/MenuBarIcons/MenuBarIcon-\(name).pdf")
            let data = try Data(contentsOf: url)
            #expect(data.starts(with: Data("%PDF".utf8)), "\(name) is not a PDF")
        }
        #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Resources/AppIcon.icns").path))
        let mark = try Data(contentsOf: Self.root.appendingPathComponent("Resources/BrandMark.pdf"))
        #expect(mark.starts(with: Data("%PDF".utf8)), "BrandMark.pdf is not a PDF")
    }
}

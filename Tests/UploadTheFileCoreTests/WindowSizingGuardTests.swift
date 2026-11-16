import Foundation
import Testing

/// The app crashed twice on a drop (2026-11-16): a window whose size followed SwiftUI's ideal
/// size (`NSHostingController.sizingOptions` including `.preferredContentSize`, which is the
/// default) fed its frame back into the layout while AppKit committed the drop, until AppKit gave
/// up after ~50 constraint passes and threw. Every window and the popover now turn the sizing
/// options off and set their size explicitly (PopoverSizing and the window controllers). These
/// tests read the app's sources, so they guard the pattern, not the run-time behaviour; they scan
/// every Swift file below Sources/UploadTheFile, and each one fails if it finds nothing to check.
@Suite("Window sizing guard")
struct WindowSizingGuardTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/UploadTheFile")

    /// One source file of the app, as the lines that are not whole-line comments.
    private struct SourceFile {
        let name: String
        let code: [String]

        func count(of needle: String) -> Int {
            code.filter { $0.contains(needle) }.count
        }
    }

    private static func appFiles() throws -> [SourceFile] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: appSources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        let files = try paths.map { path -> SourceFile in
            let text = try String(contentsOf: appSources.appendingPathComponent(path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return SourceFile(name: path, code: code)
        }
        try #require(!files.isEmpty, "no Swift files found under \(appSources.path)")
        return files
    }

    private static func file(_ name: String) throws -> SourceFile {
        try #require(try appFiles().first(where: { $0.name == name }), "\(name) is missing from Sources/UploadTheFile")
    }

    @Test func noWindowFollowsSwiftUIsIdealSize() throws {
        for file in try Self.appFiles() {
            #expect(file.count(of: "preferredContentSize") == 0,
                    "\(file.name) lets a window follow SwiftUI's ideal size")
        }
    }

    /// `NSHostingController` follows SwiftUI's ideal size unless its sizing options are cleared, so
    /// merely avoiding the word `preferredContentSize` is not enough: every controller that is
    /// created has to switch them off.
    @Test func everyHostingControllerTurnsItsSizingOptionsOff() throws {
        var controllers = 0
        for file in try Self.appFiles() {
            let created = file.count(of: "NSHostingController(")
            let cleared = file.count(of: "sizingOptions = []")
            controllers += created
            #expect(created == cleared,
                    "\(file.name) creates \(created) hosting controller(s) but clears the sizing options \(cleared) time(s)")
        }
        #expect(controllers > 0, "no NSHostingController found: the check below would pass for nothing")
    }

    /// A modal alert asked from the popover (delete) must not close the list: every alert the
    /// app shows goes through askKeepingStatusOpen, which keeps the popover open around it.
    @Test func alertsFromTheListKeepThePopoverOpen() throws {
        var calls = 0
        for file in try Self.appFiles() where file.name != "Support.swift" {  // Support.swift defines Alerts
            for line in file.code where line.contains("Alerts.") {
                calls += 1
                #expect(line.contains("askKeepingStatusOpen"), "\(file.name): an alert that would close the popover: \(line)")
            }
        }
        #expect(calls > 0, "no alert call found: the check above would pass for nothing")
    }

    @Test func dropsStartWorkOnlyAfterTheDropAnimation() throws {
        // Both drop targets (the popover list and the menu bar icon) defer the publish past
        // AppKit's drop animation instead of starting it inside the drop callback.
        for name in ["MenuContentView.swift", "StatusItemController.swift"] {
            let file = try Self.file(name)
            #expect(file.count(of: "DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)") > 0, "\(name)")
        }
    }

    /// The first menu opened in the popover after launch (the row's "…") closed itself about 250 ms
    /// later: the cooperative `NSApp.activate()` request landed while it was open. Every activation
    /// goes through AppActivation, which uses `activate(ignoringOtherApps:)`.
    @Test func activationNeverUsesTheCooperativeRequest() throws {
        for file in try Self.appFiles() {
            #expect(file.count(of: "NSApp.activate()") == 0 && file.count(of: "NSApplication.shared.activate()") == 0,
                    "\(file.name) uses the cooperative activation request")
        }
        let support = try Self.file("Support.swift")
        #expect(support.count(of: "NSApp.activate(ignoringOtherApps: true)") > 0)
    }
}

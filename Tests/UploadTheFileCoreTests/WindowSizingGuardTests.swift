import Foundation
import Testing

/// The app crashed twice on a drop (2026-11-16): a window whose size followed SwiftUI's ideal
/// size (`NSHostingController.sizingOptions = [.preferredContentSize]`) fed its frame back into
/// the layout while AppKit committed the drop, until AppKit gave up after ~50 constraint passes
/// and threw. Every window and the popover now set their size explicitly (PopoverSizing and the
/// window controllers). This keeps the pattern from coming back in any app source file.
@Suite("Window sizing guard")
struct WindowSizingGuardTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/UploadTheFile")

    @Test func noWindowFollowsSwiftUIsIdealSize() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!code.contains { $0.contains("preferredContentSize") },
                    "\(file.lastPathComponent) lets a window follow SwiftUI's ideal size")
        }
    }

    /// A modal alert asked from the popover (delete) must not close the list: every alert the
    /// model runs goes through askKeepingStatusOpen, which keeps the popover open around it.
    @Test func alertsFromTheListKeepThePopoverOpen() throws {
        let text = try String(contentsOf: Self.appSources.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        let calls = text.split(separator: "\n").filter { $0.contains("Alerts.") }
        #expect(!calls.isEmpty)
        for line in calls {
            #expect(line.contains("askKeepingStatusOpen"), "an alert that would close the popover: \(line)")
        }
    }

    @Test func dropsStartWorkOnlyAfterTheDropAnimation() throws {
        // Both drop targets (the popover list and the menu bar icon) defer the publish past
        // AppKit's drop animation instead of starting it inside the drop callback.
        for name in ["MenuContentView.swift", "StatusItemController.swift"] {
            let text = try String(contentsOf: Self.appSources.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)"), "\(name)")
        }
    }

    /// The first menu opened in the popover after launch (the row's "…") closed itself about 250 ms
    /// later: the cooperative `NSApp.activate()` request landed while it was open. Every activation
    /// goes through AppActivation, which uses `activate(ignoringOtherApps:)`.
    @Test func activationNeverUsesTheCooperativeRequest() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!code.contains { $0.contains("NSApp.activate()") || $0.contains("NSApplication.shared.activate()") },
                    "\(file.lastPathComponent) uses the cooperative activation request")
        }
        let support = try String(contentsOf: Self.appSources.appendingPathComponent("Support.swift"), encoding: .utf8)
        #expect(support.contains("NSApp.activate(ignoringOtherApps: true)"))
    }
}

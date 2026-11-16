import Foundation
import Testing

/// The alerts live in the app target, which tests cannot link, so this reads the source (like
/// `WindowSizingGuardTests`): it guards the pattern, not what AppKit does at run time.
@Suite("Alert defaults guard")
struct AlertDefaultsGuardTests {
    private static let support = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/UploadTheFile/Support.swift")

    /// `NSAlert` gives Return to the first button it was given. The destructive Delete button is
    /// first (it answers `.alertFirstButtonReturn`), so Return would delete: it gets no key, and
    /// Escape cancels.
    @Test func noKeyDeletesInTheDeleteAlert() throws {
        let text = try String(contentsOf: Self.support, encoding: .utf8)
        let start = try #require(text.range(of: "static func confirmDelete"))
        let end = try #require(text.range(of: "static func inform", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])

        #expect(body.contains("remove.hasDestructiveAction = true"))
        #expect(body.contains(#"remove.keyEquivalent = """#), "Delete must not keep the Return key")
        #expect(body.contains(#"cancel.keyEquivalent = "\u{1b}""#), "Escape must cancel")
        #expect(body.contains("alert.runModal() == .alertFirstButtonReturn"), "the answer is still Delete = first button")
    }
}

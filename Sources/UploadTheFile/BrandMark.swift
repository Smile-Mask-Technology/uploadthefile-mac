import AppKit
import SwiftUI

/// The upload.tf logo in colour (Resources/BrandMark.pdf, generated from the website's logo
/// geometry by scripts/make-menubar-icons.swift). Shipped in Contents/Resources; a DEBUG run
/// without a bundle (swift build, the snapshot renderer) reads it from the repository instead.
struct BrandMark: View {
    /// Height in points; the width follows the artwork (367 x 345).
    var height: CGFloat

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(367.0 / 345.0, contentMode: .fit)
                .frame(height: height)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.up.doc.fill")
                .font(.system(size: height * 0.8))
                .foregroundStyle(Color.accentColor)
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }

    @MainActor private static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: repo.appendingPathComponent("Resources/BrandMark.pdf"))
        #else
        return nil
        #endif
    }()
}

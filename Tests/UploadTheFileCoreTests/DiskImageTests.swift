import CoreGraphics
import Foundation
import ImageIO
import Testing

/// The disk image people open to install the app: the window layout (scripts/dmg-settings.py),
/// its background pictures, and the way scripts/release.sh builds it. Nothing here mounts an
/// image or opens a Finder window; the files are read as text and as PNG data.
@Suite("Disk image")
struct DiskImageTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The lines of a script that are not whole-line comments (`#` or `//`).
    private static func codeLines(_ path: String) throws -> [String] {
        try text(path).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private static func line(_ lines: [String], _ needles: String...) -> Int? {
        lines.firstIndex { line in needles.allSatisfy { line.contains($0) } }
    }

    // MARK: Background pictures

    private struct PNGInfo {
        let width: Int
        let height: Int
        /// Pixels per metre from the pHYs chunk (72 dpi is 2835, 144 dpi is 5669).
        let pixelsPerMetre: Int?
    }

    private static func pngInfo(_ path: String) throws -> PNGInfo {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "\(path) is not a PNG")
        func word(_ offset: Int) -> Int {
            data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        var offset = 8
        var width = 0, height = 0
        var density: Int?
        while offset + 8 <= data.count {
            let length = word(offset)
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            if type == "IHDR" { width = word(offset + 8); height = word(offset + 12) }
            if type == "pHYs" { density = word(offset + 8) }
            offset += 12 + length
        }
        return PNGInfo(width: width, height: height, pixelsPerMetre: density)
    }

    @Test func backgroundPicturesExistAtOneAndTwoTimes() throws {
        let one = try Self.pngInfo("Resources/DMG/background.png")
        let two = try Self.pngInfo("Resources/DMG/background@2x.png")
        #expect(one.width == 600 && one.height == 380)
        #expect(two.width == 1200 && two.height == 760)
        // Finder picks the 2x picture only when its density is double the 1x one. A PNG without a
        // pHYs chunk (the writer leaves it out at 72 dpi) counts as 72 dpi, 2835 pixels per metre.
        let low = one.pixelsPerMetre ?? 2835
        let high = try #require(two.pixelsPerMetre, "background@2x.png has no pixel density")
        #expect(abs(high - 2 * low) <= 2, "densities \(low) and \(high)")
    }

    /// Finder draws icon labels in black over a background picture, in Dark Mode too, so every
    /// pixel above the hint line has to stay light (contrast with black above 7:1).
    @Test func backgroundStaysLightEnoughForBlackLabels() throws {
        let url = Self.root.appendingPathComponent("Resources/DMG/background@2x.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drewIt = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drewIt)
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // The first 300 points of 380 hold the arrow and the icon slots; the hint is below.
        var darkest = 1.0
        var opaque = true
        for y in 0..<(300 * 2) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i + 3] != 255 { opaque = false }
                let luminance = 0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
                darkest = min(darkest, luminance)
            }
        }
        #expect(opaque, "the background must be opaque")
        #expect((darkest + 0.05) / 0.05 >= 7, "darkest pixel has luminance \(darkest)")
    }

    // MARK: Window layout

    @Test func settingsPlaceOnlyTheAppAndTheApplicationsLink() throws {
        let code = try Self.codeLines("scripts/dmg-settings.py").joined(separator: "\n")
        // The disk image holds the app and the link, nothing else: the licences ship inside the app.
        #expect(code.contains("files = [(defines.get(\"app\", \"build/Upload the File.app\"), \"Upload the File.app\")]"))
        #expect(code.contains("symlinks = {\"Applications\": \"/Applications\"}"))
        #expect(!code.contains("LICENSE") && !code.contains("THIRD_PARTY"))
        #expect(code.contains("icon_locations = {\"Upload the File.app\": (160, 180), \"Applications\": (440, 180)}"))
        #expect(code.contains("hide_extensions = [\"Upload the File.app\"]"))
    }

    @Test func settingsDescribeTheWindowAndTheBackground() throws {
        let code = try Self.codeLines("scripts/dmg-settings.py").joined(separator: "\n")
        #expect(code.contains("background = \"Resources/DMG/background.png\""))
        #expect(code.contains("icon = \"Resources/AppIcon.icns\""))
        // 600 x 380 points below the title bar, which Finder counts in the window's height.
        #expect(code.contains("window_rect = ((200, 120), (600, 380 + 28))"))
        #expect(code.contains("icon_size = 128"))
        #expect(code.contains("text_size = 13"))
        #expect(code.contains("default_view = \"icon-view\""))
        for hidden in ["show_status_bar", "show_tab_view", "show_toolbar", "show_pathbar", "show_sidebar"] {
            #expect(code.contains("\(hidden) = False"), "\(hidden) must be off")
        }
        #expect(code.contains("format = \"ULFO\""))
        #expect(code.contains("filesystem = \"HFS+\""))
    }

    // MARK: make-dmg.sh

    @Test func builderInstallsPinnedPackagesInAPrivateEnvironmentOnlyWhenNeeded() throws {
        let lines = try Self.codeLines("scripts/make-dmg.sh")
        #expect(lines.contains { $0.contains(".build/dmg-venv") })
        let install = try #require(Self.line(lines, "pip", "install", "--require-hashes", "-r", "scripts/requirements-dmg.txt"))
        let stamp = try #require(Self.line(lines, "cmp -s", "scripts/requirements-dmg.txt", "$STAMP"), "the install is not skipped when the requirements are unchanged")
        #expect(stamp < install)
        #expect(lines.contains { $0.contains("/opt/homebrew/bin/python3") })
        #expect(lines.contains { $0.contains("sys.version_info") && $0.contains("(3, 11)") }, "the Python version is not checked")
        let run = try #require(Self.line(lines, "dmgbuild", "scripts/dmg-settings.py"))
        #expect(lines[run].contains("Upload the File"), "the volume name is missing: \(lines[run])")
        #expect(lines[run] != lines[install])
    }

    @Test func requirementsPinDmgbuildWithHashes() throws {
        let requirements = try Self.text("scripts/requirements-dmg.txt")
        #expect(requirements.contains("dmgbuild==2.0.0"))
        #expect(requirements.contains("--hash=sha256:"))
    }

    // MARK: release.sh

    @Test func releaseBuildsTheDiskImageWithTheBuilderAndShipsNoLooseLicenceFiles() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        #expect(!lines.contains { $0.contains("hdiutil create") }, "the plain hdiutil image is back")
        #expect(!lines.contains { $0.contains("LICENSE.txt") }, "LICENSE.txt must not be copied next to the app")
        #expect(!lines.contains { $0.contains("cp ") && $0.contains("THIRD_PARTY_NOTICES.txt") && $0.contains("STAGE") })
        #expect(!lines.contains { $0.contains("$STAGE") }, "the staging folder is not needed any more")

        let staple = try #require(Self.line(lines, "stapler staple \"$APP\""))
        let make = try #require(Self.line(lines, "scripts/make-dmg.sh", "\"$APP\"", "\"$DMG\""))
        let sign = try #require(Self.line(lines, "codesign --force --timestamp --sign \"$SIGN_IDENTITY\" \"$DMG\""))
        let notarize = try #require(Self.line(lines, "notarytool submit \"$DMG\""))
        #expect(staple < make && make < sign && sign < notarize)
    }

    @Test func releaseChecksTheAppBundleHoldsBothLicenceFilesBeforeBuildingTheDiskImage() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let check = try #require(Self.line(lines, "THIRD_PARTY_NOTICES.txt LICENSE"), "the licence files are not checked")
        let gate = try #require(lines.indices.first { $0 > check && lines[$0].contains("$APP/Contents/Resources/$f") })
        #expect(lines[gate].contains("-s "), "an empty file must not pass")
        let make = try #require(Self.line(lines, "scripts/make-dmg.sh"))
        #expect(gate < make)
    }

    // MARK: Preview and docs

    @Test func previewAndBackgroundScriptsExist() throws {
        let preview = try Self.text("scripts/make-dmg-preview.swift")
        #expect(preview.contains("build/dmg-preview.png"))
        #expect(preview.contains("NSWorkspace.shared.icon(forFile: \"/Applications\")"))
        let background = try Self.text("scripts/make-dmg-background.swift")
        #expect(background.contains("Drag to Applications to install"))
        #expect(!background.contains("URLSession"), "the background is drawn without the network")
    }

    @Test func docsDescribeTheBuilderAndThePreview() throws {
        let development = try Self.text("docs/DEVELOPMENT.md")
        #expect(development.contains("scripts/make-dmg.sh"))
        #expect(development.contains("scripts/make-dmg-preview.swift"))
        #expect(development.contains("scripts/make-dmg-background.swift"))
        let releasing = try Self.text("docs/RELEASING.md")
        #expect(releasing.contains("scripts/make-dmg.sh"))
        #expect(!releasing.contains("LICENSE.txt"))
    }
}

// Renders build/dmg-preview.png: the disk image window as a picture, without mounting anything or
// opening Finder. It is the 2x background with the app icon (Resources/AppIcon.icns) and the
// Applications folder icon drawn at the icon positions of scripts/dmg-settings.py, at the icon
// size set there, with their labels in black below, the way Finder draws them over a background
// picture. Use it to review the layout.
//
// Usage: swift scripts/make-dmg-preview.swift [output .png]   (default: build/dmg-preview.png)
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// The layout comes from the settings file, so the preview cannot drift from the image.
guard let settings = try? String(contentsOfFile: "scripts/dmg-settings.py", encoding: .utf8) else {
    fail("Run this from the repository root: scripts/dmg-settings.py not found")
}
func number(_ pattern: String) -> CGFloat {
    guard let match = settings.range(of: pattern, options: .regularExpression) else { fail("dmg-settings.py: no match for \(pattern)") }
    let digits = settings[match].components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
    guard let value = Double(digits) else { fail("dmg-settings.py: no number in \(settings[match])") }
    return CGFloat(value)
}
let iconSize = number("icon_size = [0-9.]+")
let textSize = number("text_size = [0-9.]+")
func point(_ name: String) -> CGPoint {
    guard let match = settings.range(of: "\"\(name)\": \\(([0-9]+), ([0-9]+)\\)", options: .regularExpression) else {
        fail("dmg-settings.py: no icon location for \(name)")
    }
    let parts = settings[match].components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).filter { !$0.isEmpty }
    return CGPoint(x: Double(parts[0])!, y: Double(parts[1])!)
}

guard let background = NSImage(contentsOfFile: "Resources/DMG/background@2x.png"),
      let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns") else {
    fail("Missing Resources/DMG/background@2x.png or Resources/AppIcon.icns")
}
let folderIcon = NSWorkspace.shared.icon(forFile: "/Applications")

let scale: CGFloat = 2
let pixelsWide = Int(background.representations.first?.pixelsWide ?? 1200)
let pixelsHigh = Int(background.representations.first?.pixelsHigh ?? 760)
let points = NSSize(width: CGFloat(pixelsWide) / scale, height: CGFloat(pixelsHigh) / scale)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: pixelsWide, height: pixelsHigh)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: scale, y: scale)
context.imageInterpolation = .high

background.draw(in: NSRect(origin: .zero, size: points))

let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: textSize), .foregroundColor: NSColor.black]
let items: [(String, String, NSImage)] = [
    ("Upload the File.app", "Upload the File", appIcon),  // Finder hides the .app extension
    ("Applications", "Applications", folderIcon),
]
for (key, title, image) in items {
    let centre = point(key)  // from the top left, in points
    let centreY = points.height - centre.y
    image.draw(
        in: NSRect(x: centre.x - iconSize / 2, y: centreY - iconSize / 2, width: iconSize, height: iconSize),
        from: .zero, operation: .sourceOver, fraction: 1)
    let text = NSAttributedString(string: title, attributes: label)
    let textBox = text.size()
    text.draw(at: NSPoint(x: centre.x - textBox.width / 2, y: centreY - iconSize / 2 - 6 - textBox.height))
}
NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/dmg-preview.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
rep.size = points
try rep.representation(using: .png, properties: [:])!.write(to: output)
print(output.path)

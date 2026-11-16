// Draws the background of the disk image window (scripts/dmg-settings.py) as two PNG files:
// background.png (600 x 380 pixels) and background@2x.png (1200 x 760 pixels, 144 dpi). Finder
// shows the 2x file on Retina screens when its density is double the 1x file's.
//
// A near-white surface, one thin arrow between the two icon slots, and one line of hint text.
// Finder draws the icon labels in black over a background picture, in Dark Mode too, so every
// colour here stays light. The output is deterministic and needs no network.
//
// Usage: swift scripts/make-dmg-background.swift [output folder]   (default: Resources/DMG)
import AppKit

let size = NSSize(width: 600, height: 380)
// The icon slots in scripts/dmg-settings.py: 128 pt icons centred at x = 160 and x = 440.
let slotGap = (left: CGFloat(160 + 64), right: CGFloat(440 - 64))
let iconCentreY: CGFloat = 180

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Everything is drawn in points with the origin at the top left, as Finder lays icons out.
func draw() {
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(colors: [color(0xF7F7F5), color(0xEFEFEC)])!.draw(in: bounds, angle: -90)

    // The arrow: a line with a chevron head, centred between the two icons at their height.
    let middle = size.height - iconCentreY
    let centreX = (slotGap.left + slotGap.right) / 2
    let half: CGFloat = 46
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: centreX - half, y: middle))
    arrow.line(to: NSPoint(x: centreX + half, y: middle))
    arrow.move(to: NSPoint(x: centreX + half - 13, y: middle + 13))
    arrow.line(to: NSPoint(x: centreX + half, y: middle))
    arrow.line(to: NSPoint(x: centreX + half - 13, y: middle - 13))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0x8E8E93, alpha: 0.7).setStroke()
    arrow.stroke()

    // The hint, centred near the bottom, below the icon labels.
    let hint = NSAttributedString(
        string: "Drag to Applications to install",
        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color(0x6E6E73)])
    let hintSize = hint.size()
    hint.draw(at: NSPoint(x: (size.width - hintSize.width) / 2, y: 40))
}

func render(scale: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // One unit of the context is one pixel while drawing, so the scale below is explicit.
    rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    draw()
    NSGraphicsContext.restoreGraphicsState()
    // The size in points sets the density written to the file: 72 dpi at 1x, 144 dpi at 2x.
    rep.size = size
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count <= 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background [output folder]\n".utf8))
    exit(64)
}
let folder = URL(fileURLWithPath: CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : "Resources/DMG", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try render(scale: 1).write(to: folder.appendingPathComponent("background.png"))
try render(scale: 2).write(to: folder.appendingPathComponent("background@2x.png"))

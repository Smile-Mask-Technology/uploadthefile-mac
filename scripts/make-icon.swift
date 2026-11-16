// Draws the PLACEHOLDER app icon into an .iconset folder (scripts/build-app.sh turns it into an
// .icns with iconutil). A white page with an upload arrow on a blue tile. Replace it with real
// artwork before shipping: put a finished AppIcon.icns in Resources/ and the build uses that.
//
// Usage: make-icon <output .iconset folder>
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Everything is drawn on a 1024 x 1024 canvas, origin bottom-left.
func drawIcon() {
    // The tile follows the macOS icon grid: 824 pt square inside 1024, with room for a shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    color(0x3558E8).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color(0x6C9BFF), color(0x2D47D6)])!.draw(in: tile.bounds, angle: -90)
    // A faint light from the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The page, with a folded corner.
    let page = NSBezierPath()
    page.move(to: NSPoint(x: 310, y: 250))
    page.line(to: NSPoint(x: 714, y: 250))
    page.line(to: NSPoint(x: 714, y: 640))
    page.line(to: NSPoint(x: 594, y: 774))
    page.line(to: NSPoint(x: 310, y: 774))
    page.close()
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowOffset = NSSize(width: 0, height: -10)
    pageShadow.shadowBlurRadius = 22
    pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    pageShadow.set()
    NSColor.white.setFill()
    page.fill()
    NSGraphicsContext.restoreGraphicsState()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 594, y: 774))
    fold.line(to: NSPoint(x: 594, y: 640))
    fold.line(to: NSPoint(x: 714, y: 640))
    fold.close()
    color(0xCCD8FF).setFill()
    fold.fill()

    // The upload arrow.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512, y: 640))
    arrow.line(to: NSPoint(x: 624, y: 520))
    arrow.line(to: NSPoint(x: 548, y: 520))
    arrow.line(to: NSPoint(x: 548, y: 340))
    arrow.line(to: NSPoint(x: 476, y: 340))
    arrow.line(to: NSPoint(x: 476, y: 520))
    arrow.line(to: NSPoint(x: 400, y: 520))
    arrow.close()
    arrow.lineJoinStyle = .round
    color(0x2D47D6).setFill()
    arrow.fill()
    color(0x2D47D6).setStroke()
    arrow.lineWidth = 14
    arrow.stroke()
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output .iconset folder>\n".utf8))
    exit(64)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// name -> pixel size, as iconutil expects.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels: pixels).write(to: folder.appendingPathComponent(name + ".png"))
}

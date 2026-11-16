// Generates the Upload the File brand artwork for the Mac app from the website's real logo geometry:
//
//   1. Menu bar (status item) TEMPLATE icons: idle, signedOut, dropTarget and the busy frames,
//      as vector PDF (pure black on transparent) + PNG @1x / @2x  -> Resources/MenuBarIcons/
//   2. The full-colour macOS app icon (iconset + AppIcon.icns)       -> Resources/AppIcon.icns
//   3. Review sheets (strips drawn here, never screenshots)           -> build/icon-review/
//
// Usage (from the repo root, uploadthefile-mac/):
//   swiftc -O scripts/make-menubar-icons.swift -o build/make-menubar-icons && build/make-menubar-icons
//
// Everything is drawn with CoreGraphics from the SVG path strings below: the website logo's paths,
// face and arrow gradients, edge colours and the busy "lift" loop timing. If the logo changes,
// update the strings and re-run.
// Coordinates are the artwork's own pixel space (viewBox 0 0 367 345, y down).

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Source geometry (the website logo, viewBox 0 0 367 345)

let ARROW_PATH =
    "M176.99 13.55A8.6 8.6 0 0 1 189.15 13.55L352.41 176.67A5.76 5.76 0 0 1 348.34 186.5L303.88 186.5L303.88 280.1A2 2 0 0 1 302.69 281.93L188.13 332.74A11 11 0 0 1 179.26 332.76L62.22 281.62A2 2 0 0 1 61.02 279.79L61.02 186.5L16.17 186.5A5.16 5.16 0 0 1 12.53 177.69Z"
let ARROW_CLIP_PATH =
    "M176.29 12.84A9.6 9.6 0 0 1 189.85 12.84L353.11 175.96A6.76 6.76 0 0 1 348.34 187.5L304.88 187.5L304.88 280.1A3 3 0 0 1 303.1 282.84L188.53 333.65A12 12 0 0 1 178.86 333.68L61.82 282.54A3 3 0 0 1 60.02 279.79L60.02 187.5L16.17 187.5A6.16 6.16 0 0 1 11.82 176.98Z"
let HOLE_PATH =
    "M183.33 124.3A2 2 0 0 1 184.67 124.3L281.67 159.12A2 2 0 0 1 282.99 161.01L282.99 263.39A2 2 0 0 1 281.79 265.23L184.6 307.95A2 2 0 0 1 183 307.95L83.55 264.92A2 2 0 0 1 82.34 263.09L82.34 161.32A2 2 0 0 1 83.68 159.43Z"
let BAND_PATH =
    "M94.98 171L114.3 164L183.6 188.3L254.2 164.2L270.93 170.7L270.93 171.8L184 204.4L94.98 171.75Z"
let TOP_FACE_PATH = "M185.5 138.5L254.2 164.2L183.6 188.3L114.3 164Z"
let LEFT_FACE_PATH = "M94.98 171.75L184 204.4L183 294L94.98 256.2Z"
let RIGHT_FACE_PATH = "M184 204.4L270.93 171.8L270.93 256.1L183 294Z"
let ARROW_EDGE_PATH =
    "M177.34 13.9A8.1 8.1 0 0 1 188.79 13.9L352.05 177.02A5.26 5.26 0 0 1 348.34 186L303.38 186L303.38 280.1A1.5 1.5 0 0 1 302.49 281.47L187.92 332.28A10.5 10.5 0 0 1 179.46 332.3L62.42 281.17A1.5 1.5 0 0 1 61.52 279.79L61.52 186L16.17 186A4.66 4.66 0 0 1 12.88 178.04Z"
let LEFT_FACE_EDGE_PATH = "M95.48 172.47L183.5 204.75L182.51 293.24L95.48 255.87Z"
let RIGHT_FACE_EDGE_PATH = "M184.5 204.75L270.43 172.52L270.43 255.77L183.51 293.24Z"
let TOP_FACE_EDGE_PATH = "M115.8 164L183.6 187.77L252.72 164.18"

// Gradients: [offset, hex]. Arrow gradient from LogoMark.tsx (x 183, y 7 -> 335); faces from LOGO_FACE_GRADIENTS.
let ARROW_STOPS: [(CGFloat, UInt32)] = [
    (0, 0x3da5fa), (0.174, 0x3092ef), (0.326, 0x237de2), (0.482, 0x196ad0), (0.558, 0x1260c7),
    (0.68, 0x0b55b9), (0.802, 0x034aab), (0.924, 0x0146a6), (1, 0x0345a2),
]
let LEFT_STOPS: [(CGFloat, UInt32)] = [(0, 0xe85014), (0.5, 0xf67a0d), (0.75, 0xfe8f09), (1, 0xffa308)]
let RIGHT_STOPS: [(CGFloat, UInt32)] = [
    (0, 0xffd080), (0.22, 0xffce7c), (0.357, 0xffca75), (0.49, 0xffc267), (0.625, 0xffbb5e),
    (0.76, 0xffb04c), (0.89, 0xffaa42), (1, 0xffa53d),
]
let TOP_STOPS: [(CGFloat, UInt32)] = [(0, 0xff9e20), (1, 0xffb94a)]

// MARK: - SVG path parsing (absolute M L H V A Z only, which is all the logo uses)

enum Tok { case cmd(Character), num(CGFloat) }

func tokenize(_ s: String) -> [Tok] {
    var out: [Tok] = []
    var cur = ""
    func flush() { if !cur.isEmpty { out.append(.num(CGFloat(Double(cur) ?? 0))); cur = "" } }
    for ch in s {
        if ch.isLetter && ch != "e" && ch != "E" {
            flush(); out.append(.cmd(ch))
        } else if ch == " " || ch == "," {
            flush()
        } else if ch == "-" {
            flush(); cur = "-"
        } else if ch == "." && cur.contains(".") {
            flush(); cur = "."
        } else {
            cur.append(ch)
        }
    }
    flush()
    return out
}

func addArc(_ path: CGMutablePath, from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat,
            large: Bool, sweep: Bool, to p1: CGPoint) {
    if p0 == p1 { return }
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 { path.addLine(to: p1); return }
    let phi = rotation * .pi / 180
    let cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1p = cosP * dx + sinP * dy
    let y1p = -sinP * dx + cosP * dy
    let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1 { rx *= sqrt(lam); ry *= sqrt(lam) }
    let sign: CGFloat = (large == sweep) ? -1 : 1
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    let coef = sign * sqrt(max(0, num / den))
    let cxp = coef * rx * y1p / ry
    let cyp = -coef * ry * x1p / rx
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let th1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
    var dth = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
    let segs = max(1, Int(ceil(abs(dth) / (.pi / 2))))
    let delta = dth / CGFloat(segs)
    let t = 4.0 / 3.0 * tan(delta / 4)
    func pt(_ a: CGFloat) -> CGPoint {
        CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
    }
    func dv(_ a: CGFloat) -> CGPoint {
        CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
    }
    for i in 0..<segs {
        let a1 = th1 + CGFloat(i) * delta, a2 = a1 + delta
        let c1 = CGPoint(x: pt(a1).x + t * dv(a1).x, y: pt(a1).y + t * dv(a1).y)
        let c2 = CGPoint(x: pt(a2).x - t * dv(a2).x, y: pt(a2).y - t * dv(a2).y)
        path.addCurve(to: i == segs - 1 ? p1 : pt(a2), control1: c1, control2: c2)
    }
}

func svgPath(_ d: String) -> CGPath {
    let toks = tokenize(d)
    let path = CGMutablePath()
    var cur = CGPoint.zero, start = CGPoint.zero
    var i = 0
    var cmd: Character = " "
    func num() -> CGFloat {
        if case .num(let v) = toks[i] { i += 1; return v }
        fatalError("bad path data: \(d)")
    }
    while i < toks.count {
        if case .cmd(let c) = toks[i] {
            cmd = c; i += 1
            if c == "Z" || c == "z" { path.closeSubpath(); cur = start; continue }
        }
        switch cmd {
        case "M":
            let p = CGPoint(x: num(), y: num()); path.move(to: p); cur = p; start = p; cmd = "L"
        case "L":
            let p = CGPoint(x: num(), y: num()); path.addLine(to: p); cur = p
        case "H":
            let p = CGPoint(x: num(), y: cur.y); path.addLine(to: p); cur = p
        case "V":
            let p = CGPoint(x: cur.x, y: num()); path.addLine(to: p); cur = p
        case "A":
            let rx = num(), ry = num(), rot = num(), large = num() != 0, sweep = num() != 0
            let p = CGPoint(x: num(), y: num())
            addArc(path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: p)
            cur = p
        default:
            fatalError("unsupported path command \(cmd)")
        }
    }
    return path
}

let ARROW = svgPath(ARROW_PATH)
let ARROW_CLIP = svgPath(ARROW_CLIP_PATH)
let HOLE = svgPath(HOLE_PATH)
let BAND = svgPath(BAND_PATH)
let TOP_FACE = svgPath(TOP_FACE_PATH)
let LEFT_FACE = svgPath(LEFT_FACE_PATH)
let RIGHT_FACE = svgPath(RIGHT_FACE_PATH)
let ARROW_EDGE = svgPath(ARROW_EDGE_PATH)
let LEFT_EDGE = svgPath(LEFT_FACE_EDGE_PATH)
let RIGHT_EDGE = svgPath(RIGHT_FACE_EDGE_PATH)
let TOP_EDGE = svgPath(TOP_FACE_EDGE_PATH)

/// Shoelace area of a path's on-curve points: only its sign (winding direction) is used.
func signedArea(_ path: CGPath) -> CGFloat {
    var pts: [CGPoint] = []
    path.applyWithBlock { e in
        switch e.pointee.type {
        case .moveToPoint, .addLineToPoint: pts.append(e.pointee.points[0])
        case .addCurveToPoint: pts.append(e.pointee.points[2])
        default: break
        }
    }
    var a: CGFloat = 0
    for i in 0..<pts.count { let p = pts[i], q = pts[(i + 1) % pts.count]; a += p.x * q.y - q.x * p.y }
    return a / 2
}

/// The loop's clip: ARROW_CLIP united with everything above the arrow's shoulder line (y < 187.5), like the CSS
/// clipPath (`ARROW_CLIP_PATH` + a rect up to LOOP_OPEN_ABOVE). Same winding for both so a non-zero clip unions them.
let LOOP_CLIP: CGPath = {
    let p = CGMutablePath()
    p.addPath(ARROW_CLIP)
    var corners = [CGPoint(x: -500, y: -500), CGPoint(x: 900, y: -500), CGPoint(x: 900, y: 187.5), CGPoint(x: -500, y: 187.5)]
    if signedArea(polygonPath(corners)) * signedArea(ARROW_CLIP) < 0 { corners.reverse() }
    p.addPath(polygonPath(corners))
    return p
}()

// MARK: - Small geometry helpers

func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
func unit(_ a: CGPoint) -> CGPoint { let l = hypot(a.x, a.y); return CGPoint(x: a.x / l, y: a.y / l) }

/// Offsets every edge of a convex polygon inwards by `d` and re-intersects the edges.
func insetConvex(_ pts: [CGPoint], by d: CGFloat) -> [CGPoint] {
    let n = pts.count
    let cen = pts.reduce(CGPoint.zero, +) * (1 / CGFloat(n))
    var lines: [(p: CGPoint, dir: CGPoint)] = []
    for i in 0..<n {
        let a = pts[i], b = pts[(i + 1) % n]
        let dir = unit(b - a)
        var nrm = CGPoint(x: -dir.y, y: dir.x)
        if dot(nrm, cen - a) < 0 { nrm = nrm * -1 }
        lines.append((a + nrm * d, dir))
    }
    return (0..<n).map { i in
        let l0 = lines[(i - 1 + n) % n], l1 = lines[i]
        let t = cross(l1.p - l0.p, l1.dir) / cross(l0.dir, l1.dir)
        return l0.p + l0.dir * t
    }
}

func polygonPath(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts)
    p.closeSubpath()
    return p
}

func scaled(_ path: CGPath, by k: CGFloat, about c: CGPoint) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: k, y: k).translatedBy(x: -c.x, y: -c.y)
    return path.copy(using: &t) ?? path
}

func hex(_ v: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { hex($0.1) } as CFArray, locations: stops.map { $0.0 })!
}

// MARK: - Mark landmarks (logo space)

/// Where the mono mark is centred: the middle of the arrow's bounding box (x 12..352, y 13..333).
let MARK_CENTER = CGPoint(x: 182, y: 173)
/// The hexagonal hole / box centre.
let BOX_CENTER = CGPoint(x: 183, y: 216.2)
// The cube's outer corners, read off the real face paths (top vertex, both upper corners, centre, base corners).
let CUBE_T = CGPoint(x: 185.5, y: 138.5)
let CUBE_UR = CGPoint(x: 270.93, y: 171.8)
let CUBE_C = CGPoint(x: 184, y: 204.4)
let CUBE_UL = CGPoint(x: 94.98, y: 171.75)
let CUBE_B = CGPoint(x: 183, y: 294)
let CUBE_LL = CGPoint(x: 94.98, y: 256.2)
let CUBE_LR = CGPoint(x: 270.93, y: 256.1)

// MARK: - Monochrome (template) glyphs

/// Menu bar canvas in points. Every state and frame uses the same canvas so the app can swap them freely.
let CW: CGFloat = 20
let CH: CGFloat = 20

enum ArrowMode { case solid, outline, none }
enum BoxMode { case faces, openTop, outline, solid, none }

struct Spec {
    var arrow: ArrowMode = .solid
    var box: BoxMode = .faces
    var arrowDy: CGFloat = 0        // logo units, negative = up
    var arrowAlpha: CGFloat = 1
    var clipArrow = false           // busy frames: clip the moving arrow to the mark, like LogoMark `loop`
    var s: CGFloat = 0.053          // points per logo unit
    var holeK: CGFloat = 0.95       // hole scale about the box centre (smaller = thicker arrow ring)
    var boxB: CGFloat = 0.90        // box scale about the box centre
    var gap: CGFloat = 0.8          // gap between box faces, pt
    var round: CGFloat = 0.4        // corner rounding of the faces, pt
    var lw: CGFloat = 1.2           // stroke weight of outline parts, pt
    var oy: CGFloat = -0.5          // vertical offset of the whole mark, pt (up positive): headroom for the raised arrow
}

/// Draws one glyph in pure `ink` on the (0,0)-(CW,CH) canvas. y-up context, template-friendly: no colour.
func drawGlyph(_ ctx: CGContext, _ g: Spec, ink: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: CW / 2, y: CH / 2 + g.oy)
    ctx.scaleBy(x: g.s, y: -g.s)
    ctx.translateBy(x: -MARK_CENTER.x, y: -MARK_CENTER.y)
    ctx.setFillColor(ink)
    ctx.setStrokeColor(ink)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    let hole = scaled(HOLE, by: g.holeK, about: BOX_CENTER)
    let big = CGRect(x: -500, y: -500, width: 1400, height: 1400)

    // --- arrow (behind the box)
    if g.arrow != .none {
        ctx.saveGState()
        let grouped = g.arrowAlpha < 0.999 || g.clipArrow
        if grouped { ctx.setAlpha(g.arrowAlpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        switch g.arrow {
        case .solid:
            func pass(_ clip: () -> Void) {
                ctx.saveGState()
                let cut = CGMutablePath()
                cut.addRect(big)
                cut.addPath(hole)
                ctx.addPath(cut)
                ctx.clip(using: .evenOdd)
                clip()
                ctx.translateBy(x: 0, y: g.arrowDy)
                ctx.addPath(ARROW)
                ctx.fillPath()
                ctx.restoreGState()
            }
            if g.clipArrow {
                // LogoMark `loop`: clipped to the mark's silhouette, open above the arrow's shoulders (y < 187.5),
                // as one union path so there is no anti-aliasing seam where the two parts meet.
                pass { ctx.addPath(LOOP_CLIP); ctx.clip() }
            } else {
                pass {}
            }
        case .outline:
            ctx.translateBy(x: 0, y: g.arrowDy)
            ctx.setLineWidth(g.lw / g.s)
            ctx.addPath(ARROW)
            ctx.strokePath()
        case .none:
            break
        }
        if grouped { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    // --- box (in front)
    let b = g.boxB
    func sc(_ p: CGPoint) -> CGPoint { BOX_CENTER + (p - BOX_CENTER) * b }
    switch g.box {
    case .faces, .openTop:
        let gapU = g.gap / g.s, rU = g.round / g.s
        let polys = [[CUBE_UL, CUBE_C, CUBE_B, CUBE_LL], [CUBE_C, CUBE_UR, CUBE_LR, CUBE_B]]
        for poly in polys {
            let q = insetConvex(poly.map(sc), by: (gapU + rU) / 2)
            ctx.setLineWidth(rU)
            ctx.addPath(polygonPath(q))
            ctx.drawPath(using: .fillStroke)
        }
        let top = [CUBE_T, CUBE_UR, CUBE_C, CUBE_UL].map(sc)
        if g.box == .faces {
            ctx.setLineWidth(rU)
            ctx.addPath(polygonPath(insetConvex(top, by: (gapU + rU) / 2)))
            ctx.drawPath(using: .fillStroke)
        } else {
            // open lid: the top face is only an outline, like an open box waiting to be filled
            let w = g.lw / g.s
            ctx.setLineWidth(w)
            ctx.addPath(polygonPath(insetConvex(top, by: gapU / 2 + w / 2)))
            ctx.strokePath()
        }
    case .solid:
        let rU = g.round / g.s
        let hexa = [CUBE_T, CUBE_UR, CUBE_LR, CUBE_B, CUBE_LL, CUBE_UL].map(sc)
        ctx.setLineWidth(rU)
        ctx.addPath(polygonPath(insetConvex(hexa, by: rU / 2)))
        ctx.drawPath(using: .fillStroke)
    case .outline:
        let w = g.lw / g.s
        let hexa = insetConvex([CUBE_T, CUBE_UR, CUBE_LR, CUBE_B, CUBE_LL, CUBE_UL].map(sc), by: w / 2)
        ctx.setLineWidth(w)
        ctx.addPath(polygonPath(hexa))
        ctx.strokePath()
        // the Y of the cube: centre to the two upper corners and to the base
        let c = sc(CUBE_C)
        ctx.move(to: hexa[5]); ctx.addLine(to: c); ctx.addLine(to: hexa[1])
        ctx.move(to: c); ctx.addLine(to: hexa[3])
        ctx.strokePath()
    case .none:
        break
    }
    ctx.restoreGState()
}

// MARK: - Busy loop timing

/// The website's loop (LogoMark.module.css `lift`, 1.5 s): the arrow rises from behind the box with a strong
/// ease-out (translateY 150 -> 0, opacity 0 -> 1), rests, then leaves through the top accelerating
/// (0 -> -90, opacity 1 -> 0). At 12 fps the web curve's rise would be over in two frames and read as a
/// blink, so the same three beats are re-timed on a frame grid: `rise` frames of ease-out, `rest` frames
/// held, the remaining frames an ease-in lift-off with fade. Translate distances and the clip are the web's.
let BUSY_RISE = 5
let BUSY_REST = 2

func busySample(frame i: Int, of n: Int) -> (dy: CGFloat, alpha: CGFloat) {
    func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
    func easeIn(_ t: Double) -> Double { t * t * t * 0.6 + t * t * 0.4 }
    if i < BUSY_RISE {
        let t = (Double(i) + 0.5) / Double(BUSY_RISE)
        return (CGFloat(150 * (1 - easeOut(t))), CGFloat(easeOut(min(1, t / 0.35))))
    }
    if i < BUSY_RISE + BUSY_REST { return (0, 1) }
    let exitN = n - BUSY_RISE - BUSY_REST
    let t = (Double(i - BUSY_RISE - BUSY_REST) + 0.5) / Double(exitN)
    return (CGFloat(-90 * easeIn(t)), CGFloat(1 - easeIn(t)))
}

// MARK: - Designs (variants explored; one is chosen below)

enum Design: String, CaseIterable {
    case a = "A  solid ring arrow + outline box"
    case b = "B  solid ring arrow + faceted box"
    case c = "C  outline arrow + faceted box"

    func idle() -> Spec {
        switch self {
        case .a: return Spec(arrow: .solid, box: .outline, holeK: 0.92, boxB: 0.90, lw: 1.1)
        case .b: return Spec(arrow: .solid, box: .faces)
        case .c: return Spec(arrow: .outline, box: .faces, holeK: 1, boxB: 1.0, gap: 0.85, lw: 1.2)
        }
    }
}

let chosen = Design.b

struct State {
    let name: String
    let spec: Spec
}

func menuBarStates() -> [State] {
    let idle = chosen.idle()
    var out = idle; out.arrow = .outline; out.box = .outline; out.holeK = 1; out.boxB = 0.92; out.lw = 1.1
    // dropTarget: the arrow lifts out of the hole (the ring's base opens) and the box opens its lid
    var drop = idle; drop.arrowDy = -34; drop.box = .openTop; drop.lw = 1.1
    return [State(name: "idle", spec: idle), State(name: "signedOut", spec: out), State(name: "dropTarget", spec: drop)]
}

let BUSY_FRAMES = 12
let BUSY_FPS = 12

func busyStates() -> [State] {
    (0..<BUSY_FRAMES).map { i in
        let (dy, a) = busySample(frame: i, of: BUSY_FRAMES)
        var s = chosen.idle()
        s.arrowDy = dy; s.arrowAlpha = a; s.clipArrow = true
        return State(name: String(format: "busy-%02d", i + 1), spec: s)
    }
}

// MARK: - Output: PDF + bitmap

let blackInk = CGColor(gray: 0, alpha: 1)

func writePDF(_ url: URL, draw: (CGContext) -> Void) {
    var box = CGRect(x: 0, y: 0, width: CW, height: CH)
    let info: [CFString: Any] = [kCGPDFContextTitle: "Upload the File menu bar icon"]
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { fatalError("pdf \(url)") }
    ctx.beginPDFPage(nil)
    draw(ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

func makeBitmap(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("png \(url)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("png finalize \(url)") }
}

func renderGlyphPNG(_ g: Spec, scale: Int) -> CGImage {
    let ctx = makeBitmap(width: Int(CW) * scale, height: Int(CH) * scale)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    drawGlyph(ctx, g, ink: blackInk)
    return ctx.makeImage()!
}

// MARK: - Review sheets (all drawn here)

typealias GlyphDraw = (CGContext, CGColor, Int) -> Void   // ctx, ink, pixel scale; canvas (0,0)-(CW,CH)

let barLight = CGColor(srgbRed: 0.925, green: 0.925, blue: 0.935, alpha: 1)
let barDark = CGColor(srgbRed: 0.16, green: 0.16, blue: 0.175, alpha: 1)
let sheetBG = CGColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)

/// Menu bar ink: the system draws template images in the label colour (about 85% black / 90% white).
func inkFor(dark: Bool) -> (CGColor, CGFloat) { dark ? (CGColor(gray: 1, alpha: 1), 0.9) : (CGColor(gray: 0, alpha: 1), 0.85) }

func glyphDraw(_ g: Spec) -> GlyphDraw { { ctx, ink, _ in drawGlyph(ctx, g, ink: ink) } }

/// SF Symbol as a tinted bitmap, drawn centred on a CW x CH canvas.
func symbolDraw(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> GlyphDraw {
    { ctx, ink, scale in
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let w = Int(ceil(img.size.width)) + 2, h = Int(ceil(img.size.height)) + 2
        let bmp = makeBitmap(width: w * scale, height: h * scale)
        bmp.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let gc = NSGraphicsContext(cgContext: bmp, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        img.draw(in: NSRect(x: 1, y: 1, width: img.size.width, height: img.size.height), from: .zero,
                 operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bmp.setBlendMode(.sourceIn)
        bmp.setFillColor(ink)
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = bmp.makeImage() else { return }
        ctx.draw(cg, in: CGRect(x: (CW - CGFloat(w)) / 2, y: (CH - CGFloat(h)) / 2, width: CGFloat(w), height: CGFloat(h)))
    }
}

/// A menu bar strip bitmap: `wPt` x 22 pt at `scale`, glyphs placed left to right, `pitch` apart, centred vertically.
func menuBarCell(wPt: CGFloat, scale: Int, dark: Bool, glyphs: [GlyphDraw], pitch: CGFloat) -> CGImage {
    let hPt: CGFloat = 22
    let ctx = makeBitmap(width: Int(wPt) * scale, height: Int(hPt) * scale)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.setFillColor(dark ? barDark : barLight)
    ctx.fill(CGRect(x: 0, y: 0, width: wPt, height: hPt))
    let (ink, alpha) = inkFor(dark: dark)
    let totalW = pitch * CGFloat(glyphs.count)
    let x0 = (wPt - totalW) / 2 + (pitch - CW) / 2
    for (i, d) in glyphs.enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: x0 + CGFloat(i) * pitch, y: (hPt - CH) / 2)
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        d(ctx, ink, scale)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func drawText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, color: NSColor = .black,
              weight: NSFont.Weight = .regular) {
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
    ])
    NSGraphicsContext.restoreGraphicsState()
}

struct SheetRow {
    let label: String
    let glyphs: [GlyphDraw]
}

/// Table: one row per entry; columns light 1x, dark 1x, light 2x, dark 2x, then x8 magnified 1x light/dark.
func tableSheet(title: String, rows: [SheetRow], out: URL) {
    let stripW: CGFloat = 40, rowH: CGFloat = 22 * 8 + 12
    let labelW: CGFloat = 230
    let zoom = 8
    let colX: [CGFloat] = [labelW, labelW + 60, labelW + 120, labelW + 210]
    let zoomX0 = labelW + 310
    let width = Int(zoomX0 + stripW * CGFloat(zoom) * 3 + 40)
    let top: CGFloat = 40
    let height = Int(top + CGFloat(rows.count) * rowH + 20)
    let ctx = makeBitmap(width: width, height: height)
    ctx.setFillColor(sheetBG); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawText(ctx, title, x: 12, y: CGFloat(height) - 24, size: 14, weight: .semibold)
    let heads = ["light 1x", "dark 1x", "light 2x", "dark 2x", "light 1x  x8 zoom", "light 2x  x4 zoom", "dark 2x  x4 zoom"]
    let headX = colX + [zoomX0, zoomX0 + stripW * CGFloat(zoom), zoomX0 + stripW * CGFloat(zoom) * 2]
    for (i, h) in heads.enumerated() { drawText(ctx, h, x: headX[i], y: CGFloat(height) - 36, size: 10, color: .darkGray) }
    for (r, row) in rows.enumerated() {
        let yTop = CGFloat(height) - top - CGFloat(r) * rowH
        let yMid = yTop - rowH / 2
        drawText(ctx, row.label, x: 12, y: yMid - 5, size: 11)
        func place(_ img: CGImage, x: CGFloat, zoom z: Int, scale: Int) {
            let w = CGFloat(img.width) / CGFloat(scale) * CGFloat(z), h = CGFloat(img.height) / CGFloat(scale) * CGFloat(z)
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: x, y: yMid - h / 2, width: w, height: h))
        }
        let c1l = menuBarCell(wPt: stripW, scale: 1, dark: false, glyphs: row.glyphs, pitch: 28)
        let c1d = menuBarCell(wPt: stripW, scale: 1, dark: true, glyphs: row.glyphs, pitch: 28)
        let c2l = menuBarCell(wPt: stripW, scale: 2, dark: false, glyphs: row.glyphs, pitch: 28)
        let c2d = menuBarCell(wPt: stripW, scale: 2, dark: true, glyphs: row.glyphs, pitch: 28)
        place(c1l, x: colX[0], zoom: 1, scale: 1)
        place(c1d, x: colX[1], zoom: 1, scale: 1)
        place(c2l, x: colX[2], zoom: 1, scale: 1)   // 2x pixels shown 1:1 = what a Retina screen resolves
        place(c2d, x: colX[3], zoom: 1, scale: 1)
        place(c1l, x: zoomX0, zoom: zoom, scale: 1)
        place(c2l, x: zoomX0 + stripW * CGFloat(zoom), zoom: zoom / 2, scale: 1)
        place(c2d, x: zoomX0 + stripW * CGFloat(zoom) * 2, zoom: zoom / 2, scale: 1)
    }
    writePNG(ctx.makeImage()!, to: out)
}

func busySheet(frames: [State], out: URL) {
    let pitch: CGFloat = 26
    let stripW = pitch * CGFloat(frames.count) + 12
    let labelW: CGFloat = 130
    let zoom = 3
    let width = Int(labelW + stripW * CGFloat(zoom) + 40)
    let rowsSpec: [(String, Int, Bool, Int)] = [("light 1x", 1, false, 1), ("dark 1x", 1, true, 1), ("light 2x (px 1:1)", 2, false, 1),
                                                 ("dark 2x (px 1:1)", 2, true, 1), ("light 1x  x3", 1, false, 3), ("dark 1x  x3", 1, true, 3),
                                                 ("light 2x  x2", 2, false, 2), ("dark 2x  x2", 2, true, 2)]
    var heights: [CGFloat] = []
    for r in rowsSpec { heights.append(22 * CGFloat(r.3) * (r.1 == 2 && r.3 == 1 ? 2 : 1) + 14) }
    let height = Int(heights.reduce(0, +) + 70)
    let ctx = makeBitmap(width: width, height: height)
    ctx.setFillColor(sheetBG); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawText(ctx, "Busy frames 1...\(frames.count) at \(BUSY_FPS) fps, loop of \(Double(frames.count) / Double(BUSY_FPS)) s", x: 12,
             y: CGFloat(height) - 24, size: 14, weight: .semibold)
    var y = CGFloat(height) - 40
    let glyphs = frames.map { glyphDraw($0.spec) }
    for (i, r) in rowsSpec.enumerated() {
        let h = heights[i]
        y -= h
        let cell = menuBarCell(wPt: stripW, scale: r.1, dark: r.2, glyphs: glyphs, pitch: pitch)
        let w = CGFloat(cell.width) / CGFloat(r.1) * CGFloat(r.3), ch = CGFloat(cell.height) / CGFloat(r.1) * CGFloat(r.3)
        ctx.interpolationQuality = .none
        if r.1 == 2 && r.3 == 1 {
            ctx.draw(cell, in: CGRect(x: labelW, y: y + 7, width: CGFloat(cell.width), height: CGFloat(cell.height)))
        } else {
            ctx.draw(cell, in: CGRect(x: labelW, y: y + 7, width: w, height: ch))
        }
        drawText(ctx, r.0, x: 12, y: y + 7 + ch / 2 - 5, size: 11)
    }
    writePNG(ctx.makeImage()!, to: out)
}

/// A believable menu bar: neighbours are real SF Symbols so weight and size can be judged in context.
func contextSheet(glyph: Spec, out: URL) {
    let scale = 2
    let wPt: CGFloat = 340, hPt: CGFloat = 22
    let width = Int(wPt) * scale, height = (Int(hPt) * 2 + 30) * scale
    let ctx = makeBitmap(width: width, height: height)
    ctx.setFillColor(sheetBG); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    for (row, dark) in [false, true].enumerated() {
        let y0 = CGFloat(row) * (hPt + 10) + 6
        ctx.setFillColor(dark ? barDark : barLight)
        ctx.fill(CGRect(x: 0, y: y0, width: wPt, height: hPt))
        let (ink, alpha) = inkFor(dark: dark)
        var x: CGFloat = 12
        let names = ["wifi", "battery.100", "magnifyingglass", "switch.2"]
        let items: [GlyphDraw] = [glyphDraw(glyph)] + names.map { symbolDraw($0, pointSize: 14, weight: .regular) }
        for (i, d) in items.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y0 + (hPt - CH) / 2)
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            d(ctx, ink, scale)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            x += (i == 0 ? 28 : 30)
        }
        drawText(ctx, "Mon 16 Nov  9:41", x: wPt - 110, y: y0 + 5, size: 13,
                 color: dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85))
    }
    writePNG(ctx.makeImage()!, to: out)
}

// MARK: - App icon (full colour, macOS icon grid: 824 pt tile inside 1024)

func fillGradient(_ ctx: CGContext, path: CGPath, stops: [(CGFloat, UInt32)], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(stops), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// The website's logo, in colour, in its own pixel space (y down): the layers and colours of LogoArt.
func drawColourMark(_ ctx: CGContext) {
    // arrow, with the transparent hexagon cut out around the box
    ctx.saveGState()
    let cut = CGMutablePath()
    cut.addRect(CGRect(x: -50, y: -50, width: 470, height: 450))
    cut.addPath(HOLE)
    ctx.addPath(cut)
    ctx.clip(using: .evenOdd)
    fillGradient(ctx, path: ARROW, stops: ARROW_STOPS, from: CGPoint(x: 183, y: 7), to: CGPoint(x: 183, y: 335))
    ctx.setStrokeColor(hex(0x002270, alpha: 0.45))
    ctx.setLineWidth(1)
    ctx.addPath(ARROW_EDGE)
    ctx.strokePath()
    ctx.restoreGState()
    // box
    ctx.setFillColor(hex(0xffffff))
    ctx.addPath(BAND); ctx.fillPath()
    fillGradient(ctx, path: LEFT_FACE, stops: LEFT_STOPS, from: CGPoint(x: 95, y: 262), to: CGPoint(x: 185, y: 172))
    ctx.setLineWidth(1)
    ctx.setStrokeColor(hex(0xe8480c)); ctx.addPath(LEFT_EDGE); ctx.strokePath()
    fillGradient(ctx, path: RIGHT_FACE, stops: RIGHT_STOPS, from: CGPoint(x: 184, y: 185), to: CGPoint(x: 205, y: 297))
    ctx.setStrokeColor(hex(0xf58a1c)); ctx.addPath(RIGHT_EDGE); ctx.strokePath()
    fillGradient(ctx, path: TOP_FACE, stops: TOP_STOPS, from: CGPoint(x: 175.4, y: 181.6), to: CGPoint(x: 191.2, y: 147.4))
    ctx.setStrokeColor(hex(0xfc7a05)); ctx.addPath(TOP_EDGE); ctx.strokePath()
}

/// Draws the whole app icon on a 1024 x 1024 canvas (y up).
func drawAppIcon(_ ctx: CGContext) {
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 1. drop shadow of the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * shadowScale), blur: 26 * shadowScale, color: CGColor(gray: 0, alpha: 0.30))
    ctx.setFillColor(hex(0xe9eef7))
    ctx.addPath(tile); ctx.fillPath()
    ctx.restoreGState()

    // 2. tile: cool near-white, a touch darker at the bottom so the white lid band of the box stays visible
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, 0xffffff), (0.55, 0xf2f5fb), (1, 0xdde5f3)]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // inner rim
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
    ctx.setLineWidth(3)
    ctx.addPath(tile); ctx.strokePath()
    ctx.restoreGState()

    // 3. the mark: arrow bbox (340 x 320 logo units) centred on the tile. A soft shadow for the whole group
    //    (CG shadow offsets/blur are in device pixels, so scale them with the render size).
    let s: CGFloat = 1.62
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -7 * shadowScale), blur: 12 * shadowScale, color: hex(0x0b2a66, alpha: 0.20))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.translateBy(x: 512, y: 512 + 2)
    ctx.scaleBy(x: s, y: -s)
    ctx.translateBy(x: -MARK_CENTER.x, y: -MARK_CENTER.y)
    drawColourMark(ctx)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

var shadowScale: CGFloat = 1

func renderAppIcon(pixels: Int) -> CGImage {
    let ctx = makeBitmap(width: pixels, height: pixels)
    shadowScale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: shadowScale, y: shadowScale)
    drawAppIcon(ctx)
    return ctx.makeImage()!
}

func appIconSheet(out: URL) {
    let sizes = [16, 32, 128, 512]
    let pad = 24
    let panelW = sizes.reduce(0, +) + pad * (sizes.count + 1) + 140
    let panelH = 512 + 2 * pad + 20
    let ctx = makeBitmap(width: panelW, height: panelH * 2)
    for (row, dark) in [false, true].enumerated() {
        let y0 = (1 - row) * panelH   // light on top
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                              : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: y0, width: panelW, height: panelH))
        var x = pad
        for s in sizes {
            ctx.interpolationQuality = .none
            ctx.draw(renderAppIcon(pixels: s), in: CGRect(x: x, y: y0 + pad + 20, width: s, height: s))
            drawText(ctx, "\(s)", x: CGFloat(x), y: CGFloat(y0 + pad), size: 11,
                     color: dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.7))
            x += s + pad
        }
        // magnified 16 and 32 (x6 / x3) to judge small sizes
        let z16 = renderAppIcon(pixels: 16), z32 = renderAppIcon(pixels: 32)
        ctx.interpolationQuality = .none
        ctx.draw(z16, in: CGRect(x: x, y: y0 + pad + 20 + 400, width: 96, height: 96))
        ctx.draw(z32, in: CGRect(x: x, y: y0 + pad + 20 + 280, width: 96, height: 96))
        drawText(ctx, "16 x6, 32 x3", x: CGFloat(x), y: CGFloat(y0 + pad + 20 + 260), size: 10,
                 color: dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.7))
    }
    writePNG(ctx.makeImage()!, to: out)
}

func writeAppIcon(repo: URL) throws {
    let fm = FileManager.default
    let iconset = repo.appendingPathComponent("build/AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    let files: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in files { writePNG(renderAppIcon(pixels: px), to: iconset.appendingPathComponent(name + ".png")) }
    let icns = repo.appendingPathComponent("Resources/AppIcon.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { fatalError("iconutil failed") }
}

// MARK: - Main

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.swift").path) else {
    FileHandle.standardError.write(Data("run from the uploadthefile-mac repo root\n".utf8)); exit(64)
}
let iconsDir = repo.appendingPathComponent("Resources/MenuBarIcons", isDirectory: true)
let reviewDir = repo.appendingPathComponent("build/icon-review", isDirectory: true)
try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: reviewDir, withIntermediateDirectories: true)

// Variant exploration sheet (idle of each design, with the SF Symbol for weight)
tableSheet(title: "Menu bar variants (idle) vs SF Symbol", rows:
    [SheetRow(label: "SF  square.and.arrow.up  regular 15pt", glyphs: [symbolDraw("square.and.arrow.up", pointSize: 15, weight: .regular)]),
     SheetRow(label: "SF  square.and.arrow.up  medium 15pt", glyphs: [symbolDraw("square.and.arrow.up", pointSize: 15, weight: .medium)])]
    + Design.allCases.map { SheetRow(label: $0.rawValue, glyphs: [glyphDraw($0.idle())]) },
    out: reviewDir.appendingPathComponent("variants.png"))

// Tuning of the chosen design (proportions of ring / gaps / box size)
func tuned(_ f: (inout Spec) -> Void) -> Spec { var s = chosen.idle(); f(&s); return s }
tableSheet(title: "Tuning of design B", rows: [
    SheetRow(label: "B* chosen: s.053 hole.95 box.90 gap.80", glyphs: [glyphDraw(tuned { _ in })]),
    SheetRow(label: "B1 s.056 hole.95 box.90 gap.80", glyphs: [glyphDraw(tuned { $0.s = 0.056; $0.holeK = 0.95; $0.boxB = 0.90; $0.gap = 0.8; $0.round = 0.4 })]),
    SheetRow(label: "B2 s.056 hole.97 box.93 gap.75", glyphs: [glyphDraw(tuned { $0.s = 0.056; $0.holeK = 0.97; $0.boxB = 0.93; $0.gap = 0.75; $0.round = 0.4 })]),
    SheetRow(label: "B3 s.056 hole.97 box.94 gap1.0", glyphs: [glyphDraw(tuned { $0.s = 0.056; $0.holeK = 0.97; $0.boxB = 0.94; $0.gap = 1.0; $0.round = 0.3 })]),
    SheetRow(label: "B4 s.058 hole.99 box.95 gap.9", glyphs: [glyphDraw(tuned { $0.s = 0.058; $0.holeK = 0.99; $0.boxB = 0.95; $0.gap = 0.9; $0.round = 0.3 })]),
], out: reviewDir.appendingPathComponent("tuning.png"))

// Final states
let states = menuBarStates()
let busy = busyStates()
for st in states + busy {
    let base = "MenuBarIcon-" + st.name
    writePDF(iconsDir.appendingPathComponent(base + ".pdf")) { drawGlyph($0, st.spec, ink: blackInk) }
    writePNG(renderGlyphPNG(st.spec, scale: 1), to: iconsDir.appendingPathComponent(base + ".png"))
    writePNG(renderGlyphPNG(st.spec, scale: 2), to: iconsDir.appendingPathComponent(base + "@2x.png"))
}

// Round-trip check: load every PDF the way the app will (NSImage), rasterise it and compare with the direct
// render: size must be CW x CH pt, every pixel must be pure black (premultiplied r=g=b=0), alpha must agree.
func verifyPDFs(_ all: [State]) {
    var worst = 0, maxColour = 0
    for st in all {
        let url = iconsDir.appendingPathComponent("MenuBarIcon-" + st.name + ".pdf")
        guard let img = NSImage(contentsOf: url), img.size == NSSize(width: CW, height: CH) else { fatalError("bad pdf size \(st.name)") }
        let scale = 4
        let w = Int(CW) * scale, h = Int(CH) * scale
        let a = makeBitmap(width: w, height: h)
        let gc = NSGraphicsContext(cgContext: a, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let b = makeBitmap(width: w, height: h)
        b.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawGlyph(b, st.spec, ink: blackInk)
        let pa = a.data!.assumingMemoryBound(to: UInt8.self), pb = b.data!.assumingMemoryBound(to: UInt8.self)
        var stWorst = 0, sum = 0
        for y in 0..<h {
            for x in 0..<w {
                let ia = y * a.bytesPerRow + x * 4, ib = y * b.bytesPerRow + x * 4
                maxColour = max(maxColour, Int(pa[ia]), Int(pa[ia + 1]), Int(pa[ia + 2]))
                let d = abs(Int(pa[ia + 3]) - Int(pb[ib + 3]))
                stWorst = max(stWorst, d); sum += d
            }
        }
        worst = max(worst, stWorst)
        if st.name == "busy-06" {   // look at what the PDF really renders as, next to the direct render
            let both = makeBitmap(width: w * 2 + 10, height: h)
            both.setFillColor(CGColor(gray: 1, alpha: 1)); both.fill(CGRect(x: 0, y: 0, width: w * 2 + 10, height: h))
            both.draw(a.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
            both.draw(b.makeImage()!, in: CGRect(x: w + 10, y: 0, width: w, height: h))
            writePNG(both.makeImage()!, to: reviewDir.appendingPathComponent("pdf-vs-direct-busy-06.png"))
        }
        print("  \(st.name): max alpha diff \(stWorst), mean \(String(format: "%.2f", Double(sum) / Double(w * h)))")
    }
    print("pdf check: \(all.count) files, max colour channel \(maxColour) (0 = pure black), max alpha diff vs direct render \(worst)/255")
}
verifyPDFs(states + busy)

var reviewRows: [SheetRow] = [
    SheetRow(label: "SF  square.and.arrow.up  regular 15pt", glyphs: [symbolDraw("square.and.arrow.up", pointSize: 15, weight: .regular)]),
    SheetRow(label: "SF  square.and.arrow.up  medium 15pt", glyphs: [symbolDraw("square.and.arrow.up", pointSize: 15, weight: .medium)]),
]
reviewRows += states.map { SheetRow(label: $0.name, glyphs: [glyphDraw($0.spec)]) }
tableSheet(title: "Upload the File menu bar icon states (template, drawn at real size)", rows: reviewRows,
           out: reviewDir.appendingPathComponent("menubar-review.png"))
busySheet(frames: busy, out: reviewDir.appendingPathComponent("menubar-busy-review.png"))
contextSheet(glyph: states[0].spec, out: reviewDir.appendingPathComponent("menubar-context.png"))

// App icon
try writeAppIcon(repo: repo)
appIconSheet(out: reviewDir.appendingPathComponent("appicon-review.png"))

// The full-colour mark itself (vector), for the app's own UI: the popover header and the
// signed-out screen. Same layers and colours as the website's LogoMark, in its 367 x 345 space.
do {
    let url = repo.appendingPathComponent("Resources/BrandMark.pdf")
    var box = CGRect(x: 0, y: 0, width: 367, height: 345)
    let info: [CFString: Any] = [kCGPDFContextTitle: "upload.tf logo"]
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { fatalError("pdf \(url)") }
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: 345)
    ctx.scaleBy(x: 1, y: -1)   // drawColourMark works in the SVG's y-down space
    drawColourMark(ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}
print("done: \(states.count + busy.count) menu bar images, AppIcon.icns, BrandMark.pdf, review sheets in build/icon-review/")

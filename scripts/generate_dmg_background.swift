// Generates the DMG window background (Resources/dmg_background.png and @2x) in the style of
// a classic 2.x skin: beveled navy chassis, gold title-bar grips, green LCD panels, a
// spectrum analyzer, and the skin's own 5x6 pixel font (TEXT.BMP from Resources/base-2.91.wsz).
//
// Layout contract with scripts/build_dmg.sh: 660x400 pt window, 100 pt icons centred at
// (180, 200) for the app and (480, 200) for Applications (top-left origin).
//
// Run from the project root: swift scripts/generate_dmg_background.swift

import AppKit

let W: CGFloat = 660, H: CGFloat = 400
let appIcon = CGPoint(x: 180, y: 200)
let appsIcon = CGPoint(x: 480, y: 200)
let skinPath = "Resources/base-2.91.wsz"

// MARK: - Palette (sampled from the classic base skin)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let chassisTop = rgb(57, 57, 82), chassisBottom = rgb(33, 33, 49)
let bevelLight = rgb(98, 98, 128), bevelDark = rgb(14, 14, 22)
let gold = rgb(214, 182, 107), goldLight = rgb(255, 238, 178), goldDark = rgb(110, 84, 33)
let lcdBlack = rgb(0, 0, 0), lcdDots = rgb(24, 33, 41)
let lcdGreen = rgb(0, 226, 0), lcdDim = rgb(0, 96, 0)
let silverTop = rgb(150, 155, 172), silverBottom = rgb(112, 117, 136)
// VISCOLOR.TXT defaults: rows top (red) to bottom (green), plus the peak-dot colour.
let vis: [CGColor] = [
    rgb(239, 49, 16), rgb(206, 41, 16), rgb(214, 90, 0), rgb(214, 102, 0), rgb(214, 115, 0),
    rgb(198, 123, 8), rgb(222, 165, 24), rgb(214, 181, 33), rgb(189, 222, 41), rgb(148, 222, 33),
    rgb(41, 206, 16), rgb(50, 190, 16), rgb(57, 181, 16), rgb(49, 156, 8), rgb(41, 148, 0), rgb(24, 132, 8)
]
let visPeak = rgb(150, 150, 150)

// MARK: - Skin pixel font (TEXT.BMP: 5x6 glyphs)

/// Reads one file from the skin archive (unzip ships with macOS).
func skinFile(_ name: String) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    p.arguments = ["-p", "-C", skinPath, name]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 && !data.isEmpty ? data : nil
}

/// TEXT.BMP converted to an 8-bit luminance mask: lit glyph pixels paint, background doesn't.
let fontMask: CGImage? = {
    guard let data = skinFile("TEXT.BMP"), let src = NSBitmapImageRep(data: data)?.cgImage else { return nil }
    let w = src.width, h = src.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .none
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Threshold to crisp on/off pixels (the font's anti-aliased greys become solid).
    guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    for i in 0..<(w * h) { buf[i] = buf[i] > 40 ? 255 : 0 }
    return ctx.makeImage()
}()

let glyphs: [Character: (Int, Int)] = {
    var m: [Character: (Int, Int)] = [:]
    for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@".enumerated() { m[c] = (i, 0) }
    m[" "] = (30, 0)
    for (i, c) in "0123456789\u{2026}.:()-'!_+\\/[]^&%,=$#".enumerated() { m[c] = (i, 1) }
    for (i, c) in "\u{C5}\u{D6}\u{C4}?*".enumerated() { m[c] = (i, 2) }
    return m
}()

// MARK: - Drawing helpers (context is flipped: origin top-left, y down)

var cg: CGContext!

func fill(_ r: CGRect, _ c: CGColor) { cg.setFillColor(c); cg.fill(r) }

/// Classic player bevel: light top/left edge, dark bottom/right edge.
func bevel(_ r: CGRect, raised: Bool = true, width t: CGFloat = 1) {
    let (tl, br) = raised ? (bevelLight, bevelDark) : (bevelDark, bevelLight)
    fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: t), tl)
    fill(CGRect(x: r.minX, y: r.minY, width: t, height: r.height), tl)
    fill(CGRect(x: r.minX, y: r.maxY - t, width: r.width, height: t), br)
    fill(CGRect(x: r.maxX - t, y: r.minY, width: t, height: r.height), br)
}

func vGradient(_ r: CGRect, _ top: CGColor, _ bottom: CGColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    cg.saveGState(); cg.clip(to: r)
    cg.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
    cg.restoreGState()
}

/// Pixel text in the skin font, `px` points per font pixel, any colour. Returns the width.
@discardableResult
func pixelText(_ text: String, at p: CGPoint, px: CGFloat, color: CGColor, shadow: CGColor? = nil) -> CGFloat {
    guard let mask = fontMask else { return 0 }
    var x = p.x
    for ch in text.uppercased() {
        if let (gx, gy) = glyphs[ch], let g = mask.cropping(to: CGRect(x: gx * 5, y: gy * 6, width: 5, height: 6)) {
            for (offset, col) in [(shadow.map { _ in CGFloat(1) }, shadow), (CGFloat(0), color)] {
                guard let off = offset, let c = col else { continue }
                let r = CGRect(x: x + off * px, y: p.y + off * px, width: 5 * px, height: 6 * px)
                cg.saveGState()
                // Masks draw in unflipped space: flip locally around the glyph rect.
                cg.translateBy(x: 0, y: r.minY + r.maxY); cg.scaleBy(x: 1, y: -1)
                cg.clip(to: r, mask: g)
                cg.setFillColor(c); cg.fill(r)
                cg.restoreGState()
            }
        }
        x += 5 * px
    }
    return x - p.x
}

func textWidth(_ text: String, px: CGFloat) -> CGFloat { CGFloat(text.count) * 5 * px }

/// Gold "grip" stripes of the classic title bar: two bright lines with highlight and shadow.
func goldGrip(_ r: CGRect) {
    for line in 0..<2 {
        let y = r.minY + CGFloat(line) * 6
        fill(CGRect(x: r.minX, y: y, width: r.width, height: 1), goldLight)
        fill(CGRect(x: r.minX, y: y + 1, width: r.width, height: 2), gold)
        fill(CGRect(x: r.minX, y: y + 3, width: r.width, height: 1), goldDark)
    }
    fill(CGRect(x: r.minX, y: r.minY, width: 1, height: 10), goldDark)
    fill(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: 10), goldDark)
}

/// Black LCD well with the visualizer's dot grid.
func lcd(_ r: CGRect, dots: Bool = true) {
    bevel(r.insetBy(dx: -2, dy: -2), raised: false, width: 2)
    fill(r, lcdBlack)
    guard dots else { return }
    var y = r.minY + 1
    while y < r.maxY - 1 {
        var x = r.minX + 1
        while x < r.maxX - 1 { fill(CGRect(x: x, y: y, width: 1, height: 1), lcdDots); x += 2 }
        y += 2
    }
}

/// The ▶ glyph of the transport buttons, as pixel art.
func playTriangle(at p: CGPoint, height h: Int, px: CGFloat, color: CGColor) {
    for row in 0..<h {
        let half = min(row, h - 1 - row)
        fill(CGRect(x: p.x, y: p.y + CGFloat(row) * px, width: CGFloat(half + 1) * px, height: px), color)
    }
}

/// Spectrum bars in VISCOLOR colours with peak dots; `levels` 0...1, `rows` cells tall.
func spectrum(in r: CGRect, levels: [CGFloat], rows: Int, cell: CGFloat) {
    let barW = cell * 2
    for (i, level) in levels.enumerated() {
        let x = r.minX + CGFloat(i) * (barW + cell)
        guard x + barW <= r.maxX else { break }
        let lit = Int((level * CGFloat(rows)).rounded())
        for row in 0..<lit {
            let y = r.maxY - CGFloat(row + 1) * cell
            let c = vis[min(vis.count - 1, (rows - 1 - row) * vis.count / rows)]
            fill(CGRect(x: x, y: y, width: barW, height: cell), c)
        }
        let peakRow = min(rows - 1, lit + 1 + (i % 3 == 0 ? 1 : 0))
        fill(CGRect(x: x, y: r.maxY - CGFloat(peakRow + 1) * cell, width: barW, height: cell), visPeak)
    }
}

/// Raised silver plate (like the skin's transport buttons) under each Finder icon. Mid-grey so
/// Finder's icon label reads in both black (light mode) and white (dark mode).
func iconPlate(center c: CGPoint, caption: String) {
    let r = CGRect(x: c.x - 78, y: c.y - 66, width: 156, height: 160)
    fill(r.offsetBy(dx: 3, dy: 3), rgb(0, 0, 0, 0.35)) // drop shadow
    vGradient(r, silverTop, silverBottom)
    fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 2), rgb(214, 218, 232))
    fill(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height), rgb(214, 218, 232))
    fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2), rgb(40, 42, 56))
    fill(CGRect(x: r.maxX - 2, y: r.minY, width: 2, height: r.height), rgb(40, 42, 56))
    // Small LCD caption strip above the plate, like the skin's kbps/kHz readouts.
    let capW = textWidth(caption, px: 2) + 16
    let cap = CGRect(x: c.x - capW / 2, y: r.minY - 22, width: capW, height: 16)
    lcd(cap, dots: false)
    pixelText(caption, at: CGPoint(x: cap.minX + 8, y: cap.minY + 2), px: 2, color: lcdGreen)
}

// MARK: - Composition

func render(scale: CGFloat, to path: String) {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(false)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1) // top-left origin
    cg = ctx

    // Chassis with faint horizontal ribbing.
    vGradient(CGRect(x: 0, y: 0, width: W, height: H), chassisTop, chassisBottom)
    var y: CGFloat = 30
    while y < H { fill(CGRect(x: 0, y: y, width: W, height: 1), rgb(255, 255, 255, 0.025)); y += 3 }
    bevel(CGRect(x: 0, y: 0, width: W, height: H), width: 2)

    // Title bar: grips either side of a centred plaque.
    let title = "CLASSICAMP"
    let plaqueW = textWidth(title, px: 3) + 28
    fill(CGRect(x: 2, y: 2, width: W - 4, height: 26), rgb(30, 30, 46))
    goldGrip(CGRect(x: 14, y: 10, width: (W - plaqueW) / 2 - 22, height: 10))
    goldGrip(CGRect(x: (W + plaqueW) / 2 + 8, y: 10, width: (W - plaqueW) / 2 - 22, height: 10))
    pixelText(title, at: CGPoint(x: (W - textWidth(title, px: 3)) / 2, y: 6), px: 3,
              color: rgb(226, 228, 240), shadow: rgb(10, 10, 18))
    fill(CGRect(x: 2, y: 28, width: W - 4, height: 1), bevelDark)

    // Top display: track-style marquee + time + mini spectrum.
    let display = CGRect(x: 22, y: 40, width: W - 44, height: 54)
    lcd(display)
    playTriangle(at: CGPoint(x: display.minX + 12, y: display.minY + 12), height: 9, px: 2, color: lcdGreen)
    pixelText("00:42", at: CGPoint(x: display.minX + 34, y: display.minY + 10), px: 3, color: lcdGreen)
    pixelText("1. CLASSICAMP - DRAG ME INTO APPLICATIONS", at: CGPoint(x: display.minX + 12, y: display.minY + 35), px: 2, color: lcdGreen)
    pixelText("128 KBPS  44 KHZ  STEREO", at: CGPoint(x: display.minX + 128, y: display.minY + 14), px: 2, color: lcdDim)
    let mini: [CGFloat] = [0.55, 0.8, 0.95, 0.7, 0.85, 0.6, 0.75, 0.9, 0.65, 0.5, 0.7, 0.45, 0.6, 0.4, 0.5, 0.3, 0.35, 0.2]
    spectrum(in: CGRect(x: display.maxX - 168, y: display.minY + 6, width: 160, height: 42), levels: mini, rows: 14, cell: 3)

    // Icon plates and captions.
    iconPlate(center: appIcon, caption: "PLAYER")
    iconPlate(center: appsIcon, caption: "APPLICATIONS")

    // Arrow: three ▶ in an LCD between the plates, "DRAG & DROP" beneath.
    let arrowLCD = CGRect(x: 280, y: appIcon.y - 26, width: 100, height: 36)
    lcd(arrowLCD, dots: false)
    for i in 0..<3 {
        playTriangle(at: CGPoint(x: arrowLCD.minX + 18 + CGFloat(i) * 24, y: arrowLCD.minY + 7), height: 11, px: 2,
                     color: i == 2 ? lcdGreen : (i == 1 ? rgb(0, 168, 0) : lcdDim))
    }
    let dd = "DRAG & DROP"
    pixelText(dd, at: CGPoint(x: arrowLCD.midX - textWidth(dd, px: 2) / 2, y: arrowLCD.maxY + 10), px: 2,
              color: rgb(226, 228, 240), shadow: rgb(10, 10, 18))

    // Bottom: full-width spectrum analyzer.
    let analyzer = CGRect(x: 22, y: 316, width: W - 44, height: 44)
    lcd(analyzer)
    let n = 68
    let levels: [CGFloat] = (0..<n).map { i in
        let t = CGFloat(i) / CGFloat(n)
        let base = 0.85 - 0.55 * t                                  // bass-heavy roll-off
        let wiggle = 0.18 * sin(CGFloat(i) * 0.9) + 0.12 * sin(CGFloat(i) * 2.3 + 1)
        return max(0.08, min(1, base + wiggle))
    }
    spectrum(in: analyzer.insetBy(dx: 6, dy: 4), levels: levels, rows: 12, cell: 3)

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: W, height: H) // 72 dpi at 1x, 144 dpi at 2x
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Generated: \(path) (\(pxW)x\(pxH))")
}

guard fontMask != nil else {
    FileHandle.standardError.write("Could not read TEXT.BMP from \(skinPath); run from the project root.\n".data(using: .utf8)!)
    exit(1)
}
render(scale: 1, to: "Resources/dmg_background.png")
render(scale: 2, to: "Resources/dmg_background@2x.png")

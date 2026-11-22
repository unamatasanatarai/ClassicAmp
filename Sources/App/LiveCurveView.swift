import AppKit

/// The EQ response graph (113x19), drawn from EQMAIN.BMP's graph background and line palette.
public final class LiveCurveView: SkinnedView {
    public var preamp: Float = 0.0 { didSet { if oldValue != preamp { needsDisplay = true } } }
    public var bands: [Float] = Array(repeating: 0.0, count: 10) { didSet { if oldValue != bands { needsDisplay = true } } }
    public var isEQEnabled: Bool = true { didSet { if oldValue != isEQEnabled { needsDisplay = true } } }

    /// Line colours read from the skin's strip, cached per EQMAIN.BMP image (a redraw happens on
    /// every EQ slider step; re-reading the strip would allocate a bitmap context each time).
    private var rowColorCache: (sheet: CGImage?, colors: [CGColor])?

    public override func mouseDown(with event: NSEvent) {
        (window as? BaseSkinnedWindow)?.handleTitleBarMouseDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let sheet = SkinEngine.shared.getCGImage(named: "EQMAIN.BMP")
        let w = bounds.width, h = bounds.height // 113 x 19

        if let sheet = sheet, sheet.height >= 313 {
            ctx.drawSprite(sheet, src: CGRect(x: 0, y: 294, width: 113, height: 19), dst: bounds)
        } else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(bounds)
        }

        // Preamp level line (EQMAIN 0,314 113x1).
        let preNorm = CGFloat((preamp + 12) / 24)
        let preY = ((1 - preNorm) * (h - 1)).rounded()
        if let sheet = sheet, sheet.height >= 315 {
            ctx.drawSprite(sheet, src: CGRect(x: 0, y: 314, width: 113, height: 1), dst: CGRect(x: 0, y: preY, width: w, height: 1))
        }

        guard bands.count >= 2 else { return }
        let values: [CGFloat] = isEQEnabled ? bands.map { CGFloat($0) } : Array(repeating: 0, count: bands.count)

        let rowColors = self.rowColors(for: sheet)

        // Catmull-Rom interpolation across the 10 band positions, one pixel per column.
        let n = values.count
        let span = w - 1
        var lastY: Int?
        for x in 0..<Int(w) {
            let pos = CGFloat(x) / span * CGFloat(n - 1)
            let i = min(n - 2, Int(pos))
            let t = pos - CGFloat(i)
            let p0 = values[max(0, i - 1)], p1 = values[i], p2 = values[i + 1], p3 = values[min(n - 1, i + 2)]
            let t2 = t * t, t3 = t2 * t
            let v = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
            let norm = max(0, min(1, (v + 12) / 24))
            let y = Int(((1 - norm) * (h - 1)).rounded())
            let lo = lastY.map { min($0, y) } ?? y
            let hi = lastY.map { max($0, y) } ?? y
            for r in lo...hi {
                ctx.setFillColor(rowColors[min(18, max(0, r))])
                ctx.fill(CGRect(x: x, y: r, width: 1, height: 1))
            }
            lastY = y
        }
    }

    private func rowColors(for sheet: CGImage?) -> [CGColor] {
        if let c = rowColorCache, c.sheet === sheet { return c.colors }
        // Line colours per row live in a 1x19 strip at (115, 294).
        var colors: [CGColor] = []
        if let sheet = sheet, sheet.width >= 116, sheet.height >= 313,
           let strip = sheet.cropping(to: CGRect(x: 115, y: 294, width: 1, height: 19)) {
            colors = LiveCurveView.pixelColors(of: strip)
        }
        if colors.count < 19 {
            colors = (0..<19).map { r in
                let t = CGFloat(r) / 18
                return NSColor(srgbRed: 1 - t * 0.6, green: 0.3 + t * 0.7, blue: 0.1, alpha: 1).cgColor
            }
        }
        rowColorCache = (sheet, colors)
        return colors
    }

    private static func pixelColors(of image: CGImage) -> [CGColor] {
        let h = image.height
        var data = [UInt8](repeating: 0, count: h * 4)
        guard let ctx = CGContext(data: &data, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: h))
        // Bitmap memory row 0 is the image's top row.
        return (0..<h).map { r in
            NSColor(srgbRed: CGFloat(data[r * 4]) / 255, green: CGFloat(data[r * 4 + 1]) / 255,
                    blue: CGFloat(data[r * 4 + 2]) / 255, alpha: 1).cgColor
        }
    }
}

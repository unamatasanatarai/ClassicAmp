import AppKit

public struct PleditColors {
    public var normalText: NSColor = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
    public var currentText: NSColor = NSColor.white
    public var normalBG: NSColor = NSColor.black
    public var selectedBG: NSColor = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.78, alpha: 1.0)
    public var fontName: String = "Arial"

    public init() {}
}

public struct VisColors {
    public var colors: [NSColor] = []

    public init() {
        // Default 24 classic visualizer colors
        let defaults: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0), (24, 33, 41), (239, 49, 16), (206, 41, 16), (214, 90, 0), (214, 102, 0),
            (214, 115, 0), (198, 123, 8), (222, 165, 24), (214, 181, 33), (189, 222, 41), (148, 222, 33),
            (41, 206, 16), (50, 190, 16), (57, 181, 16), (49, 156, 8), (41, 148, 0), (24, 132, 8),
            (255, 255, 255), (214, 214, 222), (181, 189, 189), (160, 170, 175), (148, 156, 165), (150, 150, 150)
        ]
        colors = defaults.map { NSColor(srgbRed: $0.0 / 255.0, green: $0.1 / 255.0, blue: $0.2 / 255.0, alpha: 1.0) }
    }
}

/// A fully parsed skin, built off the main thread and swapped in atomically.
public struct LoadedSkin {
    public var images: [String: CGImage]
    public var pledit: PleditColors
    public var vis: VisColors
    public var mainRegion: CGPath?
    public var eqRegion: CGPath?
}

public final class SkinEngine {
    public static let shared = SkinEngine()

    public enum SkinError: Error, CustomStringConvertible {
        case unreadable(String)
        case missingRequired(String)
        case archive(ZipArchive.ZipError)

        public var description: String {
            switch self {
            case .unreadable(let s): return "Cannot read skin: \(s)"
            case .missingRequired(let s): return "Skin is missing \(s)"
            case .archive(let e): return e.description
            }
        }
    }

    public private(set) var activeSkinURL: URL?
    public private(set) var pleditColors = PleditColors()
    public private(set) var visColors = VisColors()
    public private(set) var mainRegionPolygon: CGPath?
    public private(set) var eqRegionPolygon: CGPath?

    private var active: LoadedSkin?
    /// The bundled base skin: every bitmap missing from a custom skin falls back to it.
    private var base: LoadedSkin?
    private var glyphCache: [Character: CGImage] = [:]

    private init() {
        // Synchronous, in-memory, and it must not call out (no notifications, no run-loop spinning):
        // any observer touching `SkinEngine.shared` during this initializer would re-enter dispatch_once.
        if let skin = SkinEngine.takePreloadedBaseSkin() ?? AppConfig.bundledSkinURL.flatMap({ try? SkinEngine.buildSkin(at: $0) }) {
            base = skin
            install(skin, url: nil, notify: false)
        }
    }

    // MARK: - Preloading (overlaps skin decoding with AppKit start-up)

    private static let preloadGroup = DispatchGroup()
    private static var preloaded: LoadedSkin?
    private static var preloadStarted = false

    /// Call once at process start: decodes the base skin on a background queue.
    public static func preloadBaseSkin() {
        guard !preloadStarted, let url = AppConfig.bundledSkinURL else { return }
        preloadStarted = true
        preloadGroup.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            preloaded = try? buildSkin(at: url)
            preloadGroup.leave()
        }
    }

    private static func takePreloadedBaseSkin() -> LoadedSkin? {
        guard preloadStarted else { return nil }
        preloadGroup.wait()
        defer { preloaded = nil }
        return preloaded
    }

    // MARK: - Loading

    public func loadDefaultSkin() {
        if base == nil, let url = AppConfig.bundledSkinURL, let skin = try? SkinEngine.buildSkin(at: url) {
            base = skin
        }
        if let base = base {
            install(base, url: nil)
        }
    }

    /// Synchronous load. Returns false (keeping the current skin) on any failure.
    @discardableResult
    public func loadSkin(at url: URL) -> Bool {
        do {
            let skin = try SkinEngine.buildSkin(at: url)
            install(skin, url: url)
            return true
        } catch {
            NSLog("Skin load failed for %@: %@", url.path, String(describing: error))
            return false
        }
    }

    /// Parses the archive on a background queue, then hot-swaps on the main thread.
    public func loadSkinAsync(at url: URL, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SkinEngine.buildSkin(at: url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let skin):
                    self.install(skin, url: url)
                    Events.status("SKIN LOADED: \(url.deletingPathExtension().lastPathComponent)")
                    completion?(true)
                case .failure(let error):
                    NSLog("Skin load failed for %@: %@", url.path, String(describing: error))
                    Events.status("SKIN ERROR: \(error)")
                    completion?(false)
                }
            }
        }
    }

    private func install(_ skin: LoadedSkin, url: URL?, notify: Bool = true) {
        active = skin
        activeSkinURL = url
        pleditColors = skin.pledit
        visColors = skin.vis
        mainRegionPolygon = skin.mainRegion
        eqRegionPolygon = skin.eqRegion
        glyphCache.removeAll()
        guard notify else { return }
        Events.post(.ampSkinChanged)
        Events.markDirty()
    }

    public static func buildSkin(at url: URL) throws -> LoadedSkin {
        var files: [String: Data] = [:]
        let wanted = SkinEngine.isSkinFile
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SkinError.unreadable(url.lastPathComponent)
        }
        if isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for item in items where wanted(item.lastPathComponent.lowercased()) {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= ZipArchive.maxEntrySize, let d = try? Data(contentsOf: item) else { continue }
                files[item.lastPathComponent.lowercased()] = d
            }
        } else {
            guard let data = try? Data(contentsOf: url) else { throw SkinError.unreadable(url.lastPathComponent) }
            do {
                files = try ZipArchive.extract(data: data, wanted: wanted)
            } catch let e as ZipArchive.ZipError {
                throw SkinError.archive(e)
            }
        }

        var images: [String: CGImage] = [:]
        for (name, data) in files where name.hasSuffix(".bmp") {
            // A tiny compressed file can declare gigapixel dimensions: check the header first and
            // decode only images within the limit (real classic-skin sprite sheets are < 350 px).
            guard SkinEngine.hasAcceptableDimensions(data) else {
                NSLog("Skin: ignoring %@ (dimensions exceed %d px)", name, SkinEngine.maxSpriteSide)
                continue
            }
            if let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage, let normalized = SkinEngine.normalized(cg) {
                images[name] = normalized
            }
        }
        guard images["main.bmp"] != nil else { throw SkinError.missingRequired("MAIN.BMP") }

        let parser = SkinEngine.parserOnly
        var pledit = PleditColors()
        if let d = files["pledit.txt"], let t = CueSheetParser.decodeStringWithEncodings(d) {
            pledit = parser.parsePleditTxt(t)
        }
        var vis = VisColors()
        if let d = files["viscolor.txt"], let t = CueSheetParser.decodeStringWithEncodings(d) {
            vis = parser.parseViscolorTxt(t)
        }
        var mainRegion: CGPath?
        var eqRegion: CGPath?
        if let d = files["region.txt"], let t = CueSheetParser.decodeStringWithEncodings(d) {
            (mainRegion, eqRegion) = parser.parseRegionTxt(t)
        }
        // The raw file bytes are dropped here: only decoded sprites and parsed colours are kept.
        return LoadedSkin(images: images, pledit: pledit, vis: vis, mainRegion: mainRegion, eqRegion: eqRegion)
    }

    /// Real classic 2.x skin sprite sheets are under 350 px; anything far beyond that is hostile or junk.
    public static let maxSpriteSide = 1024

    /// The only files read from a skin. Everything else in an archive (readme, extra bitmaps,
    /// junk planted to exhaust memory) is never inflated or decoded.
    static let skinBitmaps: Set<String> = [
        "main.bmp", "cbuttons.bmp", "titlebar.bmp", "shufrep.bmp", "text.bmp", "volume.bmp", "balance.bmp",
        "monoster.bmp", "playpaus.bmp", "numbers.bmp", "nums_ex.bmp", "posbar.bmp", "eqmain.bmp", "eq_ex.bmp",
        "pledit.bmp"
    ]
    static let skinConfigFiles: Set<String> = ["pledit.txt", "viscolor.txt", "region.txt"]

    static func isSkinFile(_ lowercasedName: String) -> Bool {
        skinBitmaps.contains(lowercasedName) || skinConfigFiles.contains(lowercasedName)
    }

    /// Reads only the image header (no pixel decode).
    static func hasAcceptableDimensions(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return false }
        return w > 0 && h > 0 && w <= maxSpriteSide && h <= maxSpriteSide
    }

    /// Skin bitmaps are usually 8-bit palettized BMPs; CoreGraphics would re-expand the palette on
    /// every blit. Converting once to 32-bit RGBA at load time keeps per-frame drawing cheap.
    static func normalized(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= maxSpriteSide, h <= maxSpriteSide,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Stateless parser instance used for background parsing (the parsers are pure functions).
    private static let parserOnly = SkinParser()

    // MARK: - Image Access

    public func getCGImage(named name: String) -> CGImage? {
        let key = name.lowercased()
        return active?.images[key] ?? base?.images[key]
    }

    // MARK: - Bitmap Font (TEXT.BMP, 5x6 glyphs)

    public static let glyphWidth: CGFloat = 5
    public static let glyphHeight: CGFloat = 6

    private static let glyphMap: [Character: (Int, Int)] = {
        var m: [Character: (Int, Int)] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@".enumerated() { m[c] = (i, 0) }
        m[" "] = (30, 0)
        for (i, c) in "0123456789\u{2026}.:()-'!_+\\/[]^&%,=$#".enumerated() { m[c] = (i, 1) }
        for (i, c) in "\u{C5}\u{D6}\u{C4}?*".enumerated() { m[c] = (i, 2) }
        return m
    }()

    /// Characters TEXT.BMP lacks, mapped to the closest glyph it has.
    private static let glyphAliases: [Character: Character] = [
        "<": "(", ">": ")", "{": "(", "}": ")", "|": "!", "~": "-", "`": "'",
        ";": ":", "\u{2013}": "-", "\u{2014}": "-", "\u{2018}": "'", "\u{2019}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{0141}": "L", "\u{00D8}": "O", "\u{00C6}": "A"
    ]

    public static func normalizeForBitmapFont(_ text: String) -> String {
        let upper = text.uppercased()
        var out = ""
        out.reserveCapacity(upper.count)
        for ch in upper {
            if glyphMap[ch] != nil {
                out.append(ch)
            } else if let alias = glyphAliases[ch] {
                out.append(alias)
            } else {
                let folded = String(ch).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).uppercased()
                if let f = folded.first, folded.count == 1, glyphMap[f] != nil {
                    out.append(f)
                } else {
                    out.append(" ")
                }
            }
        }
        return out
    }

    private func glyph(_ ch: Character) -> CGImage? {
        if let g = glyphCache[ch] { return g }
        guard let text = getCGImage(named: "TEXT.BMP"), let pos = SkinEngine.glyphMap[ch] else { return nil }
        let rect = CGRect(x: CGFloat(pos.0) * SkinEngine.glyphWidth, y: CGFloat(pos.1) * SkinEngine.glyphHeight,
                          width: SkinEngine.glyphWidth, height: SkinEngine.glyphHeight)
        guard let g = text.cropping(to: rect) else { return nil }
        glyphCache[ch] = g
        return g
    }

    /// Draws text with the skin's bitmap font into a flipped context. Returns the drawn width.
    @discardableResult
    public func drawBitmapText(_ text: String, at origin: CGPoint, in ctx: CGContext, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let normalized = SkinEngine.normalizeForBitmapFont(text)
        var x = origin.x
        for ch in normalized {
            if x - origin.x + SkinEngine.glyphWidth > maxWidth { break }
            if let g = glyph(ch) {
                ctx.drawImageFlipped(g, in: CGRect(x: x, y: origin.y, width: SkinEngine.glyphWidth, height: SkinEngine.glyphHeight))
            }
            x += SkinEngine.glyphWidth
        }
        return x - origin.x
    }

    /// Renders text into a standalone (upright) image (the marquee's scrolling strip).
    public func renderBitmapTextCG(_ text: String) -> (image: CGImage, width: CGFloat)? {
        let normalized = SkinEngine.normalizeForBitmapFont(text)
        let w = max(5, normalized.count * 5)
        guard let ctx = CGContext(data: nil, width: w, height: 6, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (i, ch) in normalized.enumerated() {
            if let g = glyph(ch) {
                ctx.draw(g, in: CGRect(x: i * 5, y: 0, width: 5, height: 6))
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, CGFloat(w))
    }
}

/// Pure text-config parsers for PLEDIT.TXT, VISCOLOR.TXT and REGION.TXT.
public struct SkinParser {
    public init() {}

    public func parsePleditTxt(_ text: String) -> PleditColors {
        var colors = PleditColors()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") && !line.contains("=") || line.hasPrefix("[") {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "font" {
                colors.fontName = val
            } else if let col = parseColor(val) {
                switch key {
                case "normal": colors.normalText = col
                case "current": colors.currentText = col
                case "normalbg": colors.normalBG = col
                case "selectedbg": colors.selectedBG = col
                default: break
                }
            }
        }
        return colors
    }

    public func parseViscolorTxt(_ text: String) -> VisColors {
        var vis = VisColors()
        var parsed: [NSColor] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "//") { line = String(line[..<r.lowerBound]) }
            if let r = line.range(of: ";") { line = String(line[..<r.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
            if parts.count >= 3 {
                parsed.append(NSColor(srgbRed: CGFloat(min(255, max(0, parts[0]))) / 255.0,
                                      green: CGFloat(min(255, max(0, parts[1]))) / 255.0,
                                      blue: CGFloat(min(255, max(0, parts[2]))) / 255.0, alpha: 1.0))
            }
            if parsed.count >= 24 { break }
        }
        if parsed.count == 24 {
            vis.colors = parsed
        } else if !parsed.isEmpty {
            // Partial palettes override the defaults for the entries they define.
            for (i, c) in parsed.enumerated() { vis.colors[i] = c }
        }
        return vis
    }

    public func parseRegionTxt(_ text: String) -> (main: CGPath?, eq: CGPath?) {
        var mainPath: CGMutablePath?
        var eqPath: CGMutablePath?
        var currentSection = ""
        var numPointsList: [Int] = []
        var pointList: [CGPoint] = []

        func commitSection() {
            defer { numPointsList.removeAll(); pointList.removeAll() }
            guard !pointList.isEmpty else { return }
            let path = CGMutablePath()
            var idx = 0
            let counts = numPointsList.isEmpty ? [pointList.count] : numPointsList
            for count in counts {
                guard count >= 3, idx + count <= pointList.count else { break }
                path.move(to: pointList[idx])
                for i in 1..<count { path.addLine(to: pointList[idx + i]) }
                path.closeSubpath()
                idx += count
            }
            guard !path.isEmpty else { return }
            if currentSection == "normal" { mainPath = path } else if currentSection == "equalizer" { eqPath = path }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                commitSection()
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "numpoints" {
                numPointsList = val.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Int($0) }
            } else if key == "pointlist" {
                let coords = val.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
                for i in stride(from: 0, to: coords.count - 1, by: 2) {
                    pointList.append(CGPoint(x: coords[i], y: coords[i + 1]))
                }
            }
        }
        commitSection()
        return (mainPath, eqPath)
    }

    private func parseColor(_ str: String) -> NSColor? {
        let s = str.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { return colorFromHex(String(s.dropFirst())) }
        if s.lowercased().hasPrefix("0x") { return colorFromHex(String(s.dropFirst(2))) }
        if s.contains(",") {
            let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count >= 3 {
                return NSColor(srgbRed: CGFloat(p[0]) / 255.0, green: CGFloat(p[1]) / 255.0, blue: CGFloat(p[2]) / 255.0, alpha: 1.0)
            }
            return nil
        }
        if let v = UInt32(s) {
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0, green: CGFloat((v >> 8) & 0xFF) / 255.0,
                           blue: CGFloat(v & 0xFF) / 255.0, alpha: 1.0)
        }
        return colorFromHex(s)
    }

    private func colorFromHex(_ hex: String) -> NSColor? {
        let clean = hex.trimmingCharacters(in: .whitespaces)
        guard clean.count == 6, let v = UInt64(clean, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v & 0xFF0000) >> 16) / 255.0, green: CGFloat((v & 0x00FF00) >> 8) / 255.0,
                       blue: CGFloat(v & 0x0000FF) / 255.0, alpha: 1.0)
    }
}

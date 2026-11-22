import AppKit

public enum VisualizerMode: Int, CaseIterable {
    case spectrum = 0
    case oscilloscope = 1
    case off = 2
}

public final class VisualizerView: SkinnedView {
    public var mode: VisualizerMode = .spectrum {
        didSet {
            resetLevels()
            needsDisplay = true
            updateTimer()
            Events.markDirty()
        }
    }

    private static let barCount = 32
    /// Frame rate. Each frame costs a timer wake-up, a Core Animation commit and a window-server
    /// recomposite, which dominate the visualizer's CPU; 30 FPS halves that and looks the same
    /// at 76x16 px. The fall-off physics below are expressed per 60 Hz tick and scaled by
    /// `ticksPerFrame`, so bars fall and peaks hold at the same real-time speed.
    static let fps: Double = 30
    private static let ticksPerFrame = CGFloat(60 / fps)
    private var levels = [CGFloat](repeating: 0, count: barCount)  // 0...16 px
    private var peaks = [CGFloat](repeating: 0, count: barCount)
    private var peakHold = [Int](repeating: 0, count: barCount)
    private var peakVelocity = [CGFloat](repeating: 0, count: barCount)
    private var osc: [Float] = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observer = NotificationCenter.default.addObserver(forName: .ampPlaybackStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateTimer()
        }
        updateTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        timer?.invalidate()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    private var isIdle: Bool {
        levels.allSatisfy { $0 <= 0 } && peaks.allSatisfy { $0 <= 0 } && osc.isEmpty
    }

    /// Animate at 60 FPS only while there is something to show; idle costs nothing.
    /// False while the main window is rolled up (the shade bar draws its own mini spectrum).
    private var onScreen = true

    public func setOnScreen(_ visible: Bool) {
        onScreen = visible
        updateTimer()
    }

    /// Frames are produced only for a visible window, and only while there is something to
    /// show (playing, or bars/peaks still falling after a stop).
    static func shouldAnimate(visible: Bool, mode: VisualizerMode, playing: Bool, idle: Bool) -> Bool {
        visible && mode != .off && (playing || !idle)
    }

    public override func visibilityDidChange() {
        updateTimer()
    }

    private func updateTimer() {
        AudioEngine.shared.setAnalysisEnabled(mode != .off)
        let needed = VisualizerView.shouldAnimate(visible: onScreen && isOnScreen, mode: mode,
                                                  playing: AudioEngine.shared.state == .playing, idle: isIdle)
        if needed && timer == nil {
            let t = Timer(timeInterval: 1.0 / VisualizerView.fps, repeats: true) { [weak self] _ in self?.frame() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed {
            timer?.invalidate()
            timer = nil
            needsDisplay = true
        }
    }

    private func resetLevels() {
        levels = [CGFloat](repeating: 0, count: VisualizerView.barCount)
        peaks = levels
        peakVelocity = levels
        peakHold = [Int](repeating: 0, count: VisualizerView.barCount)
        osc = []
    }

    private func frame() {
        let k = VisualizerView.ticksPerFrame
        // Only the data the current mode draws (the oscilloscope needs no FFT).
        let analysis = mode == .spectrum
            ? AudioEngine.shared.analyze(bins: VisualizerView.barCount, oscPoints: 0)
            : AudioEngine.shared.analyze(bins: 0, oscPoints: 76)
        let target = analysis?.spectrum ?? []
        osc = analysis?.osc ?? []

        for i in 0..<VisualizerView.barCount {
            let t = i < target.count ? CGFloat(target[i]) * 16 : 0
            // Fast attack, smooth release.
            levels[i] = t > levels[i] ? t : max(0, levels[i] - 0.9 * k)
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]
                peakHold[i] = 18 // hold ~0.3 s (in 60 Hz ticks)
                peakVelocity[i] = 0
            } else if peakHold[i] > 0 {
                peakHold[i] -= Int(k)
            } else {
                peakVelocity[i] += 0.035 * k // gravity
                peaks[i] = max(0, peaks[i] - peakVelocity[i] * k)
            }
        }
        // Push pixels straight to the layer: skips the NSView display pass entirely.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayer()
        CATransaction.commit()
        if analysis == nil && isIdle { updateTimer() }
    }

    public override func mouseDown(with event: NSEvent) {
        mode = VisualizerMode(rawValue: (mode.rawValue + 1) % VisualizerMode.allCases.count) ?? .spectrum
    }

    // MARK: - Rendering (direct pixel buffer → layer contents; no per-pixel CoreGraphics calls)

    public override var wantsUpdateLayer: Bool { true }

    private var pixels = [UInt32](repeating: 0, count: 76 * 16)
    private var palette: [UInt32] = []

    public override func skinDidChange() {
        palette = []
        lastPixels = []
        background = []
        needsDisplay = true
    }

    private static func pack(_ c: NSColor) -> UInt32 {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        let r = UInt32(max(0, min(255, (rgb.redComponent * 255).rounded())))
        let g = UInt32(max(0, min(255, (rgb.greenComponent * 255).rounded())))
        let b = UInt32(max(0, min(255, (rgb.blueComponent * 255).rounded())))
        // Little-endian RGBA bytes in memory (premultipliedLast + byteOrder32Big read as R,G,B,A).
        return (r << 24 | g << 16 | b << 8 | 0xFF).bigEndian
    }

    public override func updateLayer() {
        guard let layer = layer else { return }
        let w = 76, h = 16
        if palette.count != 24 {
            palette = SkinEngine.shared.visColors.colors.map(VisualizerView.pack)
            while palette.count < 24 { palette.append(VisualizerView.pack(.white)) }
        }
        if background.count != w * h || backgroundMode != mode {
            let bg = palette[0], dots = palette[1]
            background = (0..<(w * h)).map { i in
                (mode != .off && (i % w) % 2 == 1 && (i / w) % 2 == 1) ? dots : bg
            }
            backgroundMode = mode
        }
        // One exclusive access for the whole frame: per-pixel writes through the array property
        // would each pay Swift's exclusivity and copy-on-write checks.
        let pal = palette, lv = levels, pk = peaks, os = osc
        pixels.withUnsafeMutableBufferPointer { px in
            let p = px.baseAddress!
            background.withUnsafeBufferPointer { p.assign(from: $0.baseAddress!, count: w * h) }
            switch mode {
            case .spectrum: VisualizerView.renderSpectrum(into: p, w: w, h: h, palette: pal, levels: lv, peaks: pk)
            case .oscilloscope: VisualizerView.renderOscilloscope(into: p, w: w, h: h, palette: pal, osc: os)
            case .off: break
            }
        }
        // Identical frame (silence, pause, steady peaks): nothing to send to the window server.
        if pixels == lastPixels, layer.contents != nil { return }
        lastPixels = pixels
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: VisualizerView.rgb,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        if layer.magnificationFilter != .nearest { layer.magnificationFilter = .nearest }
        if layer.contentsGravity != .resize { layer.contentsGravity = .resize }
        layer.contents = image
    }

    private static let rgb = CGColorSpaceCreateDeviceRGB()
    private var background: [UInt32] = []
    private var backgroundMode: VisualizerMode = .off
    private var lastPixels: [UInt32] = []

    private static func renderSpectrum(into px: UnsafeMutablePointer<UInt32>, w: Int, h: Int,
                                       palette: [UInt32], levels: [CGFloat], peaks: [CGFloat]) {
        let n = barCount
        for i in 0..<n {
            let x0 = Int((CGFloat(i) * CGFloat(w) / CGFloat(n)).rounded())
            let x1 = Int((CGFloat(i + 1) * CGFloat(w) / CGFloat(n)).rounded())
            let bw = max(1, x1 - x0 - 1)
            let xEnd = min(w, x0 + bw)
            let barH = min(h, Int(levels[i].rounded()))
            // Row r from the top uses viscolor 2+r (red at the top, green at the bottom).
            if barH > 0 {
                for r in (h - barH)..<h {
                    let c = palette[min(17, 2 + r)]
                    for x in x0..<xEnd { px[r * w + x] = c }
                }
            }
            let peakRow = h - Int(peaks[i].rounded()) - 1
            if peaks[i] >= 1, peakRow >= 0 {
                for x in x0..<xEnd { px[peakRow * w + x] = palette[23] }
            }
        }
    }

    private static func renderOscilloscope(into px: UnsafeMutablePointer<UInt32>, w: Int, h: Int,
                                           palette: [UInt32], osc: [Float]) {
        guard !osc.isEmpty else { return }
        let mid = CGFloat(h) / 2
        var lastY: Int?
        for x in 0..<min(w, osc.count) {
            let y = Int(max(0, min(CGFloat(h - 1), mid - CGFloat(osc[x]) * mid)).rounded())
            let dist = abs(CGFloat(y) - mid) / mid
            let c = palette[18 + min(4, Int(dist * 4))]
            let lo = lastY.map { min($0, y) } ?? y
            let hi = lastY.map { max($0, y) } ?? y
            for r in lo...hi { px[r * w + x] = c }
            lastY = y
        }
    }
}

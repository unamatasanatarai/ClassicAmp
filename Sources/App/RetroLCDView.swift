import AppKit

/// The main window's display area. Frame origin is (24, 22) in main-window coordinates;
/// every position below is the classic skin coordinate minus that origin.
public final class RetroLCDView: SkinnedView {
    private static let origin = CGPoint(x: 24, y: 22)
    private static func local(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - origin.x, y: y - origin.y) }

    public var showRemainingTime: Bool = false {
        didSet { drawnTimeKey = nil; needsDisplay = true; Events.markDirty() }
    }

    public var marqueeText: String = "" {
        didSet { marquee.text = marqueeText }
    }
    private lazy var marquee = MarqueeView(frame: marqueeRect)

    public var bitrateText: String = "" { didSet { needsDisplay = true } }
    public var sampleRateText: String = "" { didSet { needsDisplay = true } }
    public var isStereo: Bool = true { didSet { needsDisplay = true } }
    public var hasTrack: Bool = false { didSet { needsDisplay = true } }
    public var playbackGlyph: Int = 2 { // 0 play, 1 pause, 2 stop
        didSet { needsDisplay = true }
    }

    private var statusText: String? {
        didSet { marquee.overrideText = statusText }
    }
    private var statusExpiry: CFAbsoluteTime = 0
    private var timer: Timer?
    /// (shown seconds, blink phase) last drawn; the readout is invalidated only when it changes.
    private var drawnTimeKey: Int?
    private var observers: [NSObjectProtocol] = []

    private static let tickInterval: TimeInterval = 0.25
    private let marqueeRect = CGRect(x: 111 - 24, y: 27 - 22, width: 154, height: 6)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setup() {
        addSubview(marquee)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .ampStatusMessage, object: nil, queue: .main) { [weak self] note in
            guard let text = note.userInfo?["text"] as? String else { return }
            self?.statusText = text
            self?.statusExpiry = CFAbsoluteTimeGetCurrent() + 1.6
            self?.updateTimer()
        })
        for name in [Notification.Name.ampTrackChanged, .ampPlaybackStateChanged, .ampPlaylistChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.syncWithEngine()
                self?.updateTimer()
            })
        }
        // Mute toggles: refresh the banner even while the ticker is idle.
        observers.append(nc.addObserver(forName: .ampModesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.step()
            self?.updateTimer()
        })
        syncWithEngine()
    }

    public override func visibilityDidChange() {
        updateTimer()
        if isOnScreen { step(); needsDisplay = true }
    }

    /// The 4 Hz ticker (time readout, pause blink, status expiry) runs only while visible and
    /// only while there is something that changes: a loaded track or a pending status message.
    /// Stopped and idle, the display costs no wake-ups.
    private func updateTimer() {
        let needed = isOnScreen && (AudioEngine.shared.state != .stopped || statusText != nil)
        if needed, timer == nil {
            let t = Timer(timeInterval: RetroLCDView.tickInterval, repeats: true) { [weak self] _ in
                self?.step()
                self?.updateTimer()
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    public func syncWithEngine() {
        let engine = AudioEngine.shared
        switch engine.state {
        case .playing: playbackGlyph = 0
        case .paused: playbackGlyph = 1
        case .stopped: playbackGlyph = 2
        }
        if let track = engine.currentTrack {
            hasTrack = true
            let pl = PlayerController.shared.playlist
            let number = pl.tracks.firstIndex { $0.id == track.id }.map { "\($0 + 1). " } ?? ""
            marqueeText = "\(number)\(track.displayTitle) (\(RetroLCDView.shortTime(track.duration)))"
            if let br = track.bitrate, br > 0 {
                // The kbps box holds 3 glyphs: lossless rates (e.g. 1411) read as "1K4".
                bitrateText = br < 1000 ? String(br) : "\(br / 1000)K\((br % 1000) / 100)"
            } else {
                bitrateText = ""
            }
            sampleRateText = track.sampleRate.map { String(Int(($0 / 1000).rounded())) } ?? ""
            isStereo = (track.channels ?? 2) >= 2
        } else {
            hasTrack = false
            marqueeText = "\(AppConfig.appName.uppercased()) \(AppConfig.version)"
            bitrateText = ""
            sampleRateText = ""
        }
        needsDisplay = true
    }

    /// The whole seconds the time readout shows (elapsed, or remaining when toggled).
    /// Also the redraw key: the digits change exactly when this value does.
    static func displayedSeconds(track: Track, position pos: TimeInterval, remaining: Bool) -> Int {
        remaining ? Track.wholeSeconds(track.duration - pos) : Track.wholeSeconds(pos.rounded(.down))
    }

    static func shortTime(_ t: TimeInterval) -> String {
        let s = Track.wholeSeconds(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func step() {
        let engine = AudioEngine.shared
        if statusText != nil, CFAbsoluteTimeGetCurrent() > statusExpiry {
            statusText = nil
        }
        // While muted, the display says so permanently (status messages still show briefly).
        if statusText == nil && engine.isMuted && marquee.overrideText == nil {
            marquee.overrideText = "*** MUTED - PRESS M TO UNMUTE ***"
        } else if statusText == nil && !engine.isMuted && marquee.overrideText != nil {
            marquee.overrideText = nil
        }
        // Time readout: redraw only when the shown second or the pause-blink phase changes.
        if engine.state != .stopped, let track = engine.currentTrack {
            let secs = RetroLCDView.displayedSeconds(track: track, position: engine.currentTime, remaining: showRemainingTime)
            let key = secs * 2 + (RetroLCDView.blinkHidden(engine) ? 1 : 0)
            if key != drawnTimeKey {
                drawnTimeKey = key
                setNeedsDisplay(timeRect)
            }
        } else if drawnTimeKey != nil {
            drawnTimeKey = nil
            setNeedsDisplay(timeRect)
        }
    }

    /// Paused time blinks at 1 Hz (half a second on, half off).
    static func blinkHidden(_ engine: AudioEngine) -> Bool {
        engine.state == .paused && Int(CFAbsoluteTimeGetCurrent() * 2) % 2 == 1
    }

    private let timeRect = CGRect(x: 36 - 24 - 1, y: 26 - 22, width: 66, height: 13)

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let timeArea = CGRect(origin: RetroLCDView.local(36, 26), size: CGSize(width: 66, height: 13))
        if timeArea.contains(p) {
            showRemainingTime.toggle()
        } else {
            (window as? BaseSkinnedWindow)?.handleTitleBarMouseDown(with: event)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        let engine = AudioEngine.shared

        // Status glyph (PLAYPAUS.BMP) + "working" indicator.
        let playpaus = skin.getCGImage(named: "PLAYPAUS.BMP")
        let g = RetroLCDView.local(26, 28)
        ctx.drawSprite(playpaus, src: CGRect(x: CGFloat(playbackGlyph) * 9, y: 0, width: 9, height: 9),
                       dst: CGRect(x: g.x, y: g.y, width: 9, height: 9))
        if playbackGlyph == 0, let pp = playpaus, pp.width >= 42 {
            let w = RetroLCDView.local(24, 28)
            ctx.drawSprite(pp, src: CGRect(x: 36, y: 0, width: 3, height: 9), dst: CGRect(x: w.x, y: w.y, width: 3, height: 9))
        }

        drawTime(ctx, skin: skin, engine: engine)

        guard hasTrack else { return }

        // kbps (3 chars, right aligned) and kHz (2 chars).
        let kbps = bitrateText
        let kb = RetroLCDView.local(111, 43)
        let kbWidth = CGFloat(kbps.count) * 5
        skin.drawBitmapText(kbps, at: CGPoint(x: kb.x + 15 - kbWidth, y: kb.y), in: ctx)
        let khz = RetroLCDView.local(156, 43)
        let khzText = String(sampleRateText.suffix(2))
        skin.drawBitmapText(khzText, at: CGPoint(x: khz.x + 10 - CGFloat(khzText.count) * 5, y: khz.y), in: ctx)

        // Mono / stereo badges (MONOSTER.BMP): top row lit, bottom row unlit.
        let ms = skin.getCGImage(named: "MONOSTER.BMP")
        let mono = RetroLCDView.local(212, 41)
        let stereo = RetroLCDView.local(239, 41)
        ctx.drawSprite(ms, src: CGRect(x: 29, y: isStereo ? 12 : 0, width: 27, height: 12), dst: CGRect(x: mono.x, y: mono.y, width: 27, height: 12))
        ctx.drawSprite(ms, src: CGRect(x: 0, y: isStereo ? 0 : 12, width: 29, height: 12), dst: CGRect(x: stereo.x, y: stereo.y, width: 29, height: 12))
    }

    private func drawTime(_ ctx: CGContext, skin: SkinEngine, engine: AudioEngine) {
        guard engine.state != .stopped, let track = engine.currentTrack else { return }
        // Blink while paused.
        if RetroLCDView.blinkHidden(engine) { return }

        let secs = RetroLCDView.displayedSeconds(track: track, position: engine.currentTime, remaining: showRemainingTime)
        let minutes = min(99, secs / 60)
        let seconds = secs % 60
        let digits = [minutes / 10, minutes % 10, seconds / 10, seconds % 10]
        let xs: [CGFloat] = [48, 60, 78, 90]

        let numsEx = skin.getCGImage(named: "NUMS_EX.BMP")
        let sheet = numsEx ?? skin.getCGImage(named: "NUMBERS.BMP")
        for (d, x) in zip(digits, xs) {
            let p = RetroLCDView.local(x, 26)
            ctx.drawSprite(sheet, src: CGRect(x: CGFloat(d) * 9, y: 0, width: 9, height: 13), dst: CGRect(x: p.x, y: p.y, width: 9, height: 13))
        }
        if showRemainingTime {
            if let ex = numsEx, ex.width >= 108 {
                let p = RetroLCDView.local(36, 26)
                ctx.drawSprite(ex, src: CGRect(x: 99, y: 0, width: 9, height: 13), dst: CGRect(x: p.x, y: p.y, width: 9, height: 13))
            } else {
                // NUMBERS.BMP has no minus glyph: the classic player borrows a 5x1 dash from the "2" digit.
                let p = RetroLCDView.local(38, 32)
                ctx.drawSprite(sheet, src: CGRect(x: 20, y: 6, width: 5, height: 1), dst: CGRect(x: p.x, y: p.y, width: 5, height: 1))
            }
        }
    }
}

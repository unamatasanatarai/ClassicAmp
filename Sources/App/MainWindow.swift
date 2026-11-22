import AppKit

public final class MainContentView: SkinnedContentView {
    // LCD overlay covers the display area right of the visualizer (main coords x 24...268, y 22...56).
    public let lcdView = RetroLCDView(frame: NSRect(x: 24, y: 22, width: 244, height: 34))
    public let visualizerView = VisualizerView(frame: NSRect(x: 24, y: 43, width: 76, height: 16))
    public let seekBar = SkinnedSlider(type: .position, frame: NSRect(x: 16, y: 72, width: 248, height: 10))
    public let volumeSlider = SkinnedSlider(type: .volume, frame: NSRect(x: 107, y: 57, width: 68, height: 13))
    public let balanceSlider = SkinnedSlider(type: .balance, frame: NSRect(x: 177, y: 57, width: 38, height: 13))

    public let prevButton = SkinnedTransportButton(type: .prev)
    public let playButton = SkinnedTransportButton(type: .play)
    public let pauseButton = SkinnedTransportButton(type: .pause)
    public let stopButton = SkinnedTransportButton(type: .stop)
    public let nextButton = SkinnedTransportButton(type: .next)
    public let ejectButton = SkinnedTransportButton(type: .eject)

    public let shuffleButton = SkinnedToggleButton(frame: NSRect(x: 164, y: 89, width: 47, height: 15))
    public let repeatButton = SkinnedToggleButton(frame: NSRect(x: 210, y: 89, width: 28, height: 15))
    public let eqButton = SkinnedToggleButton(frame: NSRect(x: 219, y: 58, width: 23, height: 12))
    public let plButton = SkinnedToggleButton(frame: NSRect(x: 242, y: 58, width: 23, height: 12))

    public let optionsButton = SkinnedButton(frame: NSRect(x: 6, y: 3, width: 9, height: 9),
                                             normal: Sprite("TITLEBAR.BMP", 0, 0, 9, 9), pressed: Sprite("TITLEBAR.BMP", 0, 9, 9, 9))
    public let minimizeButton = SkinnedButton(frame: NSRect(x: 244, y: 3, width: 9, height: 9),
                                              normal: Sprite("TITLEBAR.BMP", 9, 0, 9, 9), pressed: Sprite("TITLEBAR.BMP", 9, 9, 9, 9))
    public let shadeButton = SkinnedButton(frame: NSRect(x: 254, y: 3, width: 9, height: 9),
                                           normal: Sprite("TITLEBAR.BMP", 0, 18, 9, 9), pressed: Sprite("TITLEBAR.BMP", 9, 18, 9, 9))
    public let closeButton = SkinnedButton(frame: NSRect(x: 264, y: 3, width: 9, height: 9),
                                           normal: Sprite("TITLEBAR.BMP", 18, 0, 9, 9), pressed: Sprite("TITLEBAR.BMP", 18, 9, 9, 9))

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupControls() {
        prevButton.frame.origin = NSPoint(x: 16, y: 88)
        playButton.frame.origin = NSPoint(x: 39, y: 88)
        pauseButton.frame.origin = NSPoint(x: 62, y: 88)
        stopButton.frame.origin = NSPoint(x: 85, y: 88)
        nextButton.frame.origin = NSPoint(x: 108, y: 88)
        ejectButton.frame.origin = NSPoint(x: 136, y: 89)

        shuffleButton.configure(sheet: "SHUFREP.BMP",
                                off: CGRect(x: 28, y: 0, width: 47, height: 15), offPressed: CGRect(x: 28, y: 15, width: 47, height: 15),
                                on: CGRect(x: 28, y: 30, width: 47, height: 15), onPressed: CGRect(x: 28, y: 45, width: 47, height: 15))
        repeatButton.configure(sheet: "SHUFREP.BMP",
                               off: CGRect(x: 0, y: 0, width: 28, height: 15), offPressed: CGRect(x: 0, y: 15, width: 28, height: 15),
                               on: CGRect(x: 0, y: 30, width: 28, height: 15), onPressed: CGRect(x: 0, y: 45, width: 28, height: 15))
        eqButton.configure(sheet: "SHUFREP.BMP",
                           off: CGRect(x: 0, y: 61, width: 23, height: 12), offPressed: CGRect(x: 46, y: 61, width: 23, height: 12),
                           on: CGRect(x: 0, y: 73, width: 23, height: 12), onPressed: CGRect(x: 46, y: 73, width: 23, height: 12))
        plButton.configure(sheet: "SHUFREP.BMP",
                           off: CGRect(x: 23, y: 61, width: 23, height: 12), offPressed: CGRect(x: 69, y: 61, width: 23, height: 12),
                           on: CGRect(x: 23, y: 73, width: 23, height: 12), onPressed: CGRect(x: 69, y: 73, width: 23, height: 12))

        [lcdView, visualizerView, seekBar, volumeSlider, balanceSlider,
         prevButton, playButton, pauseButton, stopButton, nextButton, ejectButton,
         shuffleButton, repeatButton, eqButton, plButton,
         optionsButton, minimizeButton, shadeButton, closeButton].forEach { addSubview($0) }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, convert(event.locationInWindow, from: nil).y < 14 {
            WindowManager.shared.toggleShade(.main)
            return
        }
        // Anything that isn't a control is a drag handle (title bar and chrome).
        beginWindowDrag(event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) {
            SkinnedMenu.popUpContextMenu(menu, with: event)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        if let region = skin.mainRegionPolygon {
            ctx.addPath(region)
            ctx.clip()
        }
        ctx.drawImageFlipped(skin.getCGImage(named: "MAIN.BMP"), in: CGRect(x: 0, y: 0, width: 275, height: 116))
        let titleY: CGFloat = isKeyWindow ? 0 : 15
        ctx.drawSprite(skin.getCGImage(named: "TITLEBAR.BMP"), src: CGRect(x: 27, y: titleY, width: 275, height: 14),
                       dst: CGRect(x: 0, y: 0, width: 275, height: 14))
    }
}

/// The main window rolled up to its title bar (TITLEBAR.BMP "shade" strip): mini transport,
/// elapsed/remaining time, a tiny spectrum and a position bar, like the classic window-shade mode.
public final class MainShadeView: SkinnedContentView {
    public let optionsButton = SkinnedButton(frame: NSRect(x: 6, y: 3, width: 9, height: 9),
                                             normal: Sprite("TITLEBAR.BMP", 0, 0, 9, 9), pressed: Sprite("TITLEBAR.BMP", 0, 9, 9, 9))
    public let minimizeButton = SkinnedButton(frame: NSRect(x: 244, y: 3, width: 9, height: 9),
                                              normal: Sprite("TITLEBAR.BMP", 9, 0, 9, 9), pressed: Sprite("TITLEBAR.BMP", 9, 9, 9, 9))
    public let unshadeButton = SkinnedButton(frame: NSRect(x: 254, y: 3, width: 9, height: 9),
                                             normal: Sprite("TITLEBAR.BMP", 0, 27, 9, 9), pressed: Sprite("TITLEBAR.BMP", 9, 27, 9, 9))
    public let closeButton = SkinnedButton(frame: NSRect(x: 264, y: 3, width: 9, height: 9),
                                           normal: Sprite("TITLEBAR.BMP", 18, 0, 9, 9), pressed: Sprite("TITLEBAR.BMP", 18, 9, 9, 9))
    // The mini transport icons are painted into the shade strip; these are their click areas.
    public let prevButton = SkinnedButton(frame: NSRect(x: 169, y: 2, width: 7, height: 10))
    public let playButton = SkinnedButton(frame: NSRect(x: 176, y: 2, width: 10, height: 10))
    public let pauseButton = SkinnedButton(frame: NSRect(x: 186, y: 2, width: 10, height: 10))
    public let stopButton = SkinnedButton(frame: NSRect(x: 196, y: 2, width: 9, height: 10))
    public let nextButton = SkinnedButton(frame: NSRect(x: 205, y: 2, width: 10, height: 10))
    public let ejectButton = SkinnedButton(frame: NSRect(x: 215, y: 2, width: 10, height: 10))

    private static let posBar = CGRect(x: 226, y: 4, width: 17, height: 7)
    private static let timeRect = CGRect(x: 127, y: 4, width: 30, height: 6)
    private static let visRect = CGRect(x: 79, y: 5, width: 38, height: 5)
    private var timer: Timer?
    private var levels = [CGFloat](repeating: 0, count: 38)
    private var observers: [NSObjectProtocol] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [optionsButton, minimizeButton, unshadeButton, closeButton,
         prevButton, playButton, pauseButton, stopButton, nextButton, ejectButton].forEach { addSubview($0) }
        let nc = NotificationCenter.default
        for name in [Notification.Name.ampPlaybackStateChanged, .ampTrackChanged, .ampSkinChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateTimer()
                self?.needsDisplay = true
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public override func visibilityDidChange() {
        updateTimer()
    }

    /// 20 fps while playing and visible (spectrum + time), 2 Hz while paused (time blink),
    /// nothing at all otherwise.
    private func updateTimer() {
        let state = AudioEngine.shared.state
        let interval: TimeInterval? = !isOnScreen || state == .stopped ? nil : (state == .playing ? 1.0 / 20.0 : 0.5)
        if let t = timer, t.timeInterval != interval {
            t.invalidate()
            timer = nil
            if state != .playing { levels = [CGFloat](repeating: 0, count: levels.count) }
        }
        if let interval = interval, timer == nil {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = interval * 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Last (seconds, blink phase) drawn in the time readout; redraw only when it changes.
    private var drawnTimeKey = -1

    private var visualizerOn: Bool {
        ((WindowManager.shared.mainWindow as? MainWindow)?.mainView.visualizerView.mode ?? .spectrum) != .off
    }

    private func tick() {
        let engine = AudioEngine.shared
        if engine.state == .playing, visualizerOn {
            let spectrum = engine.analyze(bins: levels.count, oscPoints: 0)?.spectrum ?? []
            var changed = false
            for i in 0..<levels.count {
                let t = i < spectrum.count ? CGFloat(spectrum[i]) * 5 : 0
                let next = t > levels[i] ? t : max(0, levels[i] - 0.4)
                if next != levels[i] { levels[i] = next; changed = true }
            }
            if changed { setNeedsDisplay(MainShadeView.visRect) }
        }
        // Digits and the 1-px-per-few-seconds position thumb only change with the displayed second.
        let remaining = (WindowManager.shared.mainWindow as? MainWindow)?.mainView.lcdView.showRemainingTime ?? false
        let secs = engine.currentTrack.map {
            RetroLCDView.displayedSeconds(track: $0, position: engine.currentTime, remaining: remaining)
        } ?? 0
        let key = secs * 2 + (RetroLCDView.blinkHidden(engine) ? 1 : 0)
        if key != drawnTimeKey {
            drawnTimeKey = key
            setNeedsDisplay(MainShadeView.timeRect)
            setNeedsDisplay(MainShadeView.posBar)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        let engine = AudioEngine.shared
        let tb = skin.getCGImage(named: "TITLEBAR.BMP")
        ctx.drawSprite(tb, src: CGRect(x: 27, y: isKeyWindow ? 29 : 42, width: 275, height: 14), dst: CGRect(x: 0, y: 0, width: 275, height: 14))

        // Mini spectrum in the skin's visualizer colours (row 0 = top).
        let vis = skin.visColors.colors
        if visualizerOn, vis.count >= 18 {
            let r = MainShadeView.visRect
            for (i, level) in levels.enumerated() {
                let h = Int(min(5, level.rounded()))
                guard h > 0 else { continue }
                for row in (5 - h)..<5 {
                    vis[2 + row * 3].setFill()
                    CGRect(x: r.minX + CGFloat(i), y: r.minY + CGFloat(row), width: 1, height: 1).fill()
                }
            }
        }

        guard engine.state != .stopped, let track = engine.currentTrack else { return }
        // Time "MM:SS" (the colon is painted into the strip), minus sign when showing remaining.
        let lcd = (WindowManager.shared.mainWindow as? MainWindow)?.mainView.lcdView
        let remaining = lcd?.showRemainingTime ?? false
        let pos = engine.currentTime
        let secs = RetroLCDView.displayedSeconds(track: track, position: pos, remaining: remaining)
        if !RetroLCDView.blinkHidden(engine) {
            let m = min(99, secs / 60), s = secs % 60
            let t = MainShadeView.timeRect
            if remaining { skin.drawBitmapText("-", at: CGPoint(x: t.minX, y: t.minY), in: ctx) }
            skin.drawBitmapText("\(m / 10)\(m % 10)", at: CGPoint(x: t.minX + 7, y: t.minY), in: ctx)
            skin.drawBitmapText("\(s / 10)\(s % 10)", at: CGPoint(x: t.minX + 20, y: t.minY), in: ctx)
        }

        // Position bar: 3 px thumb (left/right end variants at the extremes).
        let p = MainShadeView.posBar
        ctx.drawSprite(tb, src: CGRect(x: 0, y: 36, width: 17, height: 7), dst: p)
        if track.duration > 0 {
            let ratio = max(0, min(1, pos / track.duration))
            let x = (p.minX + CGFloat(ratio) * (p.width - 3)).rounded()
            let src: CGFloat = ratio < 0.06 ? 17 : (ratio > 0.94 ? 23 : 20)
            ctx.drawSprite(tb, src: CGRect(x: src, y: 36, width: 3, height: 7), dst: CGRect(x: x, y: p.minY, width: 3, height: 7))
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            WindowManager.shared.toggleShade(.main)
            return
        }
        if MainShadeView.timeRect.insetBy(dx: -2, dy: -3).contains(p), let lcd = (WindowManager.shared.mainWindow as? MainWindow)?.mainView.lcdView {
            lcd.showRemainingTime.toggle()
            needsDisplay = true
            return
        }
        if MainShadeView.posBar.insetBy(dx: 0, dy: -3).contains(p) {
            seekDrag(event)
            return
        }
        beginWindowDrag(event)
    }

    private func seekDrag(_ event: NSEvent) {
        let engine = AudioEngine.shared
        guard let d = engine.currentTrack?.duration, d > 0 else { return }
        func ratio(_ e: NSEvent) -> Double {
            let x = convert(e.locationInWindow, from: nil).x
            return Double(max(0, min(1, (x - MainShadeView.posBar.minX) / MainShadeView.posBar.width)))
        }
        var last = ratio(event)
        trackMouse(in: self, onDrag: { e in
            last = ratio(e)
            let t = Int(last * d)
            Events.status(String(format: "SEEK TO: %d:%02d", t / 60, t % 60))
        }, onUp: { _ in engine.seek(to: last * d) })
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) {
            SkinnedMenu.popUpContextMenu(menu, with: event)
        }
    }
}

public final class MainWindow: BaseSkinnedWindow, Shadeable {
    public let shadeView = MainShadeView(frame: NSRect(x: 0, y: 0, width: 275, height: 14))
    public var defaultUnshadedHeight: CGFloat { 116 }

    public func applyShade(_ shaded: Bool) {
        contentView = shaded ? shadeView : mainView
        mainView.visualizerView.setOnScreen(!shaded)
        updatePositionTimer()
    }

    public let mainView: MainContentView
    private var observers: [NSObjectProtocol] = []

    public init() {
        mainView = MainContentView(frame: NSRect(x: 0, y: 0, width: 275, height: 116))
        super.init(id: .main, contentRect: NSRect(x: 200, y: 500, width: 275, height: 116))
        contentView = mainView
        setupBindings()
    }

    private func setupBindings() {
        let engine = AudioEngine.shared
        let player = PlayerController.shared
        let v = mainView

        v.prevButton.onAction = { player.playPrevious() }
        v.playButton.onAction = { player.playFromButton() }
        v.pauseButton.onAction = { engine.pause() }
        v.stopButton.onAction = { engine.stop() }
        v.nextButton.onAction = { player.playNext() }
        v.ejectButton.onAction = { player.openFilesPanel() }

        v.shuffleButton.onClick = { player.toggleShuffle() }
        v.repeatButton.onClick = { player.cycleRepeat() }
        v.eqButton.onClick = { WindowManager.shared.toggleVisible(.equalizer) }
        v.plButton.onClick = { WindowManager.shared.toggleVisible(.playlist) }

        v.closeButton.onAction = { NSApp.terminate(nil) }
        v.minimizeButton.onAction = { [weak self] in self?.miniaturizeCluster() }
        v.shadeButton.onAction = { WindowManager.shared.setShaded(.main, true) }

        let s = shadeView
        s.unshadeButton.onAction = { WindowManager.shared.setShaded(.main, false) }
        s.closeButton.onAction = { NSApp.terminate(nil) }
        s.minimizeButton.onAction = { [weak self] in self?.miniaturizeCluster() }
        s.optionsButton.onAction = { [weak self] in
            guard let self = self, let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) else { return }
            SkinnedMenu.popUp(menu, below: self.shadeView.optionsButton)
        }
        s.prevButton.onAction = { player.playPrevious() }
        s.playButton.onAction = { player.playFromButton() }
        s.pauseButton.onAction = { engine.pause() }
        s.stopButton.onAction = { engine.stop() }
        s.nextButton.onAction = { player.playNext() }
        s.ejectButton.onAction = { player.openFilesPanel() }
        v.optionsButton.onAction = { [weak self] in
            guard let self = self, let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) else { return }
            SkinnedMenu.popUp(menu, below: self.mainView.optionsButton)
        }

        v.seekBar.onValueChanged = { ratio in
            if let d = engine.currentTrack?.duration, d > 0 {
                let t = Int(ratio * d)
                Events.status(String(format: "SEEK TO: %d:%02d/%d:%02d (%d%%)", t / 60, t % 60, Int(d) / 60, Int(d) % 60, Int(ratio * 100)))
            }
        }
        v.seekBar.onTrackingEnded = { ratio in
            if let d = engine.currentTrack?.duration { engine.seek(to: ratio * d) }
        }

        v.volumeSlider.onValueChanged = { vol in
            engine.volume = Float(vol)
            if engine.isMuted { engine.isMuted = false }
            Events.status("VOLUME: \(Int((vol * 100).rounded()))%")
            Events.post(.ampModesChanged)
        }
        v.balanceSlider.onValueChanged = { bal in
            engine.balance = Float(bal)
            let pct = Int((abs(bal) * 100).rounded())
            Events.status(pct == 0 ? "BALANCE: CENTER" : "BALANCE: \(pct)% \(bal < 0 ? "LEFT" : "RIGHT")")
            Events.post(.ampModesChanged)
        }

        let nc = NotificationCenter.default
        for name in [Notification.Name.ampModesChanged, .ampWindowsChanged, .ampTrackChanged,
                     .ampPlaybackStateChanged, .ampEQChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.syncControls() })
        }
        syncControls()

        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main) { [weak self] _ in
            self?.updatePositionTimer()
        })
        updatePositionTimer()
    }

    /// Position bar follows playback at 4 Hz, only while playing and on screen; otherwise
    /// it costs no wake-ups at all.
    private var positionTimer: Timer?

    private func updatePositionTimer() {
        // Window-level visibility; the tick itself skips while the bar is rolled up (shaded).
        let needed = isVisible && occlusionState.contains(.visible) && AudioEngine.shared.state == .playing
        if needed, positionTimer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self = self, self.mainView.isOnScreen else { return }
                self.updatePositionBar()
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            positionTimer = t
        } else if !needed, let t = positionTimer {
            t.invalidate()
            positionTimer = nil
        }
    }

    public func syncControls() {
        let engine = AudioEngine.shared
        let pl = PlayerController.shared.playlist
        let v = mainView
        v.shuffleButton.isActive = pl.shuffleEnabled
        v.repeatButton.isActive = pl.repeatMode != .off
        v.eqButton.isActive = WindowManager.shared.isVisible(.equalizer)
        v.plButton.isActive = WindowManager.shared.isVisible(.playlist)
        if !v.volumeSlider.isDragging { v.volumeSlider.value = Double(engine.volume) }
        if !v.balanceSlider.isDragging { v.balanceSlider.value = Double(engine.balance) }
        updatePositionBar()
        updatePositionTimer()
    }

    private func updatePositionBar() {
        let engine = AudioEngine.shared
        let bar = mainView.seekBar
        guard !bar.isDragging else { return }
        guard let track = engine.currentTrack, engine.state != .stopped, track.duration > 0 else {
            bar.thumbHidden = engine.currentTrack == nil || engine.state == .stopped
            bar.value = 0
            return
        }
        bar.thumbHidden = false
        let v = max(0, min(1, engine.currentTime / track.duration))
        // The thumb moves in whole pixels: skip redraws that would produce the same picture.
        let px = Double(max(1, bar.bounds.width))
        if (v * px).rounded() != (bar.value * px).rounded() || v == 0 { bar.value = v }
    }

    private func miniaturizeCluster() {
        // Borderless windows cannot miniaturize individually; hide the whole player, as the classic player does.
        NSApp.hide(nil)
    }
}

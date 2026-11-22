import AppKit

public final class EqualizerContentView: SkinnedContentView {
    public let onButton = SkinnedToggleButton(frame: NSRect(x: 14, y: 18, width: 26, height: 12))
    public let autoButton = SkinnedToggleButton(frame: NSRect(x: 40, y: 18, width: 32, height: 12))
    public let presetsButton = SkinnedButton(frame: NSRect(x: 217, y: 18, width: 44, height: 12),
                                             normal: Sprite("EQMAIN.BMP", 224, 164, 44, 12),
                                             pressed: Sprite("EQMAIN.BMP", 224, 176, 44, 12))
    public let closeButton = SkinnedButton(frame: NSRect(x: 264, y: 3, width: 9, height: 9),
                                           normal: Sprite("EQMAIN.BMP", 0, 116, 9, 9),
                                           pressed: Sprite("EQMAIN.BMP", 0, 125, 9, 9))

    /// Title-bar "window shade" button (its idle look is part of the title bar bitmap).
    public let shadeButton = SkinnedButton(frame: NSRect(x: 254, y: 3, width: 9, height: 9),
                                           normal: nil, pressed: Sprite("EQ_EX.BMP", 1, 38, 9, 9))
    public let liveCurveView = LiveCurveView(frame: NSRect(x: 86, y: 17, width: 113, height: 19))
    public let preampSlider = SkinnedVerticalSlider(frame: NSRect(x: 21, y: 38, width: 14, height: 63))
    public var bandSliders: [SkinnedVerticalSlider] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupControls() {
        onButton.configure(sheet: "EQMAIN.BMP",
                           off: CGRect(x: 10, y: 119, width: 26, height: 12), offPressed: CGRect(x: 128, y: 119, width: 26, height: 12),
                           on: CGRect(x: 69, y: 119, width: 26, height: 12), onPressed: CGRect(x: 187, y: 119, width: 26, height: 12))
        autoButton.configure(sheet: "EQMAIN.BMP",
                             off: CGRect(x: 36, y: 119, width: 32, height: 12), offPressed: CGRect(x: 154, y: 119, width: 32, height: 12),
                             on: CGRect(x: 95, y: 119, width: 32, height: 12), onPressed: CGRect(x: 213, y: 119, width: 32, height: 12))

        for i in 0..<10 {
            bandSliders.append(SkinnedVerticalSlider(frame: NSRect(x: 78 + CGFloat(i) * 18, y: 38, width: 14, height: 63)))
        }
        ([onButton, autoButton, presetsButton, shadeButton, closeButton, liveCurveView, preampSlider] + bandSliders).forEach { addSubview($0) }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, p.y < 14 {
            WindowManager.shared.toggleShade(.equalizer)
            return
        }
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
        if let region = skin.eqRegionPolygon {
            ctx.addPath(region)
            ctx.clip()
        }
        let sheet = skin.getCGImage(named: "EQMAIN.BMP")
        ctx.drawSprite(sheet, src: CGRect(x: 0, y: 0, width: 275, height: 116), dst: CGRect(x: 0, y: 0, width: 275, height: 116))
        ctx.drawSprite(sheet, src: CGRect(x: 0, y: isKeyWindow ? 134 : 149, width: 275, height: 14),
                       dst: CGRect(x: 0, y: 0, width: 275, height: 14))
    }
}

/// The equalizer rolled up to its title bar: ON / AUTO / PRESETS plus the mini volume and
/// balance sliders of EQ_EX.BMP (filled up to the thumb so they read as sliders).
public final class EqualizerShadeView: SkinnedContentView, NSViewToolTipOwner {
    public let onButton = SkinnedToggleButton(frame: NSRect(x: 3, y: 1, width: 26, height: 12))
    public let autoButton = SkinnedToggleButton(frame: NSRect(x: 29, y: 1, width: 32, height: 12))
    public let presetsButton = SkinnedButton(frame: NSRect(x: 208, y: 1, width: 44, height: 12),
                                             normal: Sprite("EQMAIN.BMP", 224, 164, 44, 12),
                                             pressed: Sprite("EQMAIN.BMP", 224, 176, 44, 12))
    public let unshadeButton = SkinnedButton(frame: NSRect(x: 254, y: 3, width: 9, height: 9),
                                             normal: nil, pressed: Sprite("EQ_EX.BMP", 1, 47, 9, 9))
    public let closeButton = SkinnedButton(frame: NSRect(x: 264, y: 3, width: 9, height: 9),
                                           normal: Sprite("EQ_EX.BMP", 11, 38, 9, 9),
                                           pressed: Sprite("EQ_EX.BMP", 11, 47, 9, 9))
    private static let volumeTrack = CGRect(x: 61, y: 4, width: 97, height: 7)
    private static let balanceTrack = CGRect(x: 164, y: 4, width: 43, height: 7)
    private static let thumbW: CGFloat = 3
    private var observers: [NSObjectProtocol] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onButton.configure(sheet: "EQMAIN.BMP",
                           off: CGRect(x: 10, y: 119, width: 26, height: 12), offPressed: CGRect(x: 128, y: 119, width: 26, height: 12),
                           on: CGRect(x: 69, y: 119, width: 26, height: 12), onPressed: CGRect(x: 187, y: 119, width: 26, height: 12))
        autoButton.configure(sheet: "EQMAIN.BMP",
                             off: CGRect(x: 36, y: 119, width: 32, height: 12), offPressed: CGRect(x: 154, y: 119, width: 32, height: 12),
                             on: CGRect(x: 95, y: 119, width: 32, height: 12), onPressed: CGRect(x: 213, y: 119, width: 32, height: 12))
        [onButton, autoButton, presetsButton, unshadeButton, closeButton].forEach { addSubview($0) }
        addToolTip(EqualizerShadeView.volumeTrack.insetBy(dx: -2, dy: -3), owner: self, userData: nil)
        addToolTip(EqualizerShadeView.balanceTrack.insetBy(dx: -2, dy: -3), owner: self, userData: nil)
        let nc = NotificationCenter.default
        for name in [Notification.Name.ampModesChanged, .ampEQChanged, .ampSkinChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let engine = AudioEngine.shared
        if EqualizerShadeView.volumeTrack.insetBy(dx: -2, dy: -3).contains(point) {
            return "Volume: \(Int((engine.volume * 100).rounded()))%"
        }
        let b = engine.balance
        return b == 0 ? "Balance: center" : "Balance: \(Int((abs(b) * 100).rounded()))% \(b < 0 ? "left" : "right")"
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        let engine = AudioEngine.shared
        guard let ex = skin.getCGImage(named: "EQ_EX.BMP") else {
            // Skins without EQ_EX.BMP: fall back to the normal EQ title bar.
            ctx.drawSprite(skin.getCGImage(named: "EQMAIN.BMP"), src: CGRect(x: 0, y: isKeyWindow ? 134 : 149, width: 275, height: 14),
                           dst: CGRect(x: 0, y: 0, width: 275, height: 14))
            return
        }
        ctx.drawSprite(ex, src: CGRect(x: 0, y: isKeyWindow ? 0 : 15, width: 275, height: 14), dst: CGRect(x: 0, y: 0, width: 275, height: 14))

        // Thumb sprites come in left / centre / right flavours depending on the value.
        let vol = CGFloat(engine.volume)
        let vt = EqualizerShadeView.volumeTrack
        let vx = (vt.minX + vol * (vt.width - EqualizerShadeView.thumbW)).rounded()
        let vSrc: CGFloat = vol < 1 / 3 ? 1 : (vol < 2 / 3 ? 4 : 7)
        // Level fill in the thumb's own colour (its centre column, stretched).
        if vx > vt.minX + 1 {
            ctx.drawSprite(ex, src: CGRect(x: vSrc + 1, y: 31, width: 1, height: 5),
                           dst: CGRect(x: vt.minX + 1, y: vt.minY + 1, width: vx - vt.minX - 1, height: 5))
        }
        ctx.drawSprite(ex, src: CGRect(x: vSrc, y: 30, width: 3, height: 7), dst: CGRect(x: vx, y: vt.minY, width: 3, height: 7))

        let bal = CGFloat(engine.balance)
        let bt = EqualizerShadeView.balanceTrack
        let bx = (bt.minX + (bal + 1) / 2 * (bt.width - EqualizerShadeView.thumbW)).rounded()
        let bSrc: CGFloat = bal < -1 / 3 ? 11 : (bal > 1 / 3 ? 17 : 14)
        // Balance fill grows from the centre towards the thumb.
        let mid = (bt.minX + (bt.width - EqualizerShadeView.thumbW) / 2).rounded()
        if abs(bx - mid) > 1 {
            let from = min(bx + 3, mid), to = max(bx, mid + 3)
            ctx.drawSprite(ex, src: CGRect(x: bSrc + 1, y: 31, width: 1, height: 5),
                           dst: CGRect(x: from, y: bt.minY + 1, width: to - from, height: 5))
        }
        ctx.drawSprite(ex, src: CGRect(x: bSrc, y: 30, width: 3, height: 7), dst: CGRect(x: bx, y: bt.minY, width: 3, height: 7))
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            WindowManager.shared.toggleShade(.equalizer)
            return
        }
        let hitV = EqualizerShadeView.volumeTrack.insetBy(dx: -2, dy: -3)
        let hitB = EqualizerShadeView.balanceTrack.insetBy(dx: -2, dy: -3)
        guard hitV.contains(p) || hitB.contains(p) else {
            beginWindowDrag(event)
            return
        }
        let isVolume = hitV.contains(p)
        let apply = { [weak self] (e: NSEvent) in
            guard let self = self else { return }
            let x = self.convert(e.locationInWindow, from: nil).x
            let track = isVolume ? EqualizerShadeView.volumeTrack : EqualizerShadeView.balanceTrack
            let ratio = Float(max(0, min(1, (x - track.minX - 1) / (track.width - EqualizerShadeView.thumbW))))
            let engine = AudioEngine.shared
            if isVolume {
                engine.volume = ratio
                Events.status("VOLUME: \(Int((ratio * 100).rounded()))%")
            } else {
                var bal = ratio * 2 - 1
                if abs(bal) < 0.08 { bal = 0 } // snap to centre
                engine.balance = bal
                Events.status(bal == 0 ? "BALANCE: CENTER" : "BALANCE: \(Int(abs(bal) * 100))% \(bal < 0 ? "LEFT" : "RIGHT")")
            }
            Events.post(.ampModesChanged)
            self.needsDisplay = true
        }
        apply(event)
        trackMouse(in: self, onDrag: apply, onUp: { _ in })
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) {
            SkinnedMenu.popUpContextMenu(menu, with: event)
        }
    }
}

public final class EqualizerWindow: BaseSkinnedWindow, Shadeable {
    public let eqView: EqualizerContentView
    public let shadeView = EqualizerShadeView(frame: NSRect(x: 0, y: 0, width: 275, height: 14))
    public var defaultUnshadedHeight: CGFloat { 116 }

    public func applyShade(_ shaded: Bool) {
        contentView = shaded ? shadeView : eqView
        syncControlsWithEngine()
    }
    private var observers: [NSObjectProtocol] = []

    public init() {
        eqView = EqualizerContentView(frame: NSRect(x: 0, y: 0, width: 275, height: 116))
        super.init(id: .equalizer, contentRect: NSRect(x: 200, y: 384, width: 275, height: 116))
        contentView = eqView
        setupBindings()
    }

    private func setupBindings() {
        let engine = AudioEngine.shared

        eqView.onButton.onToggle = { enabled in
            engine.eqEnabled = enabled
            Events.status(enabled ? "EQUALIZER: ON" : "EQUALIZER: OFF (BYPASS)")
        }
        eqView.autoButton.onToggle = { enabled in
            engine.autoPresetEnabled = enabled
            if enabled, let track = engine.currentTrack,
               let preset = EqualizerPresets.matchPreset(forGenre: track.genre ?? "") {
                engine.applyPreset(preset)
            }
            Events.status(enabled ? "EQ AUTO-PRESET: ON" : "EQ AUTO-PRESET: OFF")
        }
        eqView.preampSlider.onValueChanged = { db in
            engine.preampGain = db
            engine.currentPresetName = "Custom"
            Events.status(String(format: "EQ: PREAMP %+.1f DB", db))
            Events.post(.ampEQChanged)
        }
        for (i, slider) in eqView.bandSliders.enumerated() {
            slider.onValueChanged = { db in
                engine.setBandGain(index: i, gain: db)
                engine.currentPresetName = "Custom"
                let f = EqualizerPresets.bandFrequencies[i]
                let label = f >= 1000 ? "\(Int(f / 1000))KHZ" : "\(Int(f))HZ"
                Events.status(String(format: "EQ: %@ %+.1f DB", label, db))
                Events.post(.ampEQChanged)
            }
        }
        eqView.presetsButton.onAction = { [weak self] in
            guard let self = self else { return }
            self.showPresetsMenu(anchor: self.eqView.presetsButton)
        }
        eqView.closeButton.onAction = { WindowManager.shared.setVisible(.equalizer, false) }
        eqView.shadeButton.onAction = { WindowManager.shared.setShaded(.equalizer, true) }
        shadeView.unshadeButton.onAction = { WindowManager.shared.setShaded(.equalizer, false) }
        shadeView.onButton.onToggle = eqView.onButton.onToggle
        shadeView.autoButton.onToggle = eqView.autoButton.onToggle
        shadeView.presetsButton.onAction = { [weak self] in
            guard let self = self else { return }
            self.showPresetsMenu(anchor: self.shadeView.presetsButton)
        }
        shadeView.closeButton.onAction = { WindowManager.shared.setVisible(.equalizer, false) }

        observers.append(NotificationCenter.default.addObserver(forName: .ampEQChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncControlsWithEngine()
        })
        syncControlsWithEngine()
    }

    public func syncControlsWithEngine() {
        let engine = AudioEngine.shared
        eqView.onButton.isActive = engine.eqEnabled
        eqView.autoButton.isActive = engine.autoPresetEnabled
        shadeView.onButton.isActive = engine.eqEnabled
        shadeView.autoButton.isActive = engine.autoPresetEnabled
        eqView.preampSlider.value = engine.preampGain
        for i in 0..<min(10, engine.eqBandGains.count) {
            eqView.bandSliders[i].value = engine.eqBandGains[i]
        }
        eqView.liveCurveView.preamp = engine.preampGain
        eqView.liveCurveView.bands = engine.eqBandGains
        eqView.liveCurveView.isEQEnabled = engine.eqEnabled
    }

    // MARK: - Presets

    private func showPresetsMenu(anchor: NSView) {
        let menu = NSMenu(title: "Presets")
        let current = AudioEngine.shared.currentPresetName

        let load = NSMenuItem(title: "Load", action: nil, keyEquivalent: "")
        let loadMenu = NSMenu()
        for preset in EqualizerPresets.factoryPresets {
            loadMenu.addItem(presetItem(preset, current: current))
        }
        if !EqualizerPresets.customPresets.isEmpty {
            loadMenu.addItem(.separator())
            for preset in EqualizerPresets.customPresets {
                loadMenu.addItem(presetItem(preset, current: current))
            }
        }
        load.submenu = loadMenu
        menu.addItem(load)

        let save = NSMenuItem(title: "Save Current as Preset…", action: #selector(handleSavePreset), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let del = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
        let delMenu = NSMenu()
        for preset in EqualizerPresets.customPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(handleDeletePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.name
            delMenu.addItem(item)
        }
        del.submenu = delMenu
        del.isEnabled = !EqualizerPresets.customPresets.isEmpty
        menu.addItem(del)

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset to Flat", action: #selector(handleResetFlat), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        SkinnedMenu.popUp(menu, below: anchor)
    }

    private func presetItem(_ preset: EqualizerPreset, current: String) -> NSMenuItem {
        let item = NSMenuItem(title: preset.name, action: #selector(handlePresetSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset.name
        item.state = preset.name == current ? .on : .off
        return item
    }

    private func preset(named name: String) -> EqualizerPreset? {
        EqualizerPresets.customPresets.first { $0.name == name } ?? EqualizerPresets.factoryPresets.first { $0.name == name }
    }

    @objc private func handlePresetSelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let p = preset(named: name) else { return }
        AudioEngine.shared.applyPreset(p)
        Events.status("EQ PRESET: \(p.name)")
    }

    @objc private func handleResetFlat() {
        AudioEngine.shared.applyPreset(EqualizerPresets.factoryPresets[0])
        Events.status("EQ PRESET: FLAT")
    }

    @objc private func handleSavePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Equalizer Preset"
        alert.informativeText = "Name for the current EQ curve (an existing custom preset with the same name is updated):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let current = AudioEngine.shared.currentPresetName
        field.stringValue = EqualizerPresets.customPresets.contains { $0.name == current } ? current : "My Preset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let engine = AudioEngine.shared
        EqualizerPresets.saveCustomPreset(EqualizerPreset(name: name, preamp: engine.preampGain, bands: engine.eqBandGains))
        engine.currentPresetName = name
        Events.status("EQ PRESET SAVED: \(name)")
    }

    @objc private func handleDeletePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        EqualizerPresets.deleteCustomPreset(named: name)
        Events.status("EQ PRESET DELETED: \(name)")
    }
}

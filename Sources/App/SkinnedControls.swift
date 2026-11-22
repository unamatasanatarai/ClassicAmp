import AppKit

/// A rectangle on one of the skin's bitmap sheets.
public struct Sprite: Equatable {
    public let sheet: String
    public let rect: CGRect

    public init(_ sheet: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        self.sheet = sheet
        self.rect = CGRect(x: x, y: y, width: w, height: h)
    }

    public func draw(in ctx: CGContext, at dst: CGRect) {
        ctx.drawSprite(SkinEngine.shared.getCGImage(named: sheet), src: rect, dst: dst)
    }
}

/// Runs a modal mouse-tracking loop (the classic AppKit pattern for custom controls).
func trackMouse(in view: NSView, onDrag: (NSEvent) -> Void, onUp: (NSEvent) -> Void) {
    guard let window = view.window else { return }
    while true {
        guard let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return }
        if e.type == .leftMouseDragged {
            onDrag(e)
        } else {
            onUp(e)
            return
        }
    }
}

// MARK: - Push Button

open class SkinnedButton: SkinnedView {
    public var isPressed: Bool = false {
        didSet { if oldValue != isPressed { needsDisplay = true } }
    }
    public var normalSprite: Sprite?
    public var pressedSprite: Sprite?
    public var onAction: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public convenience init(frame: NSRect, normal: Sprite?, pressed: Sprite?) {
        self.init(frame: frame)
        normalSprite = normal
        pressedSprite = pressed
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open override func mouseDown(with event: NSEvent) {
        isPressed = true
        trackMouse(in: self, onDrag: { e in
            self.isPressed = self.bounds.contains(self.convert(e.locationInWindow, from: nil))
        }, onUp: { e in
            let inside = self.bounds.contains(self.convert(e.locationInWindow, from: nil))
            self.isPressed = false
            if inside { self.onAction?() }
        })
    }

    open override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let sprite = isPressed ? (pressedSprite ?? normalSprite) : normalSprite
        sprite?.draw(in: ctx, at: bounds)
    }
}

// MARK: - Transport Button (CBUTTONS.BMP)

public enum TransportType: Int {
    case prev = 0, play, pause, stop, next, eject
}

public final class SkinnedTransportButton: SkinnedButton {
    public let type: TransportType

    public init(type: TransportType) {
        self.type = type
        let (x, w, h): (CGFloat, CGFloat, CGFloat)
        switch type {
        case .prev: (x, w, h) = (0, 23, 18)
        case .play: (x, w, h) = (23, 23, 18)
        case .pause: (x, w, h) = (46, 23, 18)
        case .stop: (x, w, h) = (69, 23, 18)
        case .next: (x, w, h) = (92, 22, 18)
        case .eject: (x, w, h) = (114, 22, 16)
        }
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        normalSprite = Sprite("CBUTTONS.BMP", x, 0, w, h)
        pressedSprite = Sprite("CBUTTONS.BMP", x, h, w, h)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Toggle Button (SHUFREP.BMP / EQMAIN.BMP)

public final class SkinnedToggleButton: SkinnedView {
    public var isActive: Bool = false {
        didSet { if oldValue != isActive { needsDisplay = true } }
    }
    public var isPressed: Bool = false {
        didSet { if oldValue != isPressed { needsDisplay = true } }
    }

    public var inactiveNormalRect: CGRect = .zero
    public var inactivePressedRect: CGRect = .zero
    public var activeNormalRect: CGRect = .zero
    public var activePressedRect: CGRect = .zero
    public var bitmapName: String = "SHUFREP.BMP"

    /// Called with the new state after a click. If `onClick` is set it replaces the toggle behaviour.
    public var onToggle: ((Bool) -> Void)?
    public var onClick: (() -> Void)?

    public func configure(sheet: String, off: CGRect, offPressed: CGRect, on: CGRect, onPressed: CGRect) {
        bitmapName = sheet
        inactiveNormalRect = off
        inactivePressedRect = offPressed
        activeNormalRect = on
        activePressedRect = onPressed
    }

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        trackMouse(in: self, onDrag: { e in
            self.isPressed = self.bounds.contains(self.convert(e.locationInWindow, from: nil))
        }, onUp: { e in
            let inside = self.bounds.contains(self.convert(e.locationInWindow, from: nil))
            self.isPressed = false
            guard inside else { return }
            if let click = self.onClick {
                click()
            } else {
                self.isActive.toggle()
                self.onToggle?(self.isActive)
            }
        })
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let rect = isActive ? (isPressed ? activePressedRect : activeNormalRect)
                            : (isPressed ? inactivePressedRect : inactiveNormalRect)
        ctx.drawSprite(SkinEngine.shared.getCGImage(named: bitmapName), src: rect, dst: bounds)
    }
}

// MARK: - Horizontal Slider (Volume / Balance / Position)

public final class SkinnedSlider: SkinnedView {
    public enum SliderType {
        case position
        case volume
        case balance
    }

    public let type: SliderType
    /// 0...1 for position/volume, -1...+1 for balance.
    public var value: Double = 0.5 {
        didSet { if oldValue != value { needsDisplay = true } }
    }
    /// Hides the thumb (position bar with nothing loaded).
    public var thumbHidden: Bool = false {
        didSet { if oldValue != thumbHidden { needsDisplay = true } }
    }

    public var onValueChanged: ((Double) -> Void)?
    public var onTrackingEnded: ((Double) -> Void)?

    public private(set) var isDragging: Bool = false

    private var thumbWidth: CGFloat { type == .position ? 29 : 14 }

    public init(type: SliderType, frame: NSRect) {
        self.type = type
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func mouseDown(with event: NSEvent) {
        if type == .position && thumbHidden { return }
        isDragging = true
        // Clicking on the thumb keeps the grab offset; elsewhere the thumb jumps to the mouse.
        let start = convert(event.locationInWindow, from: nil)
        let thumbX = CGFloat(normalizedValue) * (bounds.width - thumbWidth)
        let grab = (start.x >= thumbX && start.x <= thumbX + thumbWidth) ? start.x - thumbX : thumbWidth / 2
        update(from: start, grab: grab)
        trackMouse(in: self, onDrag: { e in
            self.update(from: self.convert(e.locationInWindow, from: nil), grab: grab)
        }, onUp: { e in
            self.update(from: self.convert(e.locationInWindow, from: nil), grab: grab)
            self.isDragging = false
            self.needsDisplay = true
            self.onTrackingEnded?(self.value)
        })
    }

    public override func scrollWheel(with event: NSEvent) {
        guard type != .position else { return }
        let delta = Double(event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX)
        let step = (event.hasPreciseScrollingDeltas ? 0.004 : 0.04) * delta
        if type == .volume {
            value = max(0, min(1, value + step))
        } else {
            value = max(-1, min(1, value + step))
            if abs(value) < 0.05 { value = 0 }
        }
        onValueChanged?(value)
    }

    private var normalizedValue: Double {
        type == .balance ? (value + 1) / 2 : value
    }

    private func update(from loc: NSPoint, grab: CGFloat) {
        let travel = bounds.width - thumbWidth
        guard travel > 0 else { return }
        let ratio = max(0, min(1, Double((loc.x - grab) / travel)))
        switch type {
        case .position, .volume:
            value = ratio
        case .balance:
            let pan = ratio * 2 - 1
            value = abs(pan) < 0.1 ? 0 : pan // centre detent
        }
        onValueChanged?(value)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        switch type {
        case .volume, .balance:
            let isVolume = type == .volume
            let sheet = skin.getCGImage(named: isVolume ? "VOLUME.BMP" : "BALANCE.BMP")
            let level = isVolume ? value : abs(value)
            let frame = CGFloat(min(27, max(0, Int((level * 27).rounded()))))
            let bgX: CGFloat = isVolume ? 0 : 9
            ctx.drawSprite(sheet, src: CGRect(x: bgX, y: frame * 15, width: bounds.width, height: 13), dst: bounds)
            let thumbSrcX: CGFloat = isDragging ? 0 : 15
            let x = (CGFloat(normalizedValue) * (bounds.width - 14)).rounded()
            if let sheet = sheet, sheet.height >= 433 {
                ctx.drawSprite(sheet, src: CGRect(x: thumbSrcX, y: 422, width: 14, height: 11),
                               dst: CGRect(x: x, y: 1, width: 14, height: 11))
            }
        case .position:
            let sheet = skin.getCGImage(named: "POSBAR.BMP")
            ctx.drawSprite(sheet, src: CGRect(x: 0, y: 0, width: 248, height: 10), dst: bounds)
            guard !thumbHidden else { return }
            let x = (CGFloat(max(0, min(1, value))) * (bounds.width - 29)).rounded()
            ctx.drawSprite(sheet, src: CGRect(x: isDragging ? 278 : 248, y: 0, width: 29, height: 10),
                           dst: CGRect(x: x, y: 0, width: 29, height: 10))
        }
    }
}

// MARK: - Vertical Slider (EQ preamp & bands, EQMAIN.BMP)

public final class SkinnedVerticalSlider: SkinnedView {
    /// dB, -12...+12 (top is +12).
    public var value: Float = 0.0 {
        didSet { if oldValue != value { needsDisplay = true } }
    }
    public var onValueChanged: ((Float) -> Void)?
    private var isDragging = false

    private let thumbH: CGFloat = 11

    public override func mouseDown(with event: NSEvent) {
        isDragging = true
        update(convert(event.locationInWindow, from: nil))
        trackMouse(in: self, onDrag: { e in
            self.update(self.convert(e.locationInWindow, from: nil))
        }, onUp: { _ in
            self.isDragging = false
            self.needsDisplay = true
        })
    }

    public override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.scrollingDeltaY)
        let step: Float = event.hasPreciseScrollingDeltas ? 0.05 : 0.6
        value = max(-12, min(12, value + delta * step))
        onValueChanged?(value)
    }

    private func update(_ loc: NSPoint) {
        let travel = bounds.height - thumbH
        guard travel > 0 else { return }
        let norm = 1 - max(0, min(1, (loc.y - thumbH / 2) / travel)) // 1 = top
        let db = Float(norm) * 24 - 12
        value = abs(db) < 0.75 ? 0 : (db * 10).rounded() / 10 // centre detent at 0 dB
        onValueChanged?(value)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext, let sheet = SkinEngine.shared.getCGImage(named: "EQMAIN.BMP") else { return }
        let norm = CGFloat((value + 12) / 24)
        let frame = min(27, max(0, Int((norm * 27).rounded())))
        let bgX = 13 + CGFloat(frame % 14) * 15
        let bgY = 164 + CGFloat(frame / 14) * 65
        ctx.drawSprite(sheet, src: CGRect(x: bgX, y: bgY, width: 14, height: 63), dst: CGRect(x: 0, y: 0, width: 14, height: 63))
        let thumbY = ((1 - norm) * (bounds.height - thumbH)).rounded()
        ctx.drawSprite(sheet, src: CGRect(x: 0, y: isDragging ? 176 : 164, width: 11, height: 11),
                       dst: CGRect(x: 1, y: thumbY, width: 11, height: 11))
    }
}

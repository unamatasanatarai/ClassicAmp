import AppKit
import QuartzCore

/// The title ticker. The text is rendered once into a bitmap strip; scrolling is a looping
/// CoreAnimation `contentsRect` animation executed by the window server, so it costs the app no CPU.
public final class MarqueeView: SkinnedView {
    public var text: String = "" {
        didSet { if oldValue != text { rebuild() } }
    }
    /// Temporary message (volume, seek, errors...) shown without scrolling.
    public var overrideText: String? {
        didSet { if oldValue != overrideText { rebuild() } }
    }

    private let separator = "  ***  "
    private static let pixelsPerSecond: Double = 25
    private static let loopPause: Double = 1.6

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func skinDidChange() {
        rebuild()
    }

    public override func updateLayer() {
        if layer?.contents == nil { rebuild() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()
    }

    public override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    private func rebuild() {
        guard let layer = layer else { return }
        let skin = SkinEngine.shared
        let shown = overrideText ?? text
        let width = bounds.width
        let textWidth = CGFloat(SkinEngine.normalizeForBitmapFont(shown).count) * SkinEngine.glyphWidth
        let scrolls = overrideText == nil && textWidth > width

        // Strip = loop + loop when scrolling (seamless wrap), otherwise the text padded to the view width.
        let content = scrolls ? (shown + separator + shown + separator) : shown
        let loopWidth = scrolls ? CGFloat((SkinEngine.normalizeForBitmapFont(shown + separator)).count) * SkinEngine.glyphWidth : 0
        guard let (strip, stripW) = skin.renderBitmapTextCG(content) else {
            layer.contents = nil
            return
        }
        let fullW = max(stripW, width)
        let padded = pad(strip, toWidth: Int(fullW)) ?? strip

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "scroll")
        layer.contents = padded
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        let visible = width / fullW
        layer.contentsRect = CGRect(x: 0, y: 0, width: visible, height: 1)
        CATransaction.commit()

        guard scrolls, loopWidth > 0 else { return }
        let scrollTime = Double(loopWidth) / MarqueeView.pixelsPerSecond
        let total = MarqueeView.loopPause + scrollTime
        let anim = CAKeyframeAnimation(keyPath: "contentsRect")
        anim.values = [
            NSValue(rect: NSRect(x: 0, y: 0, width: visible, height: 1)),
            NSValue(rect: NSRect(x: 0, y: 0, width: visible, height: 1)),
            NSValue(rect: NSRect(x: loopWidth / fullW, y: 0, width: visible, height: 1))
        ]
        anim.keyTimes = [0, NSNumber(value: MarqueeView.loopPause / total), 1]
        anim.calculationMode = .linear
        anim.duration = total
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "scroll")
    }

    /// Pads the strip on the right with transparent pixels so short text isn't stretched.
    private func pad(_ image: CGImage, toWidth w: Int) -> CGImage? {
        guard image.width < w else { return image }
        let h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: h))
        return ctx.makeImage()
    }
}

import AppKit

/// ⌘Q has to be pressed twice (within 2 s) to quit, so a stray keystroke can't stop the music.
/// The first press shows a small skin-styled notice over the main window.
public enum QuitConfirmation {
    private static let window: TimeInterval = 2.0
    private static var armedUntil: CFAbsoluteTime = 0
    private static var notice: QuitNoticePanel?

    /// Returns true when the app should quit now.
    public static func registerQuitKeyPress() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now < armedUntil {
            armedUntil = 0
            notice?.orderOut(nil)
            return true
        }
        armedUntil = now + window
        show()
        return false
    }

    private static func show() {
        notice?.orderOut(nil)
        let panel = QuitNoticePanel(message: "Press \u{2318}Q again to quit \(AppConfig.appName)")
        notice = panel
        let anchor = WindowManager.shared.mainWindow?.frame
            ?? NSScreen.main.map { NSRect(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY, width: 0, height: 0) }
            ?? .zero
        let size = panel.frame.size
        var origin = NSPoint(x: (anchor.midX - size.width / 2).rounded(), y: (anchor.midY - size.height / 2).rounded())
        if let vis = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak panel] in
            guard let panel = panel, panel === notice else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if notice === panel { notice = nil }
            })
        }
    }
}

/// Borderless notice: the skin's title bar on top, message in the playlist colours and font.
private final class QuitNoticePanel: NSPanel {
    init(message: String) {
        let s = WindowManager.shared.scale
        let size = NSSize(width: 275 * s, height: 44 * s)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        let view = QuitNoticeView(frame: NSRect(origin: .zero, size: size), message: message)
        view.setBoundsSize(NSSize(width: 275, height: 44))
        contentView = view
        contentView?.wantsLayer = true
        contentView?.layer?.magnificationFilter = .nearest
    }

    override var canBecomeKey: Bool { false }
}

private final class QuitNoticeView: NSView {
    let message: String

    init(frame: NSRect, message: String) {
        self.message = message
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let skin = SkinEngine.shared
        let c = skin.pleditColors
        let fg = c.normalText.usingColorSpace(.sRGB) ?? .green
        let body = NSRect(x: 0, y: 14, width: 275, height: 30)

        // Header: the main window's active title bar (the skin's name plaque) without its buttons.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: 275, height: 14))
        // The bar's buttons (x 244-272) are painted over by stretching the right-hand gold bars,
        // finished with their own end cap and the bar's right edge.
        let tb = skin.getCGImage(named: "TITLEBAR.BMP")
        ctx.drawSprite(tb, src: CGRect(x: 27, y: 0, width: 236, height: 14), dst: CGRect(x: 0, y: 0, width: 236, height: 14))
        ctx.drawSprite(tb, src: CGRect(x: 27 + 200, y: 0, width: 29, height: 14), dst: CGRect(x: 236, y: 0, width: 29, height: 14))
        ctx.drawSprite(tb, src: CGRect(x: 27 + 236, y: 0, width: 7, height: 14), dst: CGRect(x: 265, y: 0, width: 7, height: 14))
        ctx.drawSprite(tb, src: CGRect(x: 27 + 272, y: 0, width: 3, height: 14), dst: CGRect(x: 272, y: 0, width: 3, height: 14))
        ctx.restoreGState()

        c.normalBG.setFill()
        body.fill()
        fg.withAlphaComponent(0.55).setStroke()
        NSBezierPath(rect: body.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSColor.black.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: body.insetBy(dx: 1.5, dy: 1.5)).stroke()

        let font = NSFont(name: c.fontName, size: 11) ?? NSFont(name: "Arial", size: 11) ?? .systemFont(ofSize: 11)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c.currentText]
        let sz = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: NSPoint(x: ((275 - sz.width) / 2).rounded(), y: body.minY + ((body.height - sz.height) / 2).rounded()),
                                   withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        window?.orderOut(nil)
    }
}

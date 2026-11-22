import AppKit

/// App-wide broadcast events. Multiple observers can listen, unlike single-slot closures.
public extension Notification.Name {
    static let ampSkinChanged = Notification.Name("ClassicAmpSkinChanged")
    static let ampPlaylistChanged = Notification.Name("ClassicAmpPlaylistChanged")
    static let ampTrackChanged = Notification.Name("ClassicAmpTrackChanged")
    static let ampPlaybackStateChanged = Notification.Name("ClassicAmpPlaybackStateChanged")
    static let ampEQChanged = Notification.Name("ClassicAmpEQChanged")
    static let ampModesChanged = Notification.Name("ClassicAmpModesChanged")
    static let ampWindowsChanged = Notification.Name("ClassicAmpWindowsChanged")
    /// userInfo["text"]: String — a transient message shown in the LCD marquee.
    static let ampStatusMessage = Notification.Name("ClassicAmpStatusMessage")
    /// Anything persisted changed; the state manager debounces a save.
    static let ampStateDirty = Notification.Name("ClassicAmpStateDirty")
}

public enum Events {
    public static func post(_ name: Notification.Name, _ userInfo: [String: Any]? = nil) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
            }
        }
    }

    public static func status(_ text: String) {
        post(.ampStatusMessage, ["text": text])
    }

    public static func markDirty() {
        post(.ampStateDirty)
    }
}

/// Sub-images of skin sprite sheets, cut once and reused by every redraw (the draw paths ask
/// for the same few hundred rects over and over). Main thread only; emptied on skin change,
/// which also releases the previous skin's sheets.
enum SpriteCropCache {
    private struct Key: Hashable {
        let image: CGImage
        let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    }
    private static var cache: [Key: CGImage] = [:]
    private static var observer: NSObjectProtocol?

    static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        guard Thread.isMainThread else { return image.cropping(to: rect) }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .ampSkinChanged, object: nil, queue: nil) { _ in
                SpriteCropCache.cache.removeAll()
            }
        }
        let key = Key(image: image, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
        if let hit = cache[key] { return hit }
        guard let slice = image.cropping(to: rect) else { return nil }
        // Rects are fixed sprite coordinates; the cap only guards against unforeseen variety.
        if cache.count >= 2048 { cache.removeAll(keepingCapacity: true) }
        cache[key] = slice
        return slice
    }
}

public extension CGContext {
    /// Draws `src` (top-left origin, in image pixels) of `image` into `dst`,
    /// handling flipped/unflipped destination contexts and nearest-neighbour sampling.
    func drawSprite(_ image: CGImage?, src: CGRect, dst: CGRect, flipped: Bool = true) {
        guard let image = image else { return }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = src.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0,
              let slice = SpriteCropCache.crop(image, clipped) else { return }
        // If the source rect was clipped, shrink the destination accordingly.
        var target = dst
        if clipped != src, src.width > 0, src.height > 0 {
            let sx = dst.width / src.width, sy = dst.height / src.height
            target = CGRect(
                x: dst.minX + (clipped.minX - src.minX) * sx,
                y: dst.minY + (clipped.minY - src.minY) * sy,
                width: clipped.width * sx,
                height: clipped.height * sy
            )
        }
        saveGState()
        interpolationQuality = .none
        if flipped {
            translateBy(x: 0, y: target.maxY)
            scaleBy(x: 1, y: -1)
            draw(slice, in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height))
        } else {
            draw(slice, in: target)
        }
        restoreGState()
    }

    /// Draws a whole image at a destination rect in a flipped context.
    func drawImageFlipped(_ image: CGImage?, in dst: CGRect) {
        guard let image = image else { return }
        drawSprite(image, src: CGRect(x: 0, y: 0, width: image.width, height: image.height), dst: dst)
    }
}

/// Base class for every skinned view: flipped (top-left origin, like the bitmaps),
/// first-click responsive, and redraws itself whenever the skin changes.
open class SkinnedView: NSView {
    open override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(skinDidChange), name: .ampSkinChanged, object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(self, selector: #selector(skinDidChange), name: .ampSkinChanged, object: nil)
    }

    /// True only while this view's window can actually be seen: not hidden (⌘H / minimize),
    /// not on another Space, not completely covered (e.g. by a full-screen app).
    public var isOnScreen: Bool {
        guard let w = window else { return false }
        return w.isVisible && w.occlusionState.contains(.visible)
    }

    /// Override to start/stop animation timers; called when `isOnScreen` may have changed.
    open func visibilityDidChange() {}

    private var occlusionObserver: NSObjectProtocol?

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        if let w = window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak self] _ in self?.visibilityDidChange() }
        }
        visibilityDidChange()
    }

    deinit {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        NotificationCenter.default.removeObserver(self)
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc open func skinDidChange() {
        needsDisplay = true
    }

    public var cgContext: CGContext? {
        NSGraphicsContext.current?.cgContext
    }
}

import AppKit

/// Content views of skinned windows lay out in logical (1x) coordinates.
public protocol SkinnedContent: AnyObject {
    func relayout()
}

open class BaseSkinnedWindow: NSWindow {
    public let windowID: WindowID

    public init(id: WindowID, contentRect: NSRect) {
        self.windowID = id
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { true }

    open override var contentView: NSView? {
        didSet {
            contentView?.wantsLayer = true
            contentView?.layer?.magnificationFilter = .nearest
            syncContentScale()
        }
    }

    /// Logical size of the window content (frame size divided by the global scale).
    public var logicalSize: NSSize {
        let s = WindowManager.shared.scale
        return NSSize(width: frame.width / s, height: frame.height / s)
    }

    open override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        syncContentScale()
    }

    /// Double-Size mode: the content view's bounds stay in 1x logical units while its frame doubles,
    /// so all drawing is scaled by an exact integer with nearest-neighbour sampling.
    public func syncContentScale() {
        guard let cv = contentView else { return }
        let target = logicalSize
        if cv.bounds.size != target {
            cv.setBoundsSize(target)
            cv.setBoundsOrigin(.zero)
        }
        (cv as? SkinnedContent)?.relayout()
        cv.needsDisplay = true
        invalidateShadow()
    }

    open override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            WindowManager.shared.bringClusterToFront(from: self)
        }
        super.sendEvent(event)
    }

    open override func becomeKey() {
        super.becomeKey()
        contentView?.needsDisplay = true
    }

    open override func resignKey() {
        super.resignKey()
        contentView?.needsDisplay = true
    }

    public func handleTitleBarMouseDown(with event: NSEvent) {
        WindowManager.shared.beginDrag(window: self, event: event)
    }

    open override func performClose(_ sender: Any?) {
        WindowManager.shared.setVisible(windowID, false)
    }

    // MARK: - Classic player keyboard shortcuts

    open override func keyDown(with event: NSEvent) {
        if !handlePlayerKey(event) {
            super.keyDown(with: event)
        }
    }

    /// Returns true when the key was consumed.
    @discardableResult
    public func handlePlayerKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        let player = PlayerController.shared
        let engine = AudioEngine.shared
        switch event.keyCode {
        case 123: engine.seek(by: -5); return true // ←
        case 124: engine.seek(by: 5); return true  // →
        case 126: player.adjustVolume(by: 0.02); return true // ↑
        case 125: player.adjustVolume(by: -0.02); return true // ↓
        default: break
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Holding a transport key must not machine-gun play/pause/stop.
        if event.isARepeat, ["x", "c", "v", " ", "l", "j", "m", "s", "r"].contains(key ?? "") { return true }
        switch key {
        case "z": player.playPrevious(); return true
        case "x": player.playFromButton(); return true
        case "c": engine.pause(); return true
        case "v": engine.stop(); return true
        case "b": player.playNext(); return true
        case " ": engine.togglePlayPause(); return true
        case "l": player.openFilesPanel(); return true
        case "j": player.showJumpToFile(); return true
        case "m": engine.isMuted.toggle(); Events.status(engine.isMuted ? "MUTED" : "UNMUTED"); return true
        case "s": player.toggleShuffle(); return true
        case "r": player.cycleRepeat(); return true
        default: return false
        }
    }
}

/// Base for the three skinned content views: flipped, scaled by the window, accepts dropped files.
open class SkinnedContentView: SkinnedView, SkinnedContent {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    open func relayout() {}

    public var isKeyWindow: Bool {
        window?.isKeyWindow ?? false
    }

    /// Starts a window drag (snapping/cluster aware).
    public func beginWindowDrag(_ event: NSEvent) {
        (window as? BaseSkinnedWindow)?.handleTitleBarMouseDown(with: event)
    }

    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        PlayerController.shared.ingest(urls, autoplay: PlayerController.shared.autoplayOnAdd)
        return true
    }
}

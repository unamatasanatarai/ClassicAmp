import AppKit

/// Windows that can roll up to their title bar (classic "window shade").
public protocol Shadeable: AnyObject {
    /// Swap between the full content and the title-bar-only view (the frame is already resized).
    func applyShade(_ shaded: Bool)
    var defaultUnshadedHeight: CGFloat { get }
}

public enum WindowID: String, CaseIterable {
    case main
    case equalizer
    case playlist
}

public final class WindowManager {
    public static let shared = WindowManager()

    public private(set) var isDoubleSize: Bool = false
    public private(set) var isAlwaysOnTop: Bool = false

    public weak var mainWindow: NSWindow?
    public weak var eqWindow: NSWindow?
    public weak var playlistWindow: NSWindow?

    public private(set) var gluedBonds: Set<Bond> = []

    public struct Bond: Hashable {
        public let a: WindowID
        public let b: WindowID

        public init(_ first: WindowID, _ second: WindowID) {
            if first.rawValue < second.rawValue {
                a = first; b = second
            } else {
                a = second; b = first
            }
        }
    }

    /// Integer scale factor applied to every skinned window (1 or 2).
    public var scale: CGFloat { isDoubleSize ? 2 : 1 }
    public var snapDistance: CGFloat { isDoubleSize ? 20.0 : 10.0 }
    public var breakawayThreshold: CGFloat { isDoubleSize ? 40.0 : 20.0 }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.ensureWindowsOnScreen()
        }
    }

    public func window(for id: WindowID) -> NSWindow? {
        switch id {
        case .main: return mainWindow
        case .equalizer: return eqWindow
        case .playlist: return playlistWindow
        }
    }

    public func id(for window: NSWindow) -> WindowID? {
        if window === mainWindow { return .main }
        if window === eqWindow { return .equalizer }
        if window === playlistWindow { return .playlist }
        return nil
    }

    private var visibleIDs: [WindowID] {
        WindowID.allCases.filter { window(for: $0)?.isVisible == true }
    }

    // MARK: - Bonds & Clusters

    public func cluster(for id: WindowID) -> Set<WindowID> {
        var visited: Set<WindowID> = [id]
        var queue: [WindowID] = [id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for bond in gluedBonds {
                let n: WindowID? = bond.a == current ? bond.b : (bond.b == current ? bond.a : nil)
                if let n = n, !visited.contains(n) {
                    visited.insert(n)
                    queue.append(n)
                }
            }
        }
        return visited
    }

    public func breakBonds(for id: WindowID) {
        gluedBonds = gluedBonds.filter { $0.a != id && $0.b != id }
    }

    public func addBond(between first: WindowID, and second: WindowID) {
        guard first != second else { return }
        gluedBonds.insert(Bond(first, second))
    }

    /// Two visible windows are glued when an edge of one lies flush against an edge of the other.
    public static func areTouching(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 1.0) -> Bool {
        let vOverlap = a.minY < b.maxY - tolerance && a.maxY > b.minY + tolerance
        let hOverlap = a.minX < b.maxX - tolerance && a.maxX > b.minX + tolerance
        let sideBySide = vOverlap && (abs(a.maxX - b.minX) <= tolerance || abs(a.minX - b.maxX) <= tolerance)
        let stacked = hOverlap && (abs(a.maxY - b.minY) <= tolerance || abs(a.minY - b.maxY) <= tolerance)
        return sideBySide || stacked
    }

    public func recomputeBonds() {
        guard mainWindow != nil || eqWindow != nil || playlistWindow != nil else { return }
        var bonds: Set<Bond> = []
        let ids = visibleIDs
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] {
                if let fa = window(for: a)?.frame, let fb = window(for: b)?.frame, WindowManager.areTouching(fa, fb) {
                    bonds.insert(Bond(a, b))
                }
            }
        }
        gluedBonds = bonds
    }

    public func bringClusterToFront(from window: NSWindow) {
        guard let wid = id(for: window) else { return }
        recomputeBonds()
        for mid in cluster(for: wid) where mid != wid {
            self.window(for: mid)?.orderFront(nil)
        }
        window.orderFront(nil)
    }

    // MARK: - Dragging

    /// Runs the drag loop for a title-bar/background drag starting with `event`.
    public func beginDrag(window: NSWindow, event: NSEvent) {
        guard let movingID = id(for: window) else { return }
        recomputeBonds()

        let detach = event.modifierFlags.contains(.option)
        let fullCluster = cluster(for: movingID)
        var moving: Set<WindowID>
        // A child glued to the main window resists until dragged past the breakaway distance.
        var sticky = false
        if detach {
            moving = [movingID]
        } else if movingID == .main || !fullCluster.contains(.main) {
            moving = fullCluster
        } else {
            moving = [movingID]
            sticky = true
        }

        let startMouse = NSEvent.mouseLocation
        var startFrames: [WindowID: NSRect] = [:]
        for id in WindowID.allCases { if let w = self.window(for: id) { startFrames[id] = w.frame } }
        var didMove = false

        trackWindowDrag(window) { mouse, optionDown in
            var delta = CGPoint(x: mouse.x - startMouse.x, y: mouse.y - startMouse.y)
            if sticky {
                guard hypot(delta.x, delta.y) >= self.breakawayThreshold else { return }
                sticky = false
                self.closeGap(leftBy: movingID, in: fullCluster)
                for id in WindowID.allCases where id != movingID {
                    if let w = self.window(for: id) { startFrames[id] = w.frame }
                }
            }
            if optionDown && moving.count > 1 {
                moving = [movingID]
            }

            var proposed: [WindowID: NSRect] = [:]
            for id in moving {
                guard let f = startFrames[id] else { continue }
                proposed[id] = f.offsetBy(dx: delta.x, dy: delta.y)
            }
            if !optionDown {
                let adj = self.snapAdjustment(moving: proposed)
                delta.x += adj.x
                delta.y += adj.y
                for id in moving {
                    proposed[id] = startFrames[id]!.offsetBy(dx: delta.x, dy: delta.y)
                }
            }
            for (id, f) in proposed {
                self.window(for: id)?.setFrameOrigin(f.origin)
            }
            didMove = true
        }

        if didMove {
            recomputeBonds()
            Events.post(.ampWindowsChanged)
            Events.markDirty()
        }
    }

    private func trackWindowDrag(_ window: NSWindow, onMove: (NSPoint, Bool) -> Void) {
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return }
            if e.type == .leftMouseUp { return }
            onMove(NSEvent.mouseLocation, e.modifierFlags.contains(.option))
        }
    }

    /// When a window in the middle of a vertical stack leaves, pull the windows below it up.
    private func closeGap(leftBy leaving: WindowID, in group: Set<WindowID>) {
        guard let gone = window(for: leaving)?.frame else { return }
        let others = group.subtracting([leaving])
        let above = others.filter { id in
            guard let f = window(for: id)?.frame else { return false }
            return abs(f.minY - gone.maxY) <= 1 && f.minX < gone.maxX && f.maxX > gone.minX
        }
        let belowSeeds = others.filter { id in
            guard let f = window(for: id)?.frame else { return false }
            return abs(f.maxY - gone.minY) <= 1 && f.minX < gone.maxX && f.maxX > gone.minX
        }
        guard !above.isEmpty, !belowSeeds.isEmpty else { return }

        // Everything connected to the lower neighbour without passing through the leaving window
        // or the windows above it moves up by the leaving window's height.
        let saved = gluedBonds
        breakBonds(for: leaving)
        var below: Set<WindowID> = []
        for seed in belowSeeds { below.formUnion(cluster(for: seed)) }
        gluedBonds = saved
        below.subtract(above)
        below.remove(leaving)
        guard !below.isEmpty else { return }
        for id in below {
            guard let w = window(for: id) else { continue }
            w.setFrameOrigin(NSPoint(x: w.frame.minX, y: w.frame.minY + gone.height))
        }
    }

    /// Smallest translation that makes a moving edge flush with a nearby window or screen edge.
    private func snapAdjustment(moving: [WindowID: NSRect]) -> CGPoint {
        let th = snapDistance
        var bestX: CGFloat?
        var bestY: CGFloat?
        func considerX(_ d: CGFloat) { if abs(d) <= th, bestX == nil || abs(d) < abs(bestX!) { bestX = d } }
        func considerY(_ d: CGFloat) { if abs(d) <= th, bestY == nil || abs(d) < abs(bestY!) { bestY = d } }

        let targets = visibleIDs.filter { moving[$0] == nil }.compactMap { window(for: $0)?.frame }
        for m in moving.values {
            for t in targets {
                let vNear = m.minY < t.maxY + th && m.maxY > t.minY - th
                let hNear = m.minX < t.maxX + th && m.maxX > t.minX - th
                if vNear {
                    considerX(t.maxX - m.minX) // left edge → target right edge
                    considerX(t.minX - m.maxX) // right edge → target left edge
                }
                if hNear {
                    considerY(t.maxY - m.minY) // bottom edge → target top edge (stack below)
                    considerY(t.minY - m.maxY) // top edge → target bottom edge (stack above)
                }
                // Corner alignment along a shared seam.
                let stackedSeam = hNear && (abs(t.maxY - m.minY) <= th || abs(t.minY - m.maxY) <= th)
                let sideSeam = vNear && (abs(t.maxX - m.minX) <= th || abs(t.minX - m.maxX) <= th)
                if stackedSeam {
                    considerX(t.minX - m.minX)
                    considerX(t.maxX - m.maxX)
                }
                if sideSeam {
                    considerY(t.maxY - m.maxY)
                    considerY(t.minY - m.minY)
                }
            }
            let screen = NSScreen.screens.first { $0.frame.intersects(m) } ?? NSScreen.main
            if let v = screen?.visibleFrame {
                considerX(v.minX - m.minX)
                considerX(v.maxX - m.maxX)
                considerY(v.minY - m.minY)
                considerY(v.maxY - m.maxY)
            }
        }
        return CGPoint(x: bestX ?? 0, y: bestY ?? 0)
    }

    // MARK: - Double Size & Always on Top

    public func toggleDoubleSize() {
        setDoubleSize(!isDoubleSize)
    }

    public func setDoubleSize(_ enable: Bool) {
        guard enable != isDoubleSize else { return }
        let factor: CGFloat = enable ? 2.0 : 0.5
        isDoubleSize = enable

        // Scale every window's geometry about the main window's top-left corner,
        // which preserves the glued arrangement exactly.
        let anchorWin = mainWindow ?? eqWindow ?? playlistWindow
        let ax = anchorWin?.frame.minX ?? 0
        let ay = anchorWin?.frame.maxY ?? 0
        for id in WindowID.allCases {
            guard let w = window(for: id) else { continue }
            let f = w.frame
            let newW = (f.width * factor).rounded()
            let newH = (f.height * factor).rounded()
            let newX = ax + (f.minX - ax) * factor
            let newTop = ay - (ay - f.maxY) * factor
            w.setFrame(NSRect(x: newX, y: newTop - newH, width: newW, height: newH), display: true)
        }
        fitClusterOnScreen()
        Events.post(.ampWindowsChanged)
        Events.markDirty()
    }

    public func toggleAlwaysOnTop() {
        setAlwaysOnTop(!isAlwaysOnTop)
    }

    public func setAlwaysOnTop(_ enable: Bool) {
        isAlwaysOnTop = enable
        let level: NSWindow.Level = enable ? .floating : .normal
        for id in WindowID.allCases { window(for: id)?.level = level }
        Events.post(.ampWindowsChanged)
        Events.markDirty()
    }

    // MARK: - Screen Safety

    /// If the visible windows no longer fit on their screen (e.g. after Double-Size), shift them in.
    public func fitClusterOnScreen() {
        let wins = visibleIDs.compactMap { window(for: $0) }
        guard let first = wins.first else { return }
        let union = wins.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let screen = NSScreen.screens.max { $0.frame.intersection(union).area < $1.frame.intersection(union).area } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if union.maxX > v.maxX { dx = v.maxX - union.maxX }
        if union.minX + dx < v.minX { dx = v.minX - union.minX }
        if union.maxY > v.maxY { dy = v.maxY - union.maxY }
        if union.minY + dy < v.minY { dy = v.minY - union.minY }
        // Never push the title bars above the top of the work area.
        if union.maxY + dy > v.maxY { dy = v.maxY - union.maxY }
        guard dx != 0 || dy != 0 else { return }
        for w in wins { w.setFrameOrigin(NSPoint(x: w.frame.minX + dx, y: w.frame.minY + dy)) }
    }

    /// Moves windows orphaned on a disconnected display back onto a visible screen.
    public func ensureWindowsOnScreen() {
        guard let primary = NSScreen.main ?? NSScreen.screens.first else { return }
        for id in WindowID.allCases {
            guard let w = window(for: id) else { continue }
            let f = w.frame
            // Require the title bar strip to be reachable on some screen.
            let titleStrip = NSRect(x: f.minX, y: f.maxY - 14 * scale, width: f.width, height: 14 * scale)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersection(titleStrip).width >= 30 }
            if !onScreen {
                let v = primary.visibleFrame
                let x = min(max(v.minX, f.minX), v.maxX - f.width)
                let y = min(max(v.minY, f.minY), v.maxY - f.height)
                w.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        recomputeBonds()
    }

    // MARK: - Window Shade

    /// Height of a shaded ("rolled up") window: just its 14 px title bar.
    public static let shadeHeight: CGFloat = 14

    public private(set) var shadedIDs: Set<WindowID> = []
    /// Logical (1x) height each shaded window returns to when unshaded.
    public private(set) var unshadedHeights: [WindowID: CGFloat] = [:]

    public func isShaded(_ id: WindowID) -> Bool { shadedIDs.contains(id) }

    public func toggleShade(_ id: WindowID) {
        setShaded(id, !isShaded(id))
    }

    /// Rolls a window up to its title bar (or back down), keeping its top edge in place.
    /// Windows docked underneath follow, so a glued stack stays closed up.
    public func setShaded(_ id: WindowID, _ shade: Bool, moveDockedWindows: Bool = true) {
        guard shade != isShaded(id), let w = window(for: id) as? BaseSkinnedWindow & Shadeable else { return }
        recomputeBonds()
        let below = moveDockedWindows ? windowsDocked(below: id) : []
        let old = w.frame
        let newH: CGFloat
        if shade {
            unshadedHeights[id] = old.height / scale
            shadedIDs.insert(id)
            newH = WindowManager.shadeHeight * scale
        } else {
            shadedIDs.remove(id)
            newH = (unshadedHeights[id] ?? w.defaultUnshadedHeight) * scale
        }
        w.setFrame(NSRect(x: old.minX, y: old.maxY - newH, width: old.width, height: newH), display: false)
        w.applyShade(shade)
        let dy = old.height - newH
        for other in below {
            guard let ow = window(for: other) else { continue }
            ow.setFrameOrigin(NSPoint(x: ow.frame.minX, y: ow.frame.minY + dy))
        }
        if !shade { fitClusterOnScreen() }
        recomputeBonds()
        Events.post(.ampWindowsChanged)
        Events.markDirty()
    }

    /// Restores a saved shade state at launch (frames of the other windows are already final).
    public func restoreShade(_ id: WindowID, unshadedHeight: CGFloat) {
        unshadedHeights[id] = unshadedHeight
        setShaded(id, true, moveDockedWindows: false)
    }

    /// Windows hanging below `id` in its glued cluster: those touching its bottom edge plus
    /// everything glued to them that isn't above `id`.
    private func windowsDocked(below id: WindowID) -> Set<WindowID> {
        guard let me = window(for: id)?.frame else { return [] }
        let group = cluster(for: id)
        let seeds = group.filter { other in
            guard other != id, let f = window(for: other)?.frame else { return false }
            return abs(f.maxY - me.minY) <= 1 && f.minX < me.maxX && f.maxX > me.minX
        }
        guard !seeds.isEmpty else { return [] }
        let saved = gluedBonds
        breakBonds(for: id)
        var below: Set<WindowID> = []
        for seed in seeds { below.formUnion(cluster(for: seed)) }
        gluedBonds = saved
        below.remove(id)
        // Never drag along windows that sit above this one (e.g. a cluster glued around it).
        return below.filter { other in (window(for: other)?.frame.maxY ?? 0) <= me.minY + 1 }
    }

    // MARK: - Visibility

    public func isVisible(_ id: WindowID) -> Bool {
        window(for: id)?.isVisible ?? false
    }

    public func setVisible(_ id: WindowID, _ visible: Bool) {
        guard let w = window(for: id) else { return }
        if visible {
            w.orderFront(nil)
        } else {
            w.orderOut(nil)
        }
        recomputeBonds()
        Events.post(.ampWindowsChanged)
        Events.markDirty()
    }

    public func toggleVisible(_ id: WindowID) {
        setVisible(id, !isVisible(id))
    }

    // MARK: - Default Docked Layout

    public func applyDefaultGluedLayout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let s = scale
        let width = 275 * s
        let mainH = 116 * s, eqH = 116 * s, plH = 232 * s
        let x = (v.midX - width / 2).rounded()
        var top = min(v.maxY - 40, v.midY + (mainH + eqH + plH) / 2).rounded()

        for (id, h) in [(WindowID.main, mainH), (.equalizer, eqH), (.playlist, plH)] {
            guard let w = window(for: id) else { continue }
            w.setFrame(NSRect(x: x, y: top - h, width: width, height: h), display: true)
            w.orderFront(nil)
            top -= h
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        gluedBonds = [Bond(.main, .equalizer), Bond(.equalizer, .playlist)]
        fitClusterOnScreen()
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

import AppKit

/// Skin-styled popup menu, drawn with the active skin's playlist colours (PLEDIT.TXT) and font.
///
/// It renders an ordinary `NSMenu`: items keep their target/action, key-equivalent labels,
/// on/off state, submenus and enabling (`validateMenuItem` is honoured), so every popup in the
/// app can switch over without changing how its menu is built.
public final class SkinnedMenu {
    // MARK: Public entry points

    /// Shows `menu` with its top-left corner at `point` (in `view`'s coordinates).
    public static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        let inWindow = view.convert(point, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        popUp(menu, atScreenPoint: onScreen)
    }

    /// Shows `menu` under the mouse pointer of `event` (right-click context menus).
    public static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent) {
        let p = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        popUp(menu, atScreenPoint: p)
    }

    /// Shows `menu` directly below `view` (button menus), aligned to its left edge.
    public static func popUp(_ menu: NSMenu, below view: NSView) {
        let y = view.isFlipped ? view.bounds.maxY : view.bounds.minY
        popUp(menu, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }

    /// Shows `menu` directly above `view` (buttons at the bottom of a window).
    public static func popUp(_ menu: NSMenu, above view: NSView) {
        guard let window = view.window else { return }
        let r = window.convertToScreen(view.convert(view.bounds, to: nil))
        let size = MenuPanel.contentSize(for: Row.rows(from: menu))
        popUp(menu, atScreenPoint: NSPoint(x: r.minX, y: r.maxY + size.height))
    }

    public static func closeAll() {
        current?.dismiss()
    }

    private static func popUp(_ menu: NSMenu, atScreenPoint p: NSPoint) {
        closeAll()
        menu.update()
        let session = SkinnedMenu()
        current = session
        session.open(menu, topLeft: p, parent: nil)
    }

    // MARK: Session

    private static var current: SkinnedMenu?
    private var panels: [MenuPanel] = []
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    private init() {}

    fileprivate func open(_ menu: NSMenu, topLeft: NSPoint, parent: MenuPanel?) {
        let panel = MenuPanel(menu: menu, session: self)
        panel.place(topLeft: topLeft, avoiding: parent?.frame)
        panel.orderFront(nil)
        panels.append(panel)
        if monitors.isEmpty { installMonitors() }
    }

    fileprivate func openSubmenu(of row: Row, from panel: MenuPanel, rowRect: NSRect) {
        guard let sub = row.item.submenu else { return }
        closePanels(after: panel)
        sub.update()
        let screenRow = panel.convertToScreen(panel.contentView!.convert(rowRect, to: nil))
        open(sub, topLeft: NSPoint(x: screenRow.maxX - 2, y: screenRow.maxY + MenuPanel.padding), parent: panel)
    }

    fileprivate func closePanels(after panel: MenuPanel) {
        guard let idx = panels.firstIndex(where: { $0 === panel }) else { return }
        while panels.count > idx + 1 {
            panels.removeLast().orderOut(nil)
        }
        panel.menuView.openSubmenuRow = nil
    }

    /// The pointer is inside `panel`: every ancestor must keep its submenu chain open and lit
    /// (a close it scheduled while the pointer crossed its border is cancelled).
    fileprivate func pointerIsIn(_ panel: MenuPanel) {
        guard let idx = panels.firstIndex(where: { $0 === panel }) else { return }
        for ancestor in panels[..<idx] { ancestor.menuView.keepSubmenuOpen() }
    }

    /// True when `screenPoint` is over a panel opened below `panel` (its submenus).
    fileprivate func isOverChild(of panel: MenuPanel, screenPoint: NSPoint) -> Bool {
        guard let idx = panels.firstIndex(where: { $0 === panel }) else { return false }
        return panels[(idx + 1)...].contains { $0.frame.contains(screenPoint) }
    }

    fileprivate func activate(_ row: Row) {
        let item = row.item
        dismiss()
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    fileprivate func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        if SkinnedMenu.current === self { SkinnedMenu.current = nil }
    }

    private func installMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                return self.handleKey(event) ? nil : event
            }
            if let w = event.window, self.panels.contains(where: { $0 === w }) { return event }
            // A click outside closes the menu and is swallowed, like a system menu.
            self.dismiss()
            return event.type == .scrollWheel ? event : nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        monitors = [local, global].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.dismiss() }
    }

    /// Arrow keys / Return / Escape drive the deepest open menu.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel = panels.last else { return false }
        let view = panel.menuView
        switch event.keyCode {
        case 53: // Escape: close one level
            if panels.count > 1 {
                let parent = panels[panels.count - 2]
                closePanels(after: parent)
            } else {
                dismiss()
            }
        case 125: view.moveHighlight(by: 1)  // down
        case 126: view.moveHighlight(by: -1) // up
        case 124: // right: open submenu
            if let i = view.highlighted, view.rows[i].item.hasSubmenu, view.rows[i].enabled {
                openSubmenu(of: view.rows[i], from: panel, rowRect: view.rect(ofRow: i))
                panels.last?.menuView.moveHighlight(by: 1)
            }
        case 123: // left: back to parent
            if panels.count > 1 { closePanels(after: panels[panels.count - 2]) }
        case 36, 76, 49: // Return, Enter, Space
            guard let i = view.highlighted, view.rows[i].enabled else { return true }
            if view.rows[i].item.hasSubmenu {
                openSubmenu(of: view.rows[i], from: panel, rowRect: view.rect(ofRow: i))
                panels.last?.menuView.moveHighlight(by: 1)
            } else {
                activate(view.rows[i])
            }
        default:
            // Type-to-select: jump to the next item starting with the typed letter.
            if let ch = event.charactersIgnoringModifiers?.lowercased().first, ch.isLetter || ch.isNumber {
                view.highlightNext(startingWith: ch)
            }
        }
        return true
    }
}

// MARK: - Model

fileprivate struct Row {
    let item: NSMenuItem
    let enabled: Bool

    var isSeparator: Bool { item.isSeparatorItem }

    static func rows(from menu: NSMenu) -> [Row] {
        menu.items.filter { !$0.isHidden }.map { Row(item: $0, enabled: isEnabled($0, in: menu)) }
    }

    /// Mirrors AppKit's auto-enabling: submenus need an enabled child, actions need a target
    /// that (if it validates) agrees.
    private static func isEnabled(_ item: NSMenuItem, in menu: NSMenu) -> Bool {
        if item.isSeparatorItem { return false }
        if let sub = item.submenu {
            return item.isEnabled && sub.items.contains { !$0.isSeparatorItem && !$0.isHidden }
        }
        guard menu.autoenablesItems else { return item.isEnabled }
        guard let action = item.action else { return false }
        guard let target = item.target ?? NSApp.target(forAction: action, to: nil, from: item) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        return (target as AnyObject).responds(to: action)
    }
}

// MARK: - Panel

fileprivate final class MenuPanel: NSPanel {
    static let padding: CGFloat = 3

    let menuView: MenuView
    weak var session: SkinnedMenu?

    init(menu: NSMenu, session: SkinnedMenu) {
        let rows = Row.rows(from: menu)
        let size = MenuPanel.contentSize(for: rows)
        menuView = MenuView(frame: NSRect(origin: .zero, size: size), rows: rows)
        self.session = session
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = true
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle]
        menuView.panel = self
        contentView = menuView
    }

    override var canBecomeKey: Bool { false }

    static func contentSize(for rows: [Row]) -> NSSize {
        let m = MenuMetrics.current
        var labelW: CGFloat = 0
        var keyW: CGFloat = 0
        for r in rows where !r.isSeparator {
            labelW = max(labelW, (r.item.title as NSString).size(withAttributes: [.font: m.font]).width)
            let key = MenuView.shortcutLabel(r.item)
            if !key.isEmpty { keyW = max(keyW, (key as NSString).size(withAttributes: [.font: m.font]).width) }
        }
        let h = rows.reduce(CGFloat(0)) { $0 + ($1.isSeparator ? m.separatorH : m.rowH) } + padding * 2
        let w = m.gutter + labelW + (keyW > 0 ? m.keyGap + keyW : 0) + m.arrowW + padding * 2
        return NSSize(width: ceil(max(w, 90 * m.scale)), height: ceil(h))
    }

    /// Positions the panel with its top-left at `topLeft`, kept on screen. A submenu that
    /// doesn't fit to the right of its parent opens to the left instead.
    func place(topLeft: NSPoint, avoiding parent: NSRect?) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1e5, height: 1e5)
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        if origin.x + size.width > vis.maxX {
            origin.x = parent.map { $0.minX - size.width + 2 } ?? (vis.maxX - size.width)
        }
        origin.x = max(vis.minX, origin.x)
        if origin.y < vis.minY {
            // Not enough room below: open upwards from the anchor if that fits better.
            origin.y = parent == nil && topLeft.y + size.height <= vis.maxY ? topLeft.y : vis.minY
        }
        origin.y = min(origin.y, vis.maxY - size.height)
        setFrameOrigin(origin)
    }
}

// MARK: - Metrics

fileprivate struct MenuMetrics {
    let scale: CGFloat
    let font: NSFont
    let rowH: CGFloat
    let separatorH: CGFloat
    let gutter: CGFloat
    let keyGap: CGFloat
    let arrowW: CGFloat

    static var current: MenuMetrics {
        let s = WindowManager.shared.scale
        let name = SkinEngine.shared.pleditColors.fontName
        let size = 10.5 * s
        let font = NSFont(name: name, size: size) ?? NSFont(name: "Arial", size: size) ?? .systemFont(ofSize: size)
        return MenuMetrics(scale: s, font: font, rowH: 15 * s, separatorH: 7 * s, gutter: 16 * s, keyGap: 18 * s, arrowW: 14 * s)
    }
}

// MARK: - View

fileprivate final class MenuView: NSView {
    let rows: [Row]
    weak var panel: MenuPanel?
    private(set) var highlighted: Int?
    var openSubmenuRow: Int? {
        didSet {
            for r in [oldValue, openSubmenuRow].compactMap({ $0 }) where r < rowRects.count { setNeedsDisplay(rowRects[r]) }
        }
    }
    private var hoverTimer: Timer?
    /// Font and row geometry, resolved once: hit-testing runs on every mouse move.
    private let metrics = MenuMetrics.current
    private var rowRects: [NSRect] = []

    init(frame: NSRect, rows: [Row]) {
        self.rows = rows
        super.init(frame: frame)
        var y = MenuPanel.padding
        rowRects = rows.map { r in
            let h = r.isSeparator ? metrics.separatorH : metrics.rowH
            defer { y += h }
            return NSRect(x: MenuPanel.padding, y: y, width: frame.width - MenuPanel.padding * 2, height: h)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { hoverTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    func rect(ofRow index: Int) -> NSRect { rowRects[index] }

    private func row(at p: NSPoint) -> Int? {
        guard bounds.insetBy(dx: MenuPanel.padding, dy: MenuPanel.padding).contains(p) else { return nil }
        return rowRects.firstIndex { $0.contains(p) }
    }

    static func shortcutLabel(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let mods = item.keyEquivalentModifierMask
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let special: [String: String] = [" ": "Space", "\r": "↩", "\u{1b}": "Esc", "\u{8}": "⌫", "\u{7f}": "⌫",
                                         String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
                                         String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
                                         String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
                                         String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"]
        return s + (special[key] ?? key.uppercased())
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = SkinEngine.shared.pleditColors
        let m = metrics
        let bg = c.normalBG.usingColorSpace(.sRGB) ?? .black
        let fg = c.normalText.usingColorSpace(.sRGB) ?? .green

        bg.setFill()
        bounds.fill()

        // Classic-style double bevel frame tinted from the skin's text colour.
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        fg.withAlphaComponent(0.55).setStroke()
        NSBezierPath(rect: outer).stroke()
        let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
        let hi = NSBezierPath()
        hi.move(to: NSPoint(x: inner.minX, y: inner.maxY)); hi.line(to: NSPoint(x: inner.minX, y: inner.minY))
        hi.line(to: NSPoint(x: inner.maxX, y: inner.minY))
        fg.withAlphaComponent(0.22).setStroke(); hi.stroke()
        let lo = NSBezierPath()
        lo.move(to: NSPoint(x: inner.maxX, y: inner.minY)); lo.line(to: NSPoint(x: inner.maxX, y: inner.maxY))
        lo.line(to: NSPoint(x: inner.minX, y: inner.maxY))
        NSColor.black.withAlphaComponent(0.5).setStroke(); lo.stroke()

        for (i, row) in rows.enumerated() {
            let r = rect(ofRow: i)
            guard r.intersects(dirtyRect) else { continue }
            if row.isSeparator {
                let y = floor(r.midY) + 0.5
                let line = NSBezierPath()
                line.move(to: NSPoint(x: r.minX + 4 * m.scale, y: y)); line.line(to: NSPoint(x: r.maxX - 4 * m.scale, y: y))
                fg.withAlphaComponent(0.3).setStroke(); line.stroke()
                continue
            }
            let lit = row.enabled && (i == highlighted || i == openSubmenuRow)
            if lit {
                c.selectedBG.setFill()
                r.fill()
                fg.withAlphaComponent(0.35).setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
            let color: NSColor = !row.enabled ? fg.withAlphaComponent(0.35) : (lit ? c.currentText : fg)
            let attrs: [NSAttributedString.Key: Any] = [.font: m.font, .foregroundColor: color]
            let textH = (row.item.title as NSString).size(withAttributes: attrs).height
            let ty = r.minY + (r.height - textH) / 2

            if row.item.state != .off {
                // Check mark: a small filled square, like the classic player's option indicators.
                let d = 5 * m.scale
                let box = NSRect(x: r.minX + (m.gutter - d) / 2, y: r.midY - d / 2, width: d, height: d)
                color.setFill()
                (row.item.state == .on ? NSBezierPath(rect: box) : NSBezierPath(rect: box.insetBy(dx: 0, dy: d / 2 - 0.5))).fill()
            }
            (row.item.title as NSString).draw(at: NSPoint(x: r.minX + m.gutter, y: ty), withAttributes: attrs)

            let key = MenuView.shortcutLabel(row.item)
            if !key.isEmpty {
                let kw = (key as NSString).size(withAttributes: attrs).width
                (key as NSString).draw(at: NSPoint(x: r.maxX - m.arrowW - kw, y: ty), withAttributes: attrs)
            }
            if row.item.hasSubmenu {
                let a = 3.5 * m.scale
                let cx = r.maxX - m.arrowW / 2
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: cx - a / 2, y: r.midY - a)); tri.line(to: NSPoint(x: cx + a / 2, y: r.midY))
                tri.line(to: NSPoint(x: cx - a / 2, y: r.midY + a)); tri.close()
                color.setFill(); tri.fill()
            }
        }
    }

    // MARK: Highlight

    func setHighlight(_ i: Int?) {
        guard i != highlighted else { return }
        // Repaint only the two rows that change.
        for r in [highlighted, i].compactMap({ $0 }) where r < rowRects.count { setNeedsDisplay(rowRects[r]) }
        highlighted = i
    }

    /// Called while the pointer is inside one of this menu's submenus.
    func keepSubmenuOpen() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let open = openSubmenuRow { setHighlight(open) }
    }

    func moveHighlight(by delta: Int) {
        let selectable = rows.indices.filter { !rows[$0].isSeparator && rows[$0].enabled }
        guard !selectable.isEmpty else { return }
        guard let cur = highlighted, let pos = selectable.firstIndex(of: cur) else {
            setHighlight(delta > 0 ? selectable.first : selectable.last)
            return
        }
        setHighlight(selectable[(pos + delta + selectable.count) % selectable.count])
    }

    func highlightNext(startingWith ch: Character) {
        let start = (highlighted ?? -1) + 1
        let order = Array(rows.indices[start...]) + Array(rows.indices[..<start])
        if let i = order.first(where: { rows[$0].enabled && !rows[$0].isSeparator && rows[$0].item.title.lowercased().first == ch }) {
            setHighlight(i)
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard let panel = panel else { return }
        // Locate the pointer from the screen, not from the event: a mouse-moved event can be
        // delivered here while its coordinates belong to another panel (the submenu).
        let screen = NSEvent.mouseLocation
        let p = convert(panel.convertPoint(fromScreen: screen), from: nil)
        // Over a submenu (they overlap their parent by a few pixels) or outside this panel:
        // not this menu's business; it must not close the submenu the user is heading for.
        guard bounds.contains(p), !(panel.session?.isOverChild(of: panel, screenPoint: screen) ?? false) else { return }
        panel.session?.pointerIsIn(panel)
        let i = row(at: p)
        let selectable = i.flatMap { rows[$0].isSeparator || !rows[$0].enabled ? nil : $0 }
        if selectable != highlighted {
            setHighlight(selectable)
            // Crossing the border, padding or a separator is not a choice: keep any open
            // submenu. Only resting on another item switches or closes it.
            if selectable != nil || openSubmenuRow == nil { scheduleSubmenu(for: selectable) }
            else if let open = openSubmenuRow { setHighlight(open) }
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Keep the parent row of an open submenu lit (and the submenu open); otherwise clear.
        if let open = openSubmenuRow {
            keepSubmenuOpen()
            setHighlight(open)
        } else {
            setHighlight(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)), rows[i].enabled else { return }
        if rows[i].item.hasSubmenu { openSubmenu(i) }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)), rows[i].enabled, !rows[i].item.hasSubmenu else { return }
        flashAndActivate(i)
    }

    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    private func scheduleSubmenu(for i: Int?) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            if let i = i, self.rows[i].item.hasSubmenu {
                self.openSubmenu(i)
            } else if self.openSubmenuRow != nil {
                panel.session?.closePanels(after: panel)
            }
        }
    }

    private func openSubmenu(_ i: Int) {
        guard let panel = panel, openSubmenuRow != i else { return }
        panel.session?.openSubmenu(of: rows[i], from: panel, rowRect: rect(ofRow: i))
        openSubmenuRow = i
    }

    /// Brief blink on the chosen row, as menus do, before running the action.
    private func flashAndActivate(_ i: Int) {
        setHighlight(nil)
        displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self else { return }
            self.setHighlight(i)
            self.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self = self else { return }
                self.panel?.session?.activate(self.rows[i])
            }
        }
    }
}

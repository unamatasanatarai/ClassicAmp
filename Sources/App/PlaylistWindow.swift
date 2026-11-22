import AppKit

// MARK: - Track List

/// Custom-drawn track list using the skin's PLEDIT.TXT colours and font.
public final class PlaylistListView: SkinnedView {
    public let playlist: PlaylistManager
    public let rowHeight: CGFloat = 13
    public var onScrollChanged: (() -> Void)?

    /// Index of the first visible row.
    public private(set) var topRow: Int = 0
    private var anchorRow: Int?
    private var dropIndicatorRow: Int?

    public init(playlist: PlaylistManager, frame: NSRect) {
        self.playlist = playlist
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { true }

    public var visibleRowCount: Int { max(1, Int(bounds.height / rowHeight)) }
    public var maxTopRow: Int { max(0, playlist.count - visibleRowCount) }

    public func setTopRow(_ row: Int) {
        let clamped = max(0, min(maxTopRow, row))
        if clamped != topRow {
            topRow = clamped
            needsDisplay = true
            onScrollChanged?()
        }
    }

    public func scrollToVisible(_ row: Int) {
        if row < topRow {
            setTopRow(row)
        } else if row >= topRow + visibleRowCount {
            setTopRow(row - visibleRowCount + 1)
        }
    }

    public func clampScroll() {
        setTopRow(topRow)
        needsDisplay = true
    }

    private func row(at point: NSPoint) -> Int {
        topRow + Int(floor(point.y / rowHeight))
    }

    /// Font lookup by name is not free; resolved once per skin (PLEDIT.TXT names it).
    private var cachedFont: (name: String, font: NSFont)?
    private var font: NSFont {
        let name = SkinEngine.shared.pleditColors.fontName
        if let c = cachedFont, c.name == name { return c.font }
        let f = NSFont(name: name, size: 9.5) ?? NSFont(name: "Arial", size: 9.5) ?? NSFont.systemFont(ofSize: 9.5)
        cachedFont = (name, f)
        return f
    }
    private static let clippingStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping
        return p
    }()
    private static let missingColor = NSColor(srgbRed: 0.85, green: 0.25, blue: 0.25, alpha: 1)

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let colors = SkinEngine.shared.pleditColors
        ctx.setFillColor(colors.normalBG.cgColor)
        ctx.fill(bounds)

        let f = font
        let current = playlist.currentIndex
        let selected = playlist.selectedIndices
        let tracks = playlist.tracks
        let last = min(tracks.count, topRow + visibleRowCount + 1)
        guard topRow < last else { return }

        let para = PlaylistListView.clippingStyle
        let missingColor = PlaylistListView.missingColor
        let numberWidth = CGFloat(String(tracks.count).count) * 6 + 8

        for i in topRow..<last {
            let y = CGFloat(i - topRow) * rowHeight
            let rowRect = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            if selected.contains(i) {
                ctx.setFillColor(colors.selectedBG.cgColor)
                ctx.fill(rowRect)
            }
            let t = tracks[i]
            let color = t.missing ? missingColor : (i == current ? colors.currentText : colors.normalText)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: para]
            let duration = t.duration > 0 ? RetroLCDView.shortTime(t.duration) : ""
            let durStr = NSAttributedString(string: duration, attributes: attrs)
            let durW = ceil(durStr.size().width)
            let textY = y + (rowHeight - f.boundingRectForFont.height) / 2 - 0.5
            NSAttributedString(string: "\(i + 1).", attributes: attrs)
                .draw(in: CGRect(x: 2, y: textY, width: numberWidth, height: rowHeight + 2))
            NSAttributedString(string: t.displayTitle, attributes: attrs)
                .draw(in: CGRect(x: numberWidth, y: textY, width: max(0, bounds.width - numberWidth - durW - 6), height: rowHeight + 2))
            durStr.draw(at: CGPoint(x: bounds.width - durW - 2, y: textY))
        }

        if let drop = dropIndicatorRow {
            let y = CGFloat(drop - topRow) * rowHeight
            ctx.setFillColor(colors.currentText.cgColor)
            ctx.fill(CGRect(x: 0, y: max(0, y - 1), width: bounds.width, height: 2))
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        let flags = event.modifierFlags

        guard r >= 0, r < playlist.count else {
            if !flags.contains(.command) && !flags.contains(.shift) { setSelection([]) }
            return
        }

        if event.clickCount == 2 {
            PlayerController.shared.play(index: r)
            return
        }

        if flags.contains(.shift), let anchor = anchorRow ?? playlist.selectedIndices.first {
            setSelection(IndexSet(integersIn: min(anchor, r)...max(anchor, r)))
        } else if flags.contains(.command) {
            var sel = playlist.selectedIndices
            if sel.contains(r) { sel.remove(r) } else { sel.insert(r) }
            setSelection(sel)
            anchorRow = r
        } else {
            if !playlist.selectedIndices.contains(r) { setSelection([r]) }
            anchorRow = r
            trackReorderDrag(startRow: r)
        }
    }

    /// Drag selected rows to a new position (drop line shows the insertion point).
    private func trackReorderDrag(startRow: Int) {
        var moved = false
        trackMouse(in: self, onDrag: { e in
            let p = self.convert(e.locationInWindow, from: nil)
            if p.y < 0 { self.setTopRow(self.topRow - 1) } else if p.y > self.bounds.height { self.setTopRow(self.topRow + 1) }
            let target = max(0, min(self.playlist.count, self.topRow + Int((p.y / self.rowHeight).rounded())))
            if target != startRow || moved {
                moved = true
                self.dropIndicatorRow = target
                self.needsDisplay = true
            }
        }, onUp: { _ in
            if moved, let target = self.dropIndicatorRow {
                self.playlist.moveTracks(from: self.playlist.selectedIndices, to: target)
            } else {
                // Plain click on an already-selected row collapses a multi-selection.
                self.setSelection([startRow])
            }
            self.dropIndicatorRow = nil
            self.needsDisplay = true
        })
    }

    public override func rightMouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0, r < playlist.count, !playlist.selectedIndices.contains(r) { setSelection([r]) }
        let menu = NSMenu()
        let play = NSMenuItem(title: "Play", action: #selector(playSelection), keyEquivalent: "")
        play.target = self
        menu.addItem(play)
        let remove = NSMenuItem(title: "Remove", action: #selector(removeSelection), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealSelection), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        SkinnedMenu.popUpContextMenu(menu, with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / rowHeight : event.scrollingDeltaY * 3
        scrollAccumulator -= delta
        let whole = Int(scrollAccumulator.rounded(.towardZero))
        if whole != 0 {
            scrollAccumulator -= CGFloat(whole)
            setTopRow(topRow + whole)
        }
    }
    private var scrollAccumulator: CGFloat = 0

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        let sel = playlist.selectedIndices
        let shift = event.modifierFlags.contains(.shift)
        let noCmd = !event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125, 126: // ↓ ↑
            guard noCmd, playlist.count > 0 else { return }
            let up = event.keyCode == 126
            let cursor = up ? (sel.first ?? 1) - 1 : (sel.last ?? -1) + 1
            let r = max(0, min(playlist.count - 1, cursor))
            if shift, let anchor = anchorRow {
                setSelection(IndexSet(integersIn: min(anchor, r)...max(anchor, r)))
            } else {
                setSelection([r])
                anchorRow = r
            }
            scrollToVisible(r)
        case 116: setTopRow(topRow - visibleRowCount) // page up
        case 121: setTopRow(topRow + visibleRowCount) // page down
        case 115: setTopRow(0) // home
        case 119: setTopRow(maxTopRow) // end
        case 36, 76: playSelection() // return / enter
        case 51, 117: removeSelection() // delete / forward delete
        default:
            if !((window as? BaseSkinnedWindow)?.handlePlayerKey(event) ?? false) {
                super.keyDown(with: event)
            }
        }
    }

    @objc public override func selectAll(_ sender: Any?) {
        setSelection(IndexSet(integersIn: 0..<playlist.count))
    }

    private func setSelection(_ s: IndexSet) {
        playlist.setSelection(s)
        needsDisplay = true
    }

    @objc public func playSelection() {
        if let first = playlist.selectedIndices.first { PlayerController.shared.play(index: first) }
    }

    @objc public func removeSelection() {
        let first = playlist.selectedIndices.first
        playlist.removeSelected()
        if let f = first, playlist.count > 0 { setSelection([min(f, playlist.count - 1)]) }
        clampScroll()
    }

    @objc private func revealSelection() {
        let urls = playlist.selectedIndices.filter { $0 < playlist.count }.map { playlist.tracks[$0].url }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: File drops (insert at the drop row)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        dropIndicatorRow = max(0, min(playlist.count, topRow + Int((p.y / rowHeight).rounded())))
        needsDisplay = true
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicatorRow = nil
        needsDisplay = true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let at = dropIndicatorRow
        dropIndicatorRow = nil
        needsDisplay = true
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        PlayerController.shared.ingest(urls, autoplay: PlayerController.shared.autoplayOnAdd && playlist.count == 0, insertAt: at)
        return true
    }
}

// MARK: - Playlist Window Content

public final class PlaylistContentView: SkinnedContentView {
    public let playlistManager: PlaylistManager
    public let listView: PlaylistListView

    public let closeButton = SkinnedButton(frame: NSRect(x: 264, y: 3, width: 9, height: 9),
                                           normal: nil, pressed: Sprite("PLEDIT.BMP", 52, 42, 9, 9))
    /// Title-bar "window shade" button (idle look is part of the title bar bitmap).
    public let shadeButton = SkinnedButton(frame: NSRect(x: 255, y: 3, width: 9, height: 9),
                                           normal: nil, pressed: Sprite("PLEDIT.BMP", 62, 42, 9, 9))
    private let addButton = SkinnedButton(frame: .zero)
    private let remButton = SkinnedButton(frame: .zero)
    private let selButton = SkinnedButton(frame: .zero)
    private let miscButton = SkinnedButton(frame: .zero)
    private let listButton = SkinnedButton(frame: .zero)
    private var miniTransport: [SkinnedButton] = []

    public var onOpenJumpToFile: (() -> Void)?

    private static let topH: CGFloat = 20
    private static let bottomH: CGFloat = 38
    private static let leftW: CGFloat = 12
    private static let rightW: CGFloat = 20
    public static let minHeight: CGFloat = 116

    public init(playlistManager: PlaylistManager, frame: NSRect) {
        self.playlistManager = playlistManager
        self.listView = PlaylistListView(playlist: playlistManager, frame: .zero)
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        addSubview(listView)
        listView.onScrollChanged = { [weak self] in self?.needsDisplay = true }
        [shadeButton, closeButton, addButton, remButton, selButton, miscButton, listButton].forEach { addSubview($0) }

        closeButton.onAction = { WindowManager.shared.setVisible(.playlist, false) }
        shadeButton.onAction = { WindowManager.shared.setShaded(.playlist, true) }
        addButton.onAction = { [weak self] in self?.showAddMenu() }
        remButton.onAction = { [weak self] in self?.showRemMenu() }
        selButton.onAction = { [weak self] in self?.showSelMenu() }
        miscButton.onAction = { [weak self] in self?.showMiscMenu() }
        listButton.onAction = { [weak self] in self?.showListMenu() }

        let player = PlayerController.shared
        let engine = AudioEngine.shared
        let actions: [() -> Void] = [
            { player.playPrevious() }, { player.playFromButton() }, { engine.pause() },
            { engine.stop() }, { player.playNext() }, { player.openFilesPanel() }
        ]
        for action in actions {
            let b = SkinnedButton(frame: .zero)
            b.onAction = action
            miniTransport.append(b)
            addSubview(b)
        }
        relayout()
    }

    public override func relayout() {
        let w = bounds.width, h = bounds.height
        listView.frame = NSRect(x: PlaylistContentView.leftW, y: PlaylistContentView.topH,
                                width: max(10, w - PlaylistContentView.leftW - PlaylistContentView.rightW),
                                height: max(13, h - PlaylistContentView.topH - PlaylistContentView.bottomH))
        listView.clampScroll()
        closeButton.frame = NSRect(x: w - 11, y: 3, width: 9, height: 9)
        shadeButton.frame = NSRect(x: w - 20, y: 3, width: 9, height: 9)
        let by = h - 30
        addButton.frame = NSRect(x: 14, y: by, width: 22, height: 18)
        remButton.frame = NSRect(x: 43, y: by, width: 22, height: 18)
        selButton.frame = NSRect(x: 72, y: by, width: 22, height: 18)
        miscButton.frame = NSRect(x: 101, y: by, width: 22, height: 18)
        listButton.frame = NSRect(x: w - 44, y: by, width: 22, height: 18)
        let mx: [CGFloat] = [6, 14, 22, 30, 39, 47]
        let mw: [CGFloat] = [7, 8, 8, 8, 7, 8]
        for (i, b) in miniTransport.enumerated() {
            b.frame = NSRect(x: w - 150 + mx[i], y: h - 16, width: mw[i], height: 8)
        }
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let w = bounds.width, h = bounds.height
        if event.clickCount == 2, p.y < PlaylistContentView.topH {
            WindowManager.shared.toggleShade(.playlist)
        } else if p.x >= w - 20 && p.y >= h - 20 {
            resizeDrag(event)
        } else if p.x >= w - 20, p.y >= PlaylistContentView.topH, p.y < h - PlaylistContentView.bottomH {
            scrollbarDrag(event)
        } else {
            beginWindowDrag(event)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) {
            SkinnedMenu.popUpContextMenu(menu, with: event)
        }
    }

    // MARK: Scrollbar

    private var scrollTrack: (y: CGFloat, height: CGFloat) {
        (PlaylistContentView.topH, max(18, bounds.height - PlaylistContentView.topH - PlaylistContentView.bottomH))
    }

    private var thumbY: CGFloat {
        let track = scrollTrack
        let maxTop = listView.maxTopRow
        let ratio = maxTop > 0 ? CGFloat(listView.topRow) / CGFloat(maxTop) : 0
        return track.y + (ratio * (track.height - 18)).rounded()
    }

    private var draggingThumb = false

    private func scrollbarDrag(_ event: NSEvent) {
        let track = scrollTrack
        let start = convert(event.locationInWindow, from: nil)
        let grab = (start.y >= thumbY && start.y <= thumbY + 18) ? start.y - thumbY : 9
        draggingThumb = true
        func apply(_ p: NSPoint) {
            let ratio = max(0, min(1, (p.y - grab - track.y) / max(1, track.height - 18)))
            listView.setTopRow(Int((ratio * CGFloat(listView.maxTopRow)).rounded()))
            needsDisplay = true
        }
        apply(start)
        trackMouse(in: self, onDrag: { e in apply(self.convert(e.locationInWindow, from: nil)) }, onUp: { _ in
            self.draggingThumb = false
            self.needsDisplay = true
        })
    }

    // MARK: Resize (vertical, bottom-right grip)

    private func resizeDrag(_ event: NSEvent) {
        guard let win = window else { return }
        let startMouse = NSEvent.mouseLocation
        let startFrame = win.frame
        let scale = WindowManager.shared.scale
        trackMouse(in: self, onDrag: { _ in
            let dy = startMouse.y - NSEvent.mouseLocation.y
            // The classic playlist resizes in 29px steps.
            let logical = max(PlaylistContentView.minHeight, startFrame.height / scale + dy / scale)
            let stepped = PlaylistContentView.minHeight + ((logical - PlaylistContentView.minHeight) / 29).rounded() * 29
            let newH = stepped * scale
            win.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - newH, width: startFrame.width, height: newH), display: true)
        }, onUp: { _ in
            WindowManager.shared.recomputeBonds()
            Events.markDirty()
        })
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        let w = bounds.width, h = bounds.height
        guard let sheet = skin.getCGImage(named: "PLEDIT.BMP") else {
            ctx.setFillColor(skin.pleditColors.normalBG.cgColor)
            ctx.fill(bounds)
            return
        }
        let ty: CGFloat = isKeyWindow ? 0 : 21

        // A mini-time refresh dirties only a 30x10 rect: don't re-blit the whole frame for it.
        if needsToDraw(CGRect(x: 0, y: 0, width: w, height: PlaylistContentView.topH)) {
        // Top bar: corners, centred title, tiles in between.
        var x: CGFloat = 25
        while x < w - 25 {
            ctx.drawSprite(sheet, src: CGRect(x: 127, y: ty, width: 25, height: 20), dst: CGRect(x: x, y: 0, width: 25, height: 20))
            x += 25
        }
        ctx.drawSprite(sheet, src: CGRect(x: 0, y: ty, width: 25, height: 20), dst: CGRect(x: 0, y: 0, width: 25, height: 20))
        ctx.drawSprite(sheet, src: CGRect(x: 26, y: ty, width: 100, height: 20), dst: CGRect(x: ((w - 100) / 2).rounded(), y: 0, width: 100, height: 20))
        ctx.drawSprite(sheet, src: CGRect(x: 153, y: ty, width: 25, height: 20), dst: CGRect(x: w - 25, y: 0, width: 25, height: 20))
        }

        // Side borders.
        if needsToDraw(CGRect(x: 0, y: PlaylistContentView.topH, width: w, height: max(0, h - PlaylistContentView.topH - PlaylistContentView.bottomH))) {
        var y = PlaylistContentView.topH
        while y < h - PlaylistContentView.bottomH {
            let seg = min(29, h - PlaylistContentView.bottomH - y)
            ctx.drawSprite(sheet, src: CGRect(x: 0, y: 42, width: 12, height: seg), dst: CGRect(x: 0, y: y, width: 12, height: seg))
            ctx.drawSprite(sheet, src: CGRect(x: 31, y: 42, width: 20, height: seg), dst: CGRect(x: w - 20, y: y, width: 20, height: seg))
            y += 29
        }

        // Scrollbar thumb.
        ctx.drawSprite(sheet, src: CGRect(x: draggingThumb ? 61 : 52, y: 53, width: 8, height: 18),
                       dst: CGRect(x: w - 15, y: thumbY, width: 8, height: 18))
        }

        // Bottom bar.
        var bx: CGFloat = 125
        while bx < w - 150 {
            ctx.drawSprite(sheet, src: CGRect(x: 179, y: 0, width: 25, height: 38), dst: CGRect(x: bx, y: h - 38, width: 25, height: 38))
            bx += 25
        }
        ctx.drawSprite(sheet, src: CGRect(x: 0, y: 72, width: 125, height: 38), dst: CGRect(x: 0, y: h - 38, width: 125, height: 38))
        ctx.drawSprite(sheet, src: CGRect(x: 126, y: 72, width: 150, height: 38), dst: CGRect(x: w - 150, y: h - 38, width: 150, height: 38))

        // Running time: track count and total length.
        skin.drawBitmapText(compactSummary, at: CGPoint(x: w - 143, y: h - 28), in: ctx, maxWidth: 88)

        // Mini time display (elapsed of the current track).
        let engine = AudioEngine.shared
        if engine.state != .stopped {
            let t = Track.wholeSeconds(engine.currentTime.rounded(.down))
            skin.drawBitmapText(String(format: "%d:%02d", t / 60, t % 60), at: CGPoint(x: w - 150 + 66, y: h - 15), in: ctx, maxWidth: 25)
        }
    }

    /// Where the bottom bar's elapsed-time readout is drawn (see draw(_:)), for 1 s refreshes.
    public var miniTimeRect: CGRect {
        CGRect(x: bounds.width - 150 + 64, y: bounds.height - 17, width: 30, height: 10)
    }

    private var compactSummary: String {
        let total = playlistManager.totalSeconds
        let time = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        return "\(playlistManager.count) TRK/\(time)"
    }

    // MARK: Button menus

    private func popUp(_ items: [(String, Selector)], from button: NSView) {
        let menu = NSMenu()
        for (title, action) in items {
            if title == "-" {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        // Like the classic playlist button menus, they open upwards from the bottom bar.
        SkinnedMenu.popUp(menu, above: button)
    }

    private func showAddMenu() {
        popUp([("Add Files…", #selector(handleAddFile)), ("Add Folder…", #selector(handleAddDirectory)),
               ("Scan Music Library…", #selector(handleScanMusicLibrary))], from: addButton)
    }

    private func showRemMenu() {
        popUp([("Remove Selected", #selector(handleRemoveSelected)), ("Crop Selection", #selector(handleCropSelected)),
               ("Remove Missing Files", #selector(handleRemoveMissing)), ("-", #selector(handleClearPlaylist)),
               ("Clear Playlist", #selector(handleClearPlaylist))], from: remButton)
    }

    private func showSelMenu() {
        popUp([("Select All", #selector(handleSelectAll)), ("Select None", #selector(handleSelectNone)),
               ("Invert Selection", #selector(handleInvertSelection))], from: selButton)
    }

    private func showMiscMenu() {
        popUp([("Sort by Title", #selector(handleSortByTitle)), ("Sort by Filename", #selector(handleSortByFilename)),
               ("Sort by Path", #selector(handleSortByPath)), ("Sort by Duration", #selector(handleSortByDuration)), ("Reverse List", #selector(handleReverseList)),
               ("Randomize List", #selector(handleRandomizeList)),
               ("-", #selector(handleJumpToFile)), ("Jump to File…", #selector(handleJumpToFile))], from: miscButton)
    }

    private func showListMenu() {
        popUp([("New List", #selector(handleClearPlaylist)), ("Save List…", #selector(handleSaveList)),
               ("Load List…", #selector(handleLoadList))], from: listButton)
    }

    @objc private func handleAddFile() { PlayerController.shared.openFilesPanel() }
    @objc private func handleAddDirectory() { PlayerController.shared.openFolderPanel() }
    @objc private func handleScanMusicLibrary() { PlayerController.shared.scanMusicLibrary() }
    @objc private func handleRemoveSelected() { listView.removeSelection() }
    @objc private func handleCropSelected() { playlistManager.cropSelected(); listView.clampScroll() }
    @objc private func handleClearPlaylist() { playlistManager.clear(); listView.clampScroll() }
    @objc private func handleRemoveMissing() { playlistManager.removeMissing(); listView.clampScroll() }
    @objc private func handleSelectAll() { playlistManager.selectAll(); listView.needsDisplay = true }
    @objc private func handleSelectNone() { playlistManager.selectNone(); listView.needsDisplay = true }
    @objc private func handleInvertSelection() { playlistManager.invertSelection(); listView.needsDisplay = true }
    @objc private func handleSortByTitle() { playlistManager.sortByTitle() }
    @objc private func handleSortByFilename() { playlistManager.sortByFilename() }
    @objc private func handleSortByPath() { playlistManager.sortByPath() }
    @objc private func handleSortByDuration() { playlistManager.sortByDuration() }
    @objc private func handleReverseList() { playlistManager.reverseOrder() }
    @objc private func handleRandomizeList() { PlayerController.shared.randomizePlaylist() }
    @objc private func handleJumpToFile() { onOpenJumpToFile?() }
    @objc private func handleSaveList() { PlayerController.shared.savePlaylistPanel() }
    @objc private func handleLoadList() { PlayerController.shared.loadPlaylistPanel() }
}

// MARK: - Playlist Window

/// The playlist rolled up to its title bar: current track and time in the skin's bitmap font.
public final class PlaylistShadeView: SkinnedContentView {
    public let unshadeButton = SkinnedButton(frame: .zero, normal: nil, pressed: Sprite("PLEDIT.BMP", 150, 42, 9, 9))
    public let closeButton = SkinnedButton(frame: .zero, normal: nil, pressed: Sprite("PLEDIT.BMP", 52, 42, 9, 9))
    private var observers: [NSObjectProtocol] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [unshadeButton, closeButton].forEach { addSubview($0) }
        let nc = NotificationCenter.default
        for name in [Notification.Name.ampTrackChanged, .ampPlaylistChanged, .ampPlaybackStateChanged, .ampSkinChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true })
        }
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    public override func relayout() {
        let w = bounds.width
        unshadeButton.frame = NSRect(x: w - 20, y: 3, width: 9, height: 9)
        closeButton.frame = NSRect(x: w - 11, y: 3, width: 9, height: 9)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = cgContext else { return }
        let skin = SkinEngine.shared
        let sheet = skin.getCGImage(named: "PLEDIT.BMP")
        let w = bounds.width
        // Left cap, tiled middle, right cap (lit when focused).
        ctx.drawSprite(sheet, src: CGRect(x: 72, y: 42, width: 25, height: 14), dst: CGRect(x: 0, y: 0, width: 25, height: 14))
        var x: CGFloat = 25
        while x < w - 50 {
            let seg = min(25, w - 50 - x)
            ctx.drawSprite(sheet, src: CGRect(x: 72, y: 57, width: seg, height: 14), dst: CGRect(x: x, y: 0, width: seg, height: 14))
            x += seg
        }
        ctx.drawSprite(sheet, src: CGRect(x: 99, y: isKeyWindow ? 42 : 57, width: 50, height: 14),
                       dst: CGRect(x: w - 50, y: 0, width: 50, height: 14))

        // "N. Artist - Title" on the left, track length (or time left while playing) on the right.
        let engine = AudioEngine.shared
        let pl = PlayerController.shared.playlist
        let track = engine.currentTrack ?? pl.currentIndex.flatMap { $0 < pl.count ? pl.tracks[$0] : nil }
        guard let t = track else { return }
        let number = pl.tracks.firstIndex { $0.id == t.id }.map { "\($0 + 1). " } ?? ""
        let time = RetroLCDView.shortTime(t.duration)
        let timeW = CGFloat(time.count) * SkinEngine.glyphWidth
        let timeX = w - 32 - timeW
        skin.drawBitmapText(time, at: CGPoint(x: timeX, y: 4), in: ctx)
        skin.drawBitmapText("\(number)\(t.displayTitle)", at: CGPoint(x: 5, y: 4), in: ctx, maxWidth: timeX - 5 - 5)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            WindowManager.shared.toggleShade(.playlist)
        } else {
            beginWindowDrag(event)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let menu = NSApp.mainMenu.flatMap(AppDelegate.contextMenu(from:)) {
            SkinnedMenu.popUpContextMenu(menu, with: event)
        }
    }
}

public final class PlaylistWindow: BaseSkinnedWindow, Shadeable {
    public let shadeView = PlaylistShadeView(frame: NSRect(x: 0, y: 0, width: 275, height: 14))
    public var defaultUnshadedHeight: CGFloat { 232 }

    public func applyShade(_ shaded: Bool) {
        contentView = shaded ? shadeView : playlistView
    }

    public let playlistView: PlaylistContentView
    public let playlistManager: PlaylistManager
    public var jumpToFileWindow: JumpToFileWindow?
    private var observers: [NSObjectProtocol] = []

    public init(playlistManager: PlaylistManager) {
        self.playlistManager = playlistManager
        playlistView = PlaylistContentView(playlistManager: playlistManager, frame: NSRect(x: 0, y: 0, width: 275, height: 232))
        super.init(id: .playlist, contentRect: NSRect(x: 200, y: 152, width: 275, height: 232))
        contentView = playlistView
        setupBindings()
    }

    private func setupBindings() {
        playlistView.onOpenJumpToFile = { [weak self] in self?.openJumpToFile() }
        shadeView.unshadeButton.onAction = { WindowManager.shared.setShaded(.playlist, false) }
        shadeView.closeButton.onAction = { WindowManager.shared.setVisible(.playlist, false) }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .ampPlaylistChanged, object: nil, queue: .main) { [weak self] _ in
            self?.playlistView.listView.clampScroll()
            self?.playlistView.needsDisplay = true
        })
        observers.append(nc.addObserver(forName: .ampTrackChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if let idx = self.playlistManager.currentIndex { self.playlistView.listView.scrollToVisible(idx) }
            self.playlistView.listView.needsDisplay = true
        })
        observers.append(nc.addObserver(forName: .ampPlaybackStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.playlistView.needsDisplay = true
        })
        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main) { [weak self] _ in
            self?.updateMiniTimeTimer()
        })
        observers.append(nc.addObserver(forName: .ampPlaybackStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateMiniTimeTimer()
        })
        updateMiniTimeTimer()
    }

    /// Mini time readout: ticks only while playing and actually visible.
    private var miniTimeTimer: Timer?
    private var drawnMiniSeconds = -1

    private func updateMiniTimeTimer() {
        let needed = isVisible && occlusionState.contains(.visible) && AudioEngine.shared.state == .playing
        if needed, miniTimeTimer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, self.contentView === self.playlistView else { return }
                let s = Track.wholeSeconds(AudioEngine.shared.currentTime.rounded(.down))
                if s != self.drawnMiniSeconds {
                    self.drawnMiniSeconds = s
                    self.playlistView.setNeedsDisplay(self.playlistView.miniTimeRect)
                }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            miniTimeTimer = t
        } else if !needed, let t = miniTimeTimer {
            t.invalidate()
            miniTimeTimer = nil
        }
    }

    public override func becomeKey() {
        super.becomeKey()
        // The list isn't in the window while it's rolled up.
        if playlistView.listView.window === self { makeFirstResponder(playlistView.listView) }
    }

    public func openJumpToFile() {
        if jumpToFileWindow == nil {
            let jump = JumpToFileWindow(playlistManager: playlistManager)
            jump.onTrackSelected = { [weak self] track in
                guard let self = self, let idx = self.playlistManager.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                PlayerController.shared.play(index: idx)
                self.playlistManager.setSelection([idx])
                self.playlistView.listView.scrollToVisible(idx)
            }
            jumpToFileWindow = jump
        }
        jumpToFileWindow?.present(relativeTo: isVisible ? self : WindowManager.shared.mainWindow)
    }
}

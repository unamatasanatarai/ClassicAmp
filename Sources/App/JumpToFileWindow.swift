import AppKit

public final class JumpToFileWindow: NSWindow, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public var onTrackSelected: ((Track) -> Void)?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var searchResults: [Track] = []
    private let playlistManager: PlaylistManager

    public init(playlistManager: PlaylistManager) {
        self.playlistManager = playlistManager
        let rect = NSRect(x: 0, y: 0, width: 340, height: 260)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.title = "Jump to File"
        self.isReleasedWhenClosed = false
        self.level = .floating
        setupUI()
    }

    private func setupUI() {
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true

        let visualEffect = NSVisualEffectView(frame: contentView.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        contentView.addSubview(visualEffect)

        // Search field
        searchField.frame = NSRect(x: 12, y: 215, width: 316, height: 26)
        searchField.placeholderString = "Search artist, title, or filename..."
        searchField.delegate = self
        searchField.focusRingType = .none
        visualEffect.addSubview(searchField)

        // Table View
        scrollView.frame = NSRect(x: 12, y: 12, width: 316, height: 195)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TrackCol"))
        col.title = "Tracks"
        col.width = 300
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        visualEffect.addSubview(scrollView)
    }

    /// The window is kept for reuse; drop its results when hidden so it doesn't pin a copy of
    /// the whole playlist (the next playlist edit would otherwise duplicate the array).
    public override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        releaseResults()
    }

    public override func close() {
        super.close()
        releaseResults()
    }

    private func releaseResults() {
        guard !searchResults.isEmpty else { return }
        searchResults = []
        tableView.reloadData()
    }

    public func present(relativeTo parentWindow: NSWindow?) {
        searchField.stringValue = ""
        performSearch(query: "")
        if let parent = parentWindow {
            let center = NSPoint(
                x: parent.frame.midX - frame.width / 2,
                y: parent.frame.midY - frame.height / 2
            )
            setFrameOrigin(center)
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    public func controlTextDidChange(_ obj: Notification) {
        performSearch(query: searchField.stringValue)
    }

    private func performSearch(query: String) {
        searchResults = playlistManager.search(query: query)
        tableView.reloadData()
        if !searchResults.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        title = query.isEmpty ? "Jump to File" : "Jump to File — \(searchResults.count) match\(searchResults.count == 1 ? "" : "es")"
    }

    /// The search field's editor swallows arrows/return/escape, so route those commands here.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)): confirmSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): orderOut(nil); return true
        default: return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        let r = max(0, min(searchResults.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }

    public override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            orderOut(nil)
            return
        } else if event.keyCode == 36 { // Enter
            confirmSelection()
            return
        } else if event.keyCode == 126 { // Up arrow
            let selected = tableView.selectedRow
            if selected > 0 {
                tableView.selectRowIndexes(IndexSet(integer: selected - 1), byExtendingSelection: false)
                tableView.scrollRowToVisible(selected - 1)
            }
            return
        } else if event.keyCode == 125 { // Down arrow
            let selected = tableView.selectedRow
            if selected + 1 < searchResults.count {
                tableView.selectRowIndexes(IndexSet(integer: selected + 1), byExtendingSelection: false)
                tableView.scrollRowToVisible(selected + 1)
            }
            return
        }
        super.keyDown(with: event)
    }

    private func confirmSelection() {
        let row = tableView.selectedRow
        guard row >= 0 && row < searchResults.count else { return }
        let track = searchResults[row]
        orderOut(nil)
        onTrackSelected?(track)
    }

    @objc private func handleDoubleClick() {
        confirmSelection()
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return searchResults.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < searchResults.count else { return nil }
        let track = searchResults[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("JumpCell")
        var textField = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField
        if textField == nil {
            textField = NSTextField(labelWithString: "")
            textField?.identifier = cellIdentifier
            textField?.isBordered = false
            textField?.drawsBackground = false
            textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        textField?.stringValue = "\(track.displayTitle) [\(track.formattedDuration)]"
        return textField
    }
}

import Cocoa

public final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var appearanceObservation: NSKeyValueObservation?

    public weak var windowManager: WindowManager?
    public weak var playlistWindow: PlaylistWindow?

    public override init() {
        super.init()
        setupStatusItem()
        setupMenu()
        setupAppearanceObserver()
    }

    public var currentMenu: NSMenu {
        return menu
    }

    public var currentStatusItem: NSStatusItem {
        return statusItem
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = "\(AppConfig.appName) — click to show, right-click for menu"
            // No menu attached: clicks come here so left and right can do different things.
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
    }

    private func setupAppearanceObserver() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateIcon()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }
    }

    public func updateIcon() {
        guard let button = statusItem.button else { return }
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let isDark = (appearance == .darkAqua)
        button.image = Self.logoIcon ?? Self.renderBadgeIcon(isDark: isDark)
    }

    /// The app logo from the bundle, sized for the menu bar (falls back to the drawn badge).
    public static let logoIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "app-logo", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }()

    public static func renderBadgeIcon(isDark: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let badgeRect = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: badgeRect, xRadius: 3.5, yRadius: 3.5)

            let bgColor = isDark ? NSColor.white : NSColor.black
            let textColor = isDark ? NSColor.black : NSColor.white

            bgColor.setFill()
            path.fill()

            let font = NSFont.systemFont(ofSize: 10, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let str = NSAttributedString(string: "W", attributes: attrs)
            let strSize = str.size()
            let strRect = NSRect(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2 - 0.5,
                width: strSize.width,
                height: strSize.height
            )
            str.draw(in: strRect)
            return true
        }
        image.isTemplate = false
        return image
    }

    public func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false

        let appItem = NSMenuItem(title: "\(AppConfig.appName) v\(AppConfig.version)", action: nil, keyEquivalent: "")
        appItem.isEnabled = false
        menu.addItem(appItem)
        menu.addItem(NSMenuItem.separator())

        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        _ = add("Play", #selector(handlePlay))
        _ = add("Pause", #selector(handlePause))
        _ = add("Stop", #selector(handleStop))
        _ = add("Next Track", #selector(handleNext))
        _ = add("Previous Track", #selector(handlePrevious))
        menu.addItem(NSMenuItem.separator())
        shuffleItem = add("Shuffle", #selector(handleShuffle))
        repeatItem = add("Repeat", #selector(handleRepeat))
        _ = add("Randomize Playlist Order", #selector(handleRandomize))
        menu.addItem(NSMenuItem.separator())
        mainItem = add("Main Player", #selector(handleToggleMain))
        eqItem = add("Equalizer", #selector(handleToggleEQ))
        plItem = add("Playlist", #selector(handleTogglePL))
        _ = add("Show Player", #selector(handleShowPlayer))
        menu.addItem(NSMenuItem.separator())
        doubleItem = add("Double Size (2x)", #selector(handleToggleDoubleSize))
        onTopItem = add("Always on Top", #selector(handleToggleAlwaysOnTop))
        dockItem = add("Show Dock Icon", #selector(handleToggleDockIcon))
        menu.addItem(NSMenuItem.separator())
        _ = add("Load Skin (.wsz)...", #selector(handleLoadSkin))
        _ = add("Default Skin", #selector(handleDefaultSkin))
        menu.addItem(NSMenuItem.separator())
        defaultPlayerItem = add("Set \(AppConfig.appName) as Default Player", #selector(handleSetDefaultPlayer))
        menu.addItem(NSMenuItem.separator())
        _ = add("Quit \(AppConfig.appName)", #selector(handleQuit))

        menu.delegate = self
    }

    private var shuffleItem: NSMenuItem?
    private var repeatItem: NSMenuItem?
    private var mainItem: NSMenuItem?
    private var eqItem: NSMenuItem?
    private var plItem: NSMenuItem?
    private var doubleItem: NSMenuItem?
    private var onTopItem: NSMenuItem?
    private var dockItem: NSMenuItem?
    private var defaultPlayerItem: NSMenuItem?

    /// Left click: bring the player to the front. Right click (or Control-click): the menu.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if StatusBarController.wantsMenu(eventType: event?.type, modifiers: event?.modifierFlags ?? []) {
            showMenu()
        } else {
            StatusBarController.bringPlayerToFront()
        }
    }

    /// Right-click and Control-click open the menu; so does a press without a mouse event
    /// (VoiceOver / accessibility AXPress), the only way those users can reach the menu.
    static func wantsMenu(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch eventType {
        case .leftMouseUp?, .leftMouseDown?: return modifiers.contains(.control)
        case .rightMouseUp?, .rightMouseDown?: return true
        default: return true
        }
    }

    /// Pops the menu up under the icon (attaching it only for this click).
    public func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Unhides and activates the app and raises every player window that should be showing
    /// (keeping their docked arrangement); with all of them closed, shows the main window.
    public static func bringPlayerToFront() {
        let wm = WindowManager.shared
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let visible = WindowID.allCases.filter { wm.isVisible($0) }
        if visible.isEmpty { wm.setVisible(.main, true) }
        for id in WindowID.allCases where wm.isVisible(id) {
            wm.window(for: id)?.orderFront(nil)
        }
        let key = wm.isVisible(.main) ? wm.mainWindow : visible.first.flatMap { wm.window(for: $0) }
        key?.makeKeyAndOrderFront(nil)
    }

    @objc private func handlePlay() { PlayerController.shared.playFromButton() }
    @objc private func handlePause() { AudioEngine.shared.pause() }
    @objc private func handleStop() { AudioEngine.shared.stop() }
    @objc private func handleNext() { PlayerController.shared.playNext() }
    @objc private func handlePrevious() { PlayerController.shared.playPrevious() }
    @objc private func handleShuffle() { PlayerController.shared.toggleShuffle() }
    @objc private func handleRepeat() { PlayerController.shared.cycleRepeat() }
    @objc private func handleRandomize() { PlayerController.shared.randomizePlaylist() }
    @objc private func handleToggleMain() { WindowManager.shared.toggleVisible(.main) }
    @objc private func handleToggleEQ() { WindowManager.shared.toggleVisible(.equalizer) }
    @objc private func handleTogglePL() { WindowManager.shared.toggleVisible(.playlist) }
    @objc private func handleShowPlayer() {
        WindowManager.shared.setVisible(.main, true)
        StatusBarController.bringPlayerToFront()
    }
    @objc private func handleToggleDoubleSize() { WindowManager.shared.toggleDoubleSize() }
    @objc private func handleToggleAlwaysOnTop() { WindowManager.shared.toggleAlwaysOnTop() }
    @objc private func handleToggleDockIcon() { DockIcon.setVisible(!DockIcon.isVisible) }
    @objc private func handleLoadSkin() { PlayerController.shared.loadSkinPanel() }
    @objc private func handleDefaultSkin() { SkinEngine.shared.loadDefaultSkin() }
    @objc private func handleSetDefaultPlayer() { DefaultPlayer.makeDefaultInteractively() }
    @objc private func handleQuit() { NSApp.terminate(nil) }
}

extension StatusBarController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let wm = WindowManager.shared
        let pl = PlayerController.shared.playlist
        shuffleItem?.state = pl.shuffleEnabled ? .on : .off
        switch pl.repeatMode {
        case .off: repeatItem?.title = "Repeat: Off"; repeatItem?.state = .off
        case .all: repeatItem?.title = "Repeat: All"; repeatItem?.state = .on
        case .track: repeatItem?.title = "Repeat: Track"; repeatItem?.state = .on
        }
        mainItem?.state = wm.isVisible(.main) ? .on : .off
        eqItem?.state = wm.isVisible(.equalizer) ? .on : .off
        plItem?.state = wm.isVisible(.playlist) ? .on : .off
        doubleItem?.state = wm.isDoubleSize ? .on : .off
        onTopItem?.state = wm.isAlwaysOnTop ? .on : .off
        dockItem?.state = DockIcon.isVisible ? .on : .off
        defaultPlayerItem?.state = DefaultPlayer.isDefault ? .on : .off
    }
}

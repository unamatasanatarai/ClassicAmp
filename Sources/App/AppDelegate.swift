import Cocoa

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public private(set) var statusBarController: StatusBarController?
    public var playlistManager: PlaylistManager { PlayerController.shared.playlist }
    public private(set) var mainWindow: MainWindow?
    public private(set) var eqWindow: EqualizerWindow?
    public private(set) var playlistWindow: PlaylistWindow?

    private var observers: [NSObjectProtocol] = []
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(DockIcon.launchPolicy)

        setupWindows()
        setupMainMenu()
        let restored = AppStateManager.shared.restoreState(
            windowManager: WindowManager.shared,
            audioEngine: AudioEngine.shared,
            playlistManager: playlistManager
        )
        if !restored || playlistManager.tracks.isEmpty {
            loadStarterMusic()
        }
        setupPersistence()

        didFinishLaunching = true
        if !pendingOpenURLs.isEmpty {
            PlayerController.shared.ingest(pendingOpenURLs, autoplay: PlayerController.shared.autoplayOnAdd)
            pendingOpenURLs.removeAll()
        }

        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        // Non-critical UI after the windows are up.
        DispatchQueue.main.async { [weak self] in
            self?.setupStatusBar()
            // Advertise the restored track so the keyboard's media keys target this player.
            _ = PlayerController.shared
            MediaKeyMonitor.shared.start()
            let engine = AudioEngine.shared
            if AudioEngine.shouldClaimMediaKeysAtLaunch(restoredWasPlaying: AppStateManager.shared.restoredWasPlaying,
                                                        otherAudioPlaying: AudioEngine.isOtherAudioPlaying()) {
                engine.claimMediaKeys()
            } else {
                engine.updateNowPlayingInfo() // publish the track without taking the keys
            }
        }
        NSLog("%@ started successfully.", AppConfig.appName)
    }

    private func setupWindows() {
        let wm = WindowManager.shared
        let main = MainWindow()
        let eq = EqualizerWindow()
        let pl = PlaylistWindow(playlistManager: playlistManager)
        mainWindow = main
        eqWindow = eq
        playlistWindow = pl
        wm.mainWindow = main
        wm.eqWindow = eq
        wm.playlistWindow = pl

        PlayerController.shared.onShowJumpToFile = { [weak self] in self?.playlistWindow?.openJumpToFile() }
        main.syncControls()
    }

    private func setupStatusBar() {
        let sb = StatusBarController()
        sb.windowManager = WindowManager.shared
        sb.playlistWindow = playlistWindow
        statusBarController = sb
    }

    /// First launch: seed the playlist from the repository's sample library when present.
    private func loadStarterMusic() {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("start/music"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("start/music"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("start/music")
        ]
        if let dir = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            Events.status("LOADING SAMPLE LIBRARY...")
            PlayerController.shared.ingest([dir], autoplay: false)
        }
    }

    private func setupPersistence() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .ampStateDirty, object: nil, queue: .main) { _ in
            AppStateManager.shared.scheduleSave()
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                if note.object is BaseSkinnedWindow { AppStateManager.shared.scheduleSave() }
            })
        }
        // Keep the resume position fresh while playing (pause/stop/quit save immediately anyway).
        let t = Timer(timeInterval: 15, repeats: true) { _ in
            if AudioEngine.shared.state == .playing { AppStateManager.shared.saveNow() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        AppStateManager.shared.saveNow(synchronously: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            PlayerController.shared.ingest(urls, autoplay: PlayerController.shared.autoplayOnAdd)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !WindowManager.shared.isVisible(.main) { WindowManager.shared.setVisible(.main, true) }
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: - Main Menu

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let name = AppConfig.appName

        let appMenu = NSMenu(title: name)
        appMenu.addItem(item("About \(name)", #selector(handleAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(name)", #selector(handleQuitShortcut), "q"))
        addSubmenu(appMenu, to: mainMenu)

        let file = NSMenu(title: "File")
        file.addItem(item("Open Files…", #selector(handleOpenFile), "o"))
        file.addItem(item("Open Folder…", #selector(handleOpenFolder), "o", [.command, .shift]))
        file.addItem(item("Scan Music Library…", #selector(handleScanLibrary)))
        file.addItem(.separator())
        file.addItem(item("Load Playlist…", #selector(handleLoadPlaylist), "l", [.command, .shift]))
        file.addItem(item("Save Playlist…", #selector(handleSavePlaylist), "s"))
        file.addItem(.separator())
        file.addItem(item("Load Skin (.wsz)…", #selector(handleLoadSkin), "k"))
        file.addItem(item("Default Skin", #selector(handleDefaultSkin)))
        file.addItem(.separator())
        file.addItem(item("Set \(name) as Default Player", #selector(handleSetDefaultPlayer)))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(handleCloseWindow), "w"))
        addSubmenu(file, to: mainMenu)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        addSubmenu(edit, to: mainMenu)

        let play = NSMenu(title: "Playback")
        play.addItem(item("Play", #selector(handlePlay)))
        play.addItem(item("Play / Pause", #selector(handlePlayPause), "p"))
        play.addItem(item("Stop", #selector(handleStop), "."))
        play.addItem(item("Previous Track", #selector(handlePrevTrack), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))))
        play.addItem(item("Next Track", #selector(handleNextTrack), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))))
        play.addItem(.separator())
        play.addItem(item("Seek Backward 5s", #selector(handleSeekBackward), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option]))
        play.addItem(item("Seek Forward 5s", #selector(handleSeekForward), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option]))
        play.addItem(.separator())
        play.addItem(item("Volume Up", #selector(handleVolumeUp), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))))
        play.addItem(item("Volume Down", #selector(handleVolumeDown), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))))
        play.addItem(item("Mute", #selector(handleMute), "m", [.command, .shift]))
        play.addItem(.separator())
        play.addItem(item("Shuffle", #selector(handleShuffle), "s", [.command, .shift]))
        play.addItem(item("Randomize Playlist Order", #selector(handleRandomizeList), "r", [.command, .shift]))
        play.addItem(item("Repeat: Off", #selector(handleRepeatOff)))
        play.addItem(item("Repeat: All", #selector(handleRepeatAll)))
        play.addItem(item("Repeat: Track", #selector(handleRepeatTrack)))
        play.addItem(.separator())
        play.addItem(item("Autoplay Added Files", #selector(handleAutoplay)))
        addSubmenu(play, to: mainMenu)

        let view = NSMenu(title: "View")
        view.addItem(item("Double Size (2x)", #selector(handleDoubleSize), "d", [.command, .shift]))
        view.addItem(item("Always on Top", #selector(handleAlwaysOnTop), "t", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Main Player", #selector(handleToggleMain), "1"))
        view.addItem(item("Equalizer", #selector(handleToggleEQ), "2"))
        view.addItem(item("Playlist", #selector(handleTogglePL), "3"))
        view.addItem(.separator())
        view.addItem(item("Time Remaining", #selector(handleTimeMode), "e", [.command, .shift]))
        view.addItem(item("Visualizer: Spectrum", #selector(handleVisSpectrum)))
        view.addItem(item("Visualizer: Oscilloscope", #selector(handleVisOscilloscope)))
        view.addItem(item("Visualizer: Off", #selector(handleVisOff)))
        view.addItem(.separator())
        view.addItem(item("Jump to File…", #selector(handleJumpToFile), "j"))
        view.addItem(.separator())
        view.addItem(item("Reset Window Layout", #selector(handleResetLayout)))
        addSubmenu(view, to: mainMenu)

        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(handleMinimize), "m"))
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        addSubmenu(win, to: mainMenu)
        NSApp.windowsMenu = win

        NSApp.mainMenu = mainMenu
    }

    private func addSubmenu(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    /// Right-click / options-button menu assembled from the main menu's File, Playback and View menus.
    public static func contextMenu(from mainMenu: NSMenu) -> NSMenu? {
        let menu = NSMenu(title: AppConfig.appName)
        for title in ["File", "Playback", "View"] {
            guard let sub = mainMenu.items.first(where: { $0.submenu?.title == title })?.submenu,
                  let copy = sub.copy() as? NSMenu else { continue }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = copy
            menu.addItem(holder)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(AppConfig.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let wm = WindowManager.shared
        let pl = playlistManager
        let engine = AudioEngine.shared
        let main = mainWindow?.mainView
        func check(_ on: Bool) { menuItem.state = on ? .on : .off }
        switch menuItem.action {
        case #selector(handleSetDefaultPlayer): check(DefaultPlayer.isDefault)
        case #selector(handleDoubleSize): check(wm.isDoubleSize)
        case #selector(handleAlwaysOnTop): check(wm.isAlwaysOnTop)
        case #selector(handleToggleMain): check(wm.isVisible(.main))
        case #selector(handleToggleEQ): check(wm.isVisible(.equalizer))
        case #selector(handleTogglePL): check(wm.isVisible(.playlist))
        case #selector(handleShuffle): check(pl.shuffleEnabled)
        case #selector(handleRepeatOff): check(pl.repeatMode == .off)
        case #selector(handleRepeatAll): check(pl.repeatMode == .all)
        case #selector(handleRepeatTrack): check(pl.repeatMode == .track)
        case #selector(handleMute): check(engine.isMuted)
        case #selector(handleAutoplay): check(PlayerController.shared.autoplayOnAdd)
        case #selector(handleTimeMode): check(main?.lcdView.showRemainingTime ?? false)
        case #selector(handleVisSpectrum): check(main?.visualizerView.mode == .spectrum)
        case #selector(handleVisOscilloscope): check(main?.visualizerView.mode == .oscilloscope)
        case #selector(handleVisOff): check(main?.visualizerView.mode == .off)
        case #selector(handleDefaultSkin): return SkinEngine.shared.activeSkinURL != nil
        case #selector(handleRandomizeList): return pl.count > 1
        case #selector(handleStop), #selector(handleSeekForward), #selector(handleSeekBackward):
            return engine.state != .stopped
        default: break
        }
        return true
    }

    // MARK: - Actions

    @objc private func handleSetDefaultPlayer() { DefaultPlayer.makeDefaultInteractively() }

    @objc private func handleAbout() {
        let alert = NSAlert()
        alert.messageText = "\(AppConfig.appName) v\(AppConfig.version) (build \(AppConfig.buildNumber))"
        alert.informativeText = "High-fidelity local audio player with classic 2.x skin (.wsz) support.\nNo accounts, no telemetry, completely offline."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func handleOpenFile() { PlayerController.shared.openFilesPanel() }
    @objc private func handleOpenFolder() { PlayerController.shared.openFolderPanel() }
    /// ⌘Q needs a second press; choosing Quit with the mouse quits straight away.
    @objc private func handleQuitShortcut() {
        let fromKeyboard = NSApp.currentEvent?.type == .keyDown
        if !fromKeyboard || QuitConfirmation.registerQuitKeyPress() {
            NSApp.terminate(nil)
        }
    }

    @objc private func handleScanLibrary() { PlayerController.shared.scanMusicLibrary() }
    @objc private func handleLoadPlaylist() { PlayerController.shared.loadPlaylistPanel() }
    @objc private func handleSavePlaylist() { PlayerController.shared.savePlaylistPanel() }
    @objc private func handleLoadSkin() { PlayerController.shared.loadSkinPanel() }
    @objc private func handleDefaultSkin() { SkinEngine.shared.loadDefaultSkin(); Events.status("DEFAULT SKIN") }

    @objc private func handleCloseWindow() {
        if let w = NSApp.keyWindow as? BaseSkinnedWindow {
            WindowManager.shared.setVisible(w.windowID, false)
        } else {
            NSApp.keyWindow?.orderOut(nil)
        }
    }

    @objc private func handlePlay() { PlayerController.shared.playFromButton() }
    @objc private func handlePlayPause() { AudioEngine.shared.togglePlayPause() }
    @objc private func handleStop() { AudioEngine.shared.stop() }
    @objc private func handleNextTrack() { PlayerController.shared.playNext() }
    @objc private func handlePrevTrack() { PlayerController.shared.playPrevious() }
    @objc private func handleSeekForward() { AudioEngine.shared.seek(by: 5) }
    @objc private func handleSeekBackward() { AudioEngine.shared.seek(by: -5) }
    @objc private func handleVolumeUp() { PlayerController.shared.adjustVolume(by: 0.05) }
    @objc private func handleVolumeDown() { PlayerController.shared.adjustVolume(by: -0.05) }
    @objc private func handleMute() {
        AudioEngine.shared.isMuted.toggle()
        Events.status(AudioEngine.shared.isMuted ? "MUTED" : "UNMUTED")
    }
    @objc private func handleShuffle() { PlayerController.shared.toggleShuffle() }
    @objc private func handleRandomizeList() { PlayerController.shared.randomizePlaylist() }
    @objc private func handleRepeatOff() { playlistManager.repeatMode = .off }
    @objc private func handleRepeatAll() { playlistManager.repeatMode = .all }
    @objc private func handleRepeatTrack() { playlistManager.repeatMode = .track }
    @objc private func handleAutoplay() { PlayerController.shared.autoplayOnAdd.toggle() }

    @objc private func handleDoubleSize() { WindowManager.shared.toggleDoubleSize() }
    @objc private func handleAlwaysOnTop() { WindowManager.shared.toggleAlwaysOnTop() }
    @objc private func handleToggleMain() { WindowManager.shared.toggleVisible(.main) }
    @objc private func handleToggleEQ() { WindowManager.shared.toggleVisible(.equalizer) }
    @objc private func handleTogglePL() { WindowManager.shared.toggleVisible(.playlist) }
    @objc private func handleTimeMode() { mainWindow?.mainView.lcdView.showRemainingTime.toggle() }
    @objc private func handleVisSpectrum() { mainWindow?.mainView.visualizerView.mode = .spectrum }
    @objc private func handleVisOscilloscope() { mainWindow?.mainView.visualizerView.mode = .oscilloscope }
    @objc private func handleVisOff() { mainWindow?.mainView.visualizerView.mode = .off }
    @objc private func handleJumpToFile() { playlistWindow?.openJumpToFile() }
    @objc private func handleMinimize() { NSApp.hide(nil) }

    @objc private func handleResetLayout() {
        for id in WindowID.allCases { WindowManager.shared.window(for: id)?.orderFront(nil) }
        WindowManager.shared.applyDefaultGluedLayout()
        Events.post(.ampWindowsChanged)
        Events.markDirty()
    }
}

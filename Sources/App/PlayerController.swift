import AppKit
import UniformTypeIdentifiers

/// Coordinates the playlist and the audio engine: transport, queue advance, file ingestion.
public final class PlayerController {
    public static let shared = PlayerController()

    public let playlist = PlaylistManager()
    private let engine = AudioEngine.shared

    /// Start playing automatically when files are dropped in / opened from the desktop.
    public var autoplayOnAdd: Bool = true {
        didSet { Events.markDirty() }
    }
    public var lastMusicDirectory: URL?
    public var lastSkinDirectory: URL?

    public var onShowJumpToFile: (() -> Void)?

    private init() {
        engine.onPlaybackEnded = { [weak self] in self?.advanceAfterEnd() }
        engine.onPlaybackFailed = { [weak self] track in self?.handleFailure(track) }
        engine.onPlayRequestedWithoutTrack = { [weak self] in self?.playSelectedOrFirst() }
        engine.onNextRequested = { [weak self] in self?.playNext() }
        engine.onPreviousRequested = { [weak self] in self?.playPrevious() }
        engine.idleNowPlayingTrack = { [weak self] in
            guard let pl = self?.playlist, pl.count > 0 else { return nil }
            let idx = pl.currentIndex.flatMap { $0 < pl.count ? $0 : nil } ?? 0
            return pl.tracks[idx]
        }
        engine.nextGaplessTrack = { [weak self] current in self?.gaplessSuccessor(of: current) }
        engine.onGaplessAdvance = { [weak self] track in
            guard let self = self, let idx = self.playlist.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            self.playlist.currentIndex = idx
            Events.post(.ampPlaylistChanged)
        }
    }

    // MARK: - Transport

    public func play(index: Int) {
        guard index >= 0, index < playlist.count else { return }
        playlist.currentIndex = index
        engine.loadAndPlay(track: playlist.tracks[index])
        Events.post(.ampPlaylistChanged)
    }

    /// Play button semantics: resume when paused, restart current, or start the selection.
    public func playFromButton() {
        switch engine.state {
        case .paused: engine.play()
        case .playing:
            if let idx = playlist.currentIndex { play(index: idx) }
        case .stopped:
            if let idx = playlist.currentIndex, idx < playlist.count {
                play(index: idx)
            } else {
                playSelectedOrFirst()
            }
        }
    }

    public func playSelectedOrFirst() {
        guard playlist.count > 0 else {
            openFilesPanel()
            return
        }
        play(index: playlist.selectedIndices.first ?? playlist.currentIndex ?? 0)
    }

    public func playNext() {
        guard let idx = nextIndex(userInitiated: true) else { return }
        play(index: idx)
    }

    public func playPrevious() {
        guard let idx = playlist.previousIndex() else { return }
        play(index: idx)
    }

    private func nextIndex(userInitiated: Bool) -> Int? {
        // A manual "next" should move on even in repeat-one mode.
        if userInitiated && playlist.repeatMode == .track {
            playlist.repeatMode = .all
            defer { playlist.repeatMode = .track }
            return playlist.nextIndex()
        }
        return playlist.nextIndex()
    }

    private func advanceAfterEnd() {
        guard let idx = nextIndex(userInitiated: false) else {
            engine.stop()
            return
        }
        play(index: idx)
    }

    private func handleFailure(_ track: Track) {
        if let idx = playlist.tracks.firstIndex(where: { $0.id == track.id }) {
            var t = playlist.tracks[idx]
            t.missing = true
            playlist.updateTrack(t)
        }
        // Skip forward, but stop if every track in the list has failed in a row.
        guard engine.failureStreak < max(1, playlist.count), let next = nextIndex(userInitiated: false) else {
            engine.stop()
            return
        }
        play(index: next)
    }

    private func gaplessSuccessor(of current: Track) -> Track? {
        guard !playlist.shuffleEnabled, playlist.repeatMode != .track,
              let idx = playlist.tracks.firstIndex(where: { $0.id == current.id }),
              idx + 1 < playlist.count else { return nil }
        let next = playlist.tracks[idx + 1]
        return next.isGaplessSuccessor(of: current) ? next : nil
    }

    public func adjustVolume(by delta: Float) {
        engine.volume = max(0, min(1, engine.volume + delta))
        Events.status("VOLUME: \(Int((engine.volume * 100).rounded()))%")
        Events.post(.ampModesChanged)
    }

    public func toggleShuffle() {
        playlist.shuffleEnabled.toggle()
        Events.status(playlist.shuffleEnabled ? "SHUFFLE: ON" : "SHUFFLE: OFF")
    }

    public func cycleRepeat() {
        switch playlist.repeatMode {
        case .off: playlist.repeatMode = .all
        case .all: playlist.repeatMode = .track
        case .track: playlist.repeatMode = .off
        }
        let label: String
        switch playlist.repeatMode {
        case .off: label = "REPEAT: OFF"
        case .all: label = "REPEAT: ALL"
        case .track: label = "REPEAT: TRACK"
        }
        Events.status(label)
    }

    public func randomizePlaylist() {
        guard playlist.count > 1 else { return }
        playlist.randomizeOrder()
        Events.status("PLAYLIST RANDOMIZED")
    }

    public func showJumpToFile() {
        onShowJumpToFile?()
    }

    // MARK: - Ingestion

    /// Adds files/folders/playlists/CUE sheets (and applies dropped skins) in the background.
    public func ingest(_ urls: [URL], autoplay: Bool, insertAt: Int? = nil, completion: ((LibraryImporter.Result) -> Void)? = nil) {
        ingest(urls, autoplay: autoplay, insertAt: insertAt, showProgress: false, completion: completion)
    }

    private func ingest(_ urls: [URL], autoplay: Bool, insertAt: Int?, showProgress: Bool, completion: ((LibraryImporter.Result) -> Void)?) {
        guard !urls.isEmpty else { return }
        if let dir = urls.first(where: { $0.pathExtension.lowercased() != "wsz" }) {
            lastMusicDirectory = dir.hasDirectoryPath ? dir : dir.deletingLastPathComponent()
        }
        // Big folder imports take a while: show a running count in the display.
        let progress: LibraryImporter.Progress? = { done, total in
            guard showProgress || total >= 200 else { return }
            DispatchQueue.main.async { Events.status("LOADING \(done)/\(total)...") }
        }
        LibraryImporter.importAsync(urls, progress: progress) { [weak self] result in
            guard let self = self else { return }
            if let skin = result.skins.last {
                self.lastSkinDirectory = skin.deletingLastPathComponent()
                SkinEngine.shared.loadSkinAsync(at: skin)
            }
            if !result.tracks.isEmpty {
                let firstNew: Int
                if let at = insertAt {
                    firstNew = max(0, min(at, self.playlist.count))
                    self.playlist.insertTracks(result.tracks, at: firstNew)
                } else {
                    firstNew = self.playlist.count
                    self.playlist.addTracks(result.tracks)
                }
                if autoplay {
                    self.play(index: firstNew)
                }
            }
            completion?(result)
        }
    }

    // MARK: - Panels

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in ["flac", "cue", "m3u", "m3u8", "pls", "wsz", "ogg", "opus"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    public func openFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = audioTypes + [.folder]
        panel.directoryURL = lastMusicDirectory ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        panel.message = "Choose audio files, folders, playlists or CUE sheets"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            ingest(panel.urls, autoplay: autoplayOnAdd)
        }
    }

    public func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = lastMusicDirectory ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            ingest(panel.urls, autoplay: false)
        }
    }

    public func loadSkinPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let wsz = UTType(filenameExtension: "wsz") {
            panel.allowedContentTypes = [wsz, .zip, .folder]
        }
        panel.directoryURL = lastSkinDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Skins")
        panel.message = "Choose a classic 2.x skin (.wsz)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            lastSkinDirectory = url.deletingLastPathComponent()
            SkinEngine.shared.loadSkinAsync(at: url)
            Events.markDirty()
        }
    }

    public func scanMusicLibrary() {
        let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        Events.status("SCANNING MUSIC LIBRARY...")
        ingest([musicDir], autoplay: false, insertAt: nil, showProgress: true) { result in
            let alert = NSAlert()
            alert.messageText = "Music Library Import"
            alert.informativeText = """
            Added \(result.tracks.count) track\(result.tracks.count == 1 ? "" : "s") from \(musicDir.path).
            Skipped \(result.skippedStreaming) empty or cloud-only file\(result.skippedStreaming == 1 ? "" : "s") with no audio stored on this Mac.
            """
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    public func savePlaylistPanel() {
        let panel = NSSavePanel()
        var types: [UTType] = []
        for ext in ["m3u8", "m3u", "pls"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = "Playlist.m3u8"
        panel.directoryURL = lastMusicDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "pls" {
                try playlist.exportPLS(to: url)
            } else {
                try playlist.exportM3U(to: url)
            }
            Events.status("PLAYLIST SAVED")
        } catch {
            Events.status("SAVE FAILED: \(error.localizedDescription)")
        }
    }

    public func loadPlaylistPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = []
        for ext in ["m3u8", "m3u", "pls", "cue"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        panel.allowedContentTypes = types
        panel.directoryURL = lastMusicDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playlist.clear()
        engine.stop()
        ingest([url], autoplay: false)
    }
}

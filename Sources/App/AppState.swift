import Foundation
import AppKit

public struct SavedWindowState: Codable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var isVisible: Bool
    /// Rolled up to the title bar; x/y/width/height then describe the unrolled frame.
    public var isShaded: Bool? = nil
}

public struct SavedBond: Codable {
    public var a: String
    public var b: String
}

public struct ApplicationState: Codable {
    public var windows: [String: SavedWindowState] = [:]
    public var bonds: [SavedBond] = []
    public var isDoubleSize: Bool = false
    public var isAlwaysOnTop: Bool = false

    public var volume: Float = 0.8
    public var balance: Float = 0.0
    public var isMuted: Bool = false

    public var eqEnabled: Bool = true
    public var autoPresetEnabled: Bool = false
    public var currentPresetName: String = "Flat"
    public var preampGain: Float = 0.0
    public var eqBandGains: [Float] = Array(repeating: 0.0, count: 10)
    public var customPresets: [EqualizerPreset] = []

    public var activeSkinPath: String?
    public var lastMusicDirectory: String?
    public var lastSkinDirectory: String?

    public var playlistTracks: [Track] = []
    public var currentTrackIndex: Int?
    public var selectedIndices: [Int] = []
    public var playbackPosition: TimeInterval = 0
    public var wasPlaying: Bool = false

    public var shuffleEnabled: Bool = false
    public var repeatMode: RepeatMode = .all
    public var autoplayOnAdd: Bool = true
    public var visualizerMode: Int = 0
    public var showRemainingTime: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case windows, bonds, isDoubleSize, isAlwaysOnTop, volume, balance, isMuted
        case eqEnabled, autoPresetEnabled, currentPresetName, preampGain, eqBandGains, customPresets
        case activeSkinPath, lastMusicDirectory, lastSkinDirectory
        case playlistTracks, currentTrackIndex, selectedIndices, playbackPosition, wasPlaying
        case shuffleEnabled, repeatMode, autoplayOnAdd, visualizerMode, showRemainingTime
    }

    /// Tolerant decoding: any missing or malformed field falls back to its default,
    /// so an older or partially corrupt state file never prevents launch.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        windows = v(.windows, [:])
        bonds = v(.bonds, [])
        isDoubleSize = v(.isDoubleSize, false)
        isAlwaysOnTop = v(.isAlwaysOnTop, false)
        volume = v(.volume, 0.8)
        balance = v(.balance, 0)
        isMuted = v(.isMuted, false)
        eqEnabled = v(.eqEnabled, true)
        autoPresetEnabled = v(.autoPresetEnabled, false)
        currentPresetName = v(.currentPresetName, "Flat")
        preampGain = v(.preampGain, 0)
        eqBandGains = v(.eqBandGains, Array(repeating: 0, count: 10))
        if eqBandGains.count != 10 { eqBandGains = Array(repeating: 0, count: 10) }
        customPresets = v(.customPresets, [])
        activeSkinPath = v(.activeSkinPath, nil as String?)
        lastMusicDirectory = v(.lastMusicDirectory, nil as String?)
        lastSkinDirectory = v(.lastSkinDirectory, nil as String?)
        // Decode tracks one by one so a single bad entry doesn't drop the whole playlist.
        if let raw = try? c.decodeIfPresent([FailableTrack].self, forKey: .playlistTracks) {
            playlistTracks = raw.compactMap { $0.track }
        }
        currentTrackIndex = v(.currentTrackIndex, nil as Int?)
        selectedIndices = v(.selectedIndices, [])
        playbackPosition = v(.playbackPosition, 0)
        wasPlaying = v(.wasPlaying, false)
        shuffleEnabled = v(.shuffleEnabled, false)
        repeatMode = v(.repeatMode, .all)
        autoplayOnAdd = v(.autoplayOnAdd, true)
        visualizerMode = v(.visualizerMode, 0)
        showRemainingTime = v(.showRemainingTime, false)
    }
}

private struct FailableTrack: Decodable {
    let track: Track?
    init(from decoder: Decoder) throws {
        track = try? Track(from: decoder)
    }
}

public final class AppStateManager {
    public static let shared = AppStateManager()

    private var saveTimer: Timer?
    private let stateURL = AppConfig.stateFileURL
    private let playlistURL = AppConfig.playlistFileURL
    /// Revision of the playlist last handed to the writer (nil: never written this session).
    private var savedPlaylistRevision: Int?
    private let ioQueue = DispatchQueue(label: "com.classic.amp.state.io", qos: .utility)
    /// Suppresses saves while restoring (restoration itself fires change events).
    public private(set) var isRestoring = false
    /// Whether the previous session quit while playing (drives the launch-time media-key claim).
    public private(set) var restoredWasPlaying = false

    private init() {}

    /// Debounced (500 ms) save.
    public func scheduleSave() {
        guard !isRestoring else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    public func saveNow(synchronously: Bool = false) {
        guard !isRestoring else { return }
        saveTimer?.invalidate()
        saveTimer = nil
        let state = captureState()
        let pl = PlayerController.shared.playlist
        // The playlist (MBs for big libraries) is rewritten only when it was edited.
        let tracks: [Track]? = pl.revision == savedPlaylistRevision ? nil : pl.tracks
        let revision = pl.revision
        savedPlaylistRevision = revision
        let url = stateURL, playlistURL = self.playlistURL
        let write = { [weak self] in
            do {
                let payloads = try AppStateManager.encodePayloads(state: state, tracks: tracks)
                if let p = payloads.playlist { try p.write(to: playlistURL, options: .atomic) }
                try payloads.state.write(to: url, options: .atomic)
            } catch {
                NSLog("Failed to save state: %@", error.localizedDescription)
                // Make the next save retry the playlist.
                DispatchQueue.main.async { if self?.savedPlaylistRevision == revision { self?.savedPlaylistRevision = nil } }
            }
        }
        if synchronously {
            ioQueue.sync(execute: write)
        } else {
            ioQueue.async(execute: write)
        }
    }

    private func captureState() -> ApplicationState {
        let wm = WindowManager.shared
        let engine = AudioEngine.shared
        let player = PlayerController.shared
        let pl = player.playlist
        var state = ApplicationState()

        for id in WindowID.allCases {
            if let w = wm.window(for: id) {
                var f = w.frame
                let shaded = wm.isShaded(id)
                if shaded, let full = wm.unshadedHeights[id] {
                    f = NSRect(x: f.minX, y: f.maxY - full * wm.scale, width: f.width, height: full * wm.scale)
                }
                state.windows[id.rawValue] = SavedWindowState(x: f.minX, y: f.minY, width: f.width,
                                                              height: f.height, isVisible: w.isVisible, isShaded: shaded)
            }
        }
        wm.recomputeBonds()
        state.bonds = wm.gluedBonds.map { SavedBond(a: $0.a.rawValue, b: $0.b.rawValue) }
        state.isDoubleSize = wm.isDoubleSize
        state.isAlwaysOnTop = wm.isAlwaysOnTop

        state.volume = engine.volume
        state.balance = engine.balance
        state.isMuted = engine.isMuted
        state.eqEnabled = engine.eqEnabled
        state.autoPresetEnabled = engine.autoPresetEnabled
        state.currentPresetName = engine.currentPresetName
        state.preampGain = engine.preampGain
        state.eqBandGains = engine.eqBandGains
        state.customPresets = EqualizerPresets.customPresets

        state.activeSkinPath = SkinEngine.shared.activeSkinURL?.path
        state.lastMusicDirectory = player.lastMusicDirectory?.path
        state.lastSkinDirectory = player.lastSkinDirectory?.path

        // Tracks are persisted separately (playlist.json) — see saveNow().
        // Remember the track actually loaded in the engine, if it is in the list.
        if let current = engine.currentTrack, let idx = pl.tracks.firstIndex(where: { $0.id == current.id }) {
            state.currentTrackIndex = idx
        } else {
            state.currentTrackIndex = pl.currentIndex
        }
        state.selectedIndices = Array(pl.selectedIndices)
        state.playbackPosition = engine.currentTime
        state.wasPlaying = engine.state == .playing
        state.shuffleEnabled = pl.shuffleEnabled
        state.repeatMode = pl.repeatMode
        state.autoplayOnAdd = player.autoplayOnAdd

        if let main = wm.mainWindow as? MainWindow {
            state.visualizerMode = main.mainView.visualizerView.mode.rawValue
            state.showRemainingTime = main.mainView.lcdView.showRemainingTime
        }
        return state
    }

    /// state.json never embeds the playlist; it goes to playlist.json, and only when given.
    static func encodePayloads(state: ApplicationState, tracks: [Track]?) throws -> (state: Data, playlist: Data?) {
        var slim = state
        slim.playlistTracks = []
        let stateData = try JSONEncoder().encode(slim)
        let playlistData = try tracks.map { try JSONEncoder().encode($0) }
        return (stateData, playlistData)
    }

    /// Tolerant decode: one corrupt entry doesn't drop the whole playlist.
    static func decodePlaylist(_ data: Data) -> [Track]? {
        (try? JSONDecoder().decode([FailableTrack].self, from: data))?.compactMap { $0.track }
    }

    public func loadState() -> ApplicationState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try JSONDecoder().decode(ApplicationState.self, from: data)
        } catch {
            NSLog("state.json unreadable (%@); starting fresh", error.localizedDescription)
            return nil
        }
    }

    /// Restores everything. Returns false when there was no saved state (first launch).
    @discardableResult
    public func restoreState(windowManager wm: WindowManager, audioEngine engine: AudioEngine, playlistManager pl: PlaylistManager) -> Bool {
        isRestoring = true
        defer { isRestoring = false }

        guard let state = loadState() else {
            wm.applyDefaultGluedLayout()
            return false
        }
        let player = PlayerController.shared

        if state.isDoubleSize { wm.setDoubleSize(true) }
        wm.setAlwaysOnTop(state.isAlwaysOnTop)

        for id in WindowID.allCases {
            guard let w = wm.window(for: id) else { continue }
            if let s = state.windows[id.rawValue], s.width > 0, s.height > 0 {
                let minH = (id == .playlist ? PlaylistContentView.minHeight : 116) * wm.scale
                w.setFrame(NSRect(x: s.x, y: s.y, width: 275 * wm.scale, height: max(minH, id == .playlist ? s.height : 116 * wm.scale)),
                           display: false)
                if s.isVisible { w.orderFront(nil) } else { w.orderOut(nil) }
            } else {
                w.orderFront(nil)
            }
        }
        for id in WindowID.allCases {
            if let s = state.windows[id.rawValue], s.isShaded == true, let w = wm.window(for: id) {
                wm.restoreShade(id, unshadedHeight: w.frame.height / wm.scale)
            }
        }
        wm.ensureWindowsOnScreen()
        wm.fitClusterOnScreen()
        wm.recomputeBonds()

        engine.volume = state.volume
        engine.balance = state.balance
        // Mute is a momentary toggle: never start a session silent.
        engine.isMuted = false
        engine.eqEnabled = state.eqEnabled
        engine.autoPresetEnabled = state.autoPresetEnabled
        engine.preampGain = state.preampGain
        engine.eqBandGains = state.eqBandGains
        engine.currentPresetName = state.currentPresetName
        EqualizerPresets.customPresets = state.customPresets
        Events.post(.ampEQChanged)

        if let path = state.activeSkinPath, FileManager.default.fileExists(atPath: path) {
            SkinEngine.shared.loadSkin(at: URL(fileURLWithPath: path))
        }
        player.lastMusicDirectory = state.lastMusicDirectory.map { URL(fileURLWithPath: $0) }
        player.lastSkinDirectory = state.lastSkinDirectory.map { URL(fileURLWithPath: $0) }
        player.autoplayOnAdd = state.autoplayOnAdd

        if let main = wm.mainWindow as? MainWindow {
            main.mainView.visualizerView.mode = VisualizerMode(rawValue: state.visualizerMode) ?? .spectrum
            main.mainView.lcdView.showRemainingTime = state.showRemainingTime
        }

        // playlist.json wins; tracks embedded in an older state.json are migrated on the next save.
        let savedTracks = (try? Data(contentsOf: playlistURL)).flatMap(AppStateManager.decodePlaylist)
        // Only the track about to be loaded is checked now; the rest are stat'ed in the background.
        pl.setTracks(savedTracks ?? state.playlistTracks, validate: false)
        pl.validateMissingStatusAsync()
        restoredWasPlaying = state.wasPlaying
        pl.repeatMode = state.repeatMode
        if let idx = state.currentTrackIndex, idx >= 0, idx < pl.count {
            pl.currentIndex = idx
        }
        pl.shuffleEnabled = state.shuffleEnabled
        pl.setSelection(IndexSet(state.selectedIndices))

        if let idx = pl.currentIndex {
            let track = pl.tracks[idx]
            if FileManager.default.fileExists(atPath: track.url.path) {
                // Resume within the exact second, paused (the player never auto-blasts audio on launch).
                // Deferred one run-loop turn so the windows are on screen before the audio graph spins up.
                let position = state.playbackPosition
                DispatchQueue.main.async {
                    guard engine.currentTrack == nil else { return }
                    engine.load(track: track, startOffset: position, autoplay: false)
                }
            }
        }
        Events.post(.ampModesChanged)
        Events.post(.ampWindowsChanged)
        return true
    }
}

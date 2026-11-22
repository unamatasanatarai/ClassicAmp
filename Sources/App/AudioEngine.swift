import Foundation
import AppKit
import AVFoundation
import Accelerate
import MediaPlayer

public enum PlaybackState {
    case playing
    case paused
    case stopped
}

public final class AudioEngine {
    public static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
    /// Post-EQ mixer: carries the stereo balance (pan) into the main mixer and hosts the visualizer tap.
    private let balanceNode = AVAudioMixerNode()
    private var connectedFormat: AVAudioFormat?
    private var tapInstalled = false

    // MARK: Public state

    public private(set) var state: PlaybackState = .stopped
    public private(set) var currentTrack: Track?

    public var volume: Float = 0.8 {
        didSet {
            volume = min(1, max(0, volume))
            // Touching the volume (slider, arrow keys, wheel) always brings the sound back.
            if isMuted && volume != oldValue { isMuted = false }
            updateVolume()
            Events.markDirty()
        }
    }

    public var isMuted: Bool = false {
        didSet { updateVolume(); Events.post(.ampModesChanged); Events.markDirty() }
    }

    public var balance: Float = 0.0 { // -1.0 (left) ... +1.0 (right)
        didSet { balance = min(1, max(-1, balance)); balanceNode.pan = balance; Events.markDirty() }
    }

    public var eqEnabled: Bool = true {
        didSet { updateEQBypass(); Events.post(.ampEQChanged); Events.markDirty() }
    }

    public var preampGain: Float = 0.0 { // dB (-12 ... +12)
        didSet { preampGain = min(12, max(-12, preampGain)); updatePreamp(); updateEQBypass(); Events.markDirty() }
    }

    /// A flat EQ (all bands and preamp at 0 dB) is an identity filter: bypass it so the
    /// 10 biquads per channel don't run on the render thread for nothing.
    static func eqIsFlat(preamp: Float, bands: [Float]) -> Bool {
        preamp == 0 && bands.allSatisfy { $0 == 0 }
    }

    private func updateEQBypass() {
        let bypass = !eqEnabled || AudioEngine.eqIsFlat(preamp: preampGain, bands: eqBandGains)
        if eqNode.bypass != bypass { eqNode.bypass = bypass }
    }

    public var autoPresetEnabled: Bool = false {
        didSet { Events.markDirty() }
    }
    public var currentPresetName: String = "Flat"
    public var eqBandGains: [Float] = Array(repeating: 0.0, count: 10) {
        didSet { applyBandGains(); updateEQBypass(); Events.markDirty() }
    }

    // MARK: Callbacks (single owner each; UI observers use notifications instead)

    public var onPlaybackEnded: (() -> Void)?
    /// Called when a track cannot be opened. The playlist controller decides whether to skip.
    public var onPlaybackFailed: ((Track) -> Void)?
    /// Asked for the track that should follow `current` seamlessly (same file, contiguous CUE segment).
    public var nextGaplessTrack: ((Track) -> Track?)?
    /// Notified when playback crossed a gapless boundary into `track`.
    public var onGaplessAdvance: ((Track) -> Void)?
    /// Asked to start something when Play is pressed with nothing loaded.
    public var onPlayRequestedWithoutTrack: (() -> Void)?
    public var onNextRequested: (() -> Void)?
    public var onPreviousRequested: (() -> Void)?

    // MARK: Scheduling

    private struct Segment {
        let track: Track
        let file: AVAudioFile
        let startFrame: AVAudioFramePosition
        /// Can exceed `AVAudioFrameCount` (UInt32) for very long files; scheduled in chunks.
        let frameCount: AVAudioFramePosition
        /// Seconds into the track at which this segment begins (non-zero after a seek).
        let trackOffset: TimeInterval
    }

    private var generation = 0
    private var segments: [Segment] = []
    /// Player sample time at which `segments[0]` began.
    private var segmentPlayerStartFrame: AVAudioFramePosition = 0
    private var pausedTime: TimeInterval = 0
    private var consecutiveFailures = 0

    // MARK: Visualizer capture

    private let captureLock = NSLock()
    private var captureSamples: [Float] = []
    private var captureSampleRate: Double = 44100
    private var captureTime: CFAbsoluteTime = 0

    private let fftSize = 1024

    /// Cover art per audio file (CUE segments share their file's art). `nil` value = file has
    /// none, so play/pause doesn't re-read the tags. Kept tiny: only the current track needs it.
    private var artworkCache: [URL: NSImage?] = [:]
    private var artworkLoading: Set<URL> = []

    private init() {
        // The audio graph and media-key registration are built lazily / after launch so the
        // windows can appear immediately (cold start budget: 200 ms).
        DispatchQueue.main.async { [weak self] in self?.setupMediaRemoteCommands() }
    }

    private var graphReady = false

    /// Builds the AVAudioEngine graph on first use.
    private func ensureGraph() {
        guard !graphReady else { return }
        graphReady = true
        setupAudioEngine()
    }



    // MARK: - Engine Setup

    private func setupAudioEngine() {
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(balanceNode)

        for (i, freq) in EqualizerPresets.bandFrequencies.enumerated() {
            let band = eqNode.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1.0
            band.gain = 0.0
            band.bypass = false
        }
        applyBandGains()
        updateEQBypass()

        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        // Output first: connectGraph installs the visualizer tap on balanceNode, and a tap
        // installed before the node's output is connected may never receive buffers.
        engine.connect(balanceNode, to: engine.mainMixerNode, format: nil)
        connectGraph(format: defaultFormat)
        balanceNode.pan = balance

        updateVolume()
        updatePreamp()
        engine.prepare()

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func connectGraph(format: AVAudioFormat) {
        if tapInstalled {
            balanceNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(eqNode)
        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: balanceNode, format: format)
        connectedFormat = format
        installTap()
    }

    private var analysisEnabled = true

    /// The visualizer tap is only installed while something displays it.
    public func setAnalysisEnabled(_ enabled: Bool) {
        guard enabled != analysisEnabled else { return }
        analysisEnabled = enabled
        if enabled {
            installTap()
        } else if tapInstalled {
            balanceNode.removeTap(onBus: 0)
            tapInstalled = false
            captureLock.lock()
            captureSamples.removeAll()
            captureLock.unlock()
        }
    }

    private func installTap() {
        guard graphReady, !tapInstalled, analysisEnabled else { return }
        // ~11 tap callbacks per second instead of ~43: analyze() slides its 1024-sample window
        // through the latest buffer in real time, so the picture stays just as live.
        balanceNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize * 4), format: nil) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        tapInstalled = true
    }

    /// Reconnects the graph when a file's processing format differs from the current connection.
    private func ensureConnected(format: AVAudioFormat) {
        if let c = connectedFormat, c.sampleRate == format.sampleRate, c.channelCount == format.channelCount {
            return
        }
        let wasRunning = engine.isRunning
        engine.stop()
        connectGraph(format: format)
        balanceNode.pan = balance
        if wasRunning { startEngineIfNeeded() }
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("Failed to start AVAudioEngine: %@", error.localizedDescription)
            return false
        }
    }

    private func handleConfigurationChange() {
        // Output device changed (headphones, AirPlay...). Rebuild and resume where we were.
        let resumeAt = currentTime
        let wasPlaying = state == .playing
        connectedFormat = nil
        if let track = currentTrack, state != .stopped {
            load(track: track, startOffset: resumeAt, autoplay: wasPlaying, announce: false)
        }
    }

    private func updateVolume() {
        guard graphReady else { return } // applied when the graph is built
        // Perceptual (logarithmic-feeling) taper: 0 → silent, 1 → 0 dBFS.
        engine.mainMixerNode.outputVolume = isMuted ? 0.0 : pow(volume, 2.5)
    }

    private func updatePreamp() {
        eqNode.globalGain = preampGain
    }

    public func setBandGain(index: Int, gain: Float) {
        guard index >= 0 && index < 10 else { return }
        eqBandGains[index] = max(-12.0, min(12.0, gain))
    }

    public func applyBandGains() {
        for i in 0..<min(10, eqBandGains.count) {
            eqNode.bands[i].gain = eqBandGains[i]
        }
    }

    public func applyPreset(_ preset: EqualizerPreset) {
        currentPresetName = preset.name
        preampGain = preset.preamp
        eqBandGains = preset.bands.count == 10 ? preset.bands : Array(repeating: 0, count: 10)
        Events.post(.ampEQChanged)
    }

    // MARK: - Playback Control

    /// Loads `track` and starts playing it.
    public func loadAndPlay(track: Track, startOffset: TimeInterval = 0) {
        load(track: track, startOffset: startOffset, autoplay: true, announce: true)
    }

    /// Loads `track`, positioned at `startOffset`, optionally starting playback.
    public func load(track: Track, startOffset: TimeInterval = 0, autoplay: Bool, announce: Bool = true) {
        ensureGraph()
        generation += 1
        playerNode.stop()
        segments.removeAll()
        segmentPlayerStartFrame = 0

        let isNewTrack = currentTrack?.id != track.id
        currentTrack = track
        if announce || isNewTrack {
            if autoPresetEnabled, isNewTrack || announce, let preset = EqualizerPresets.matchPreset(forGenre: track.genre ?? "") {
                applyPreset(preset)
            }
            Events.post(.ampTrackChanged)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: track.url)
        } catch {
            NSLog("Error loading audio file %@: %@", track.url.path, error.localizedDescription)
            setState(.stopped)
            Events.status("CANNOT PLAY: \(track.displayTitle)")
            consecutiveFailures += 1
            let failed = track
            DispatchQueue.main.async { [weak self] in self?.onPlaybackFailed?(failed) }
            return
        }

        guard let segment = makeSegment(track: track, file: file, offset: startOffset) else {
            setState(.stopped)
            DispatchQueue.main.async { [weak self] in self?.onPlaybackEnded?() }
            return
        }
        consecutiveFailures = 0
        ensureConnected(format: file.processingFormat)
        if autoplay { startEngineIfNeeded() }

        schedule(segment)
        segments = [segment]
        prescheduleGaplessSuccessor()

        if autoplay {
            playerNode.play()
            setState(.playing)
        } else {
            pausedTime = segment.trackOffset
            engine.pause()
            setState(.paused)
        }
    }

    /// Number of failed opens in a row — lets the playlist stop skipping when nothing is playable.
    public var failureStreak: Int { consecutiveFailures }

    private func makeSegment(track: Track, file: AVAudioFile, offset: TimeInterval) -> Segment? {
        let sr = file.processingFormat.sampleRate
        guard let b = AudioEngine.segmentBounds(length: file.length, sampleRate: sr,
                                                cueStart: track.isCueSegment ? track.cueStartTime : nil,
                                                cueEnd: track.isCueSegment ? track.cueEndTime : nil,
                                                offset: offset) else { return nil }
        return Segment(track: track, file: file, startFrame: b.start, frameCount: b.count, trackOffset: b.trackOffset)
    }

    /// Frame range to play for a file of `length` frames: the CUE window (if any), advanced by
    /// `offset` seconds. Non-finite or out-of-range times are clamped, never converted blindly.
    static func segmentBounds(length: AVAudioFramePosition, sampleRate sr: Double, cueStart: TimeInterval?,
                              cueEnd: TimeInterval?, offset: TimeInterval) -> (start: AVAudioFramePosition, count: AVAudioFramePosition, trackOffset: TimeInterval)? {
        guard sr > 0, sr.isFinite, length > 0 else { return nil }
        func frames(_ seconds: TimeInterval) -> AVAudioFramePosition {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            let f = seconds * sr
            return f >= Double(length) ? length : AVAudioFramePosition(f)
        }
        var startFrame: AVAudioFramePosition = 0
        var endFrame = length
        if let cs = cueStart {
            startFrame = frames(cs)
            if let ce = cueEnd, ce.isFinite, ce > cs { endFrame = frames(ce) }
        }
        let actualStart = min(endFrame, startFrame + frames(offset))
        let count = endFrame - actualStart
        guard count > 0 else { return nil }
        return (actualStart, count, Double(actualStart - startFrame) / sr)
    }

    /// `scheduleSegment` takes at most UInt32.max frames per call.
    static func chunkSizes(_ total: AVAudioFramePosition, maxChunk: AVAudioFramePosition = AVAudioFramePosition(AVAudioFrameCount.max)) -> [AVAudioFrameCount] {
        guard total > 0 else { return [] }
        var out: [AVAudioFrameCount] = []
        var left = total
        while left > 0 {
            let n = min(left, maxChunk)
            out.append(AVAudioFrameCount(n))
            left -= n
        }
        return out
    }

    private func schedule(_ segment: Segment) {
        let token = generation
        let chunks = AudioEngine.chunkSizes(segment.frameCount)
        var start = segment.startFrame
        // Chunks are queued back to back (sample-contiguous); only the last one reports completion.
        for (i, n) in chunks.enumerated() {
            let isLast = i == chunks.count - 1
            playerNode.scheduleSegment(segment.file, startingFrame: start, frameCount: n, at: nil,
                                       completionCallbackType: .dataPlayedBack,
                                       completionHandler: isLast ? { [weak self] _ in
                                           DispatchQueue.main.async { self?.segmentFinished(token: token) }
                                       } : nil)
            start += AVAudioFramePosition(n)
        }
    }

    /// Queues the next CUE segment of the same file right behind the current one, so the
    /// boundary is sample-contiguous: zero silence between tracks.
    private func prescheduleGaplessSuccessor() {
        guard segments.count == 1, let current = segments.first,
              let next = nextGaplessTrack?(current.track), next.isGaplessSuccessor(of: current.track),
              let seg = makeSegment(track: next, file: current.file, offset: 0) else { return }
        schedule(seg)
        segments.append(seg)
    }

    private func segmentFinished(token: Int) {
        guard token == generation, !segments.isEmpty else { return }
        let finished = segments.removeFirst()
        segmentPlayerStartFrame += finished.frameCount

        if let next = segments.first {
            NSLog("Gapless transition into \"%@\" (no re-scheduling, sample-contiguous)", next.track.title)
            currentTrack = next.track
            Events.post(.ampTrackChanged)
            onGaplessAdvance?(next.track)
            prescheduleGaplessSuccessor()
            updateNowPlayingInfo()
        } else {
            setState(.stopped)
            onPlaybackEnded?()
            // If nothing new started, let the audio hardware idle.
            if state == .stopped { engine.pause() }
        }
    }

    public func play() {
        switch state {
        case .playing:
            return
        case .paused where !segments.isEmpty:
            ensureGraph()
            startEngineIfNeeded()
            playerNode.play()
            setState(.playing)
        default:
            if let track = currentTrack {
                load(track: track, startOffset: 0, autoplay: true, announce: false)
            } else {
                onPlayRequestedWithoutTrack?()
            }
        }
    }

    public func pause() {
        guard state == .playing else {
            if state == .paused { play() } // classic behaviour: pause toggles
            return
        }
        pausedTime = currentTime
        if graphReady {
            playerNode.pause()
            engine.pause() // stop the IO thread: an idle player should cost ~0 CPU
        }
        setState(.paused)
    }

    public func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    public func stop() {
        generation += 1
        if graphReady { playerNode.stop() }
        segments.removeAll()
        segmentPlayerStartFrame = 0
        pausedTime = 0
        captureLock.lock()
        captureSamples.removeAll()
        captureLock.unlock()
        if graphReady { engine.pause() }
        setState(.stopped)
    }

    public func seek(to time: TimeInterval) {
        guard let track = currentTrack, state != .stopped else { return }
        let clamped = max(0, min(time, max(0, track.duration - 0.05)))
        load(track: track, startOffset: clamped, autoplay: state == .playing, announce: false)
    }

    public func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    public var currentTime: TimeInterval {
        guard state != .stopped, let seg = segments.first else { return 0 }
        if state == .paused { return pausedTime }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return seg.trackOffset
        }
        let into = Double(playerTime.sampleTime - segmentPlayerStartFrame) / playerTime.sampleRate
        return min(seg.track.duration, max(0, seg.trackOffset + into))
    }

    private func setState(_ newState: PlaybackState) {
        state = newState
        Events.post(.ampPlaybackStateChanged)
        updateNowPlayingInfo()
    }

    // MARK: - Visualizer

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        captureLock.lock()
        defer { captureLock.unlock() }
        // Mix to mono straight into the reused buffer (no allocation once sized).
        if captureSamples.count != frames { captureSamples = [Float](repeating: 0, count: frames) }
        captureSamples.withUnsafeMutableBufferPointer { out in
            if channels == 1 {
                out.baseAddress!.assign(from: data[0], count: frames)
            } else {
                vDSP_vadd(data[0], 1, data[1], 1, out.baseAddress!, 1, vDSP_Length(frames))
                var half: Float = 0.5
                vDSP_vsmul(out.baseAddress!, 1, &half, out.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        captureSampleRate = buffer.format.sampleRate
        captureTime = CFAbsoluteTimeGetCurrent()
    }

    private let analyzer = SpectrumAnalyzer()

    /// Analyses the audio currently audible: `bins` log-spaced spectrum bins (0...1) and
    /// `oscPoints` waveform samples (-1...1). Pass 0 for the part you don't draw: the
    /// oscilloscope needs no FFT and the spectrum no waveform. Allocation-free apart from the
    /// returned arrays; main thread only.
    public func analyze(bins binCount: Int = 32, oscPoints: Int = 76) -> (spectrum: [Float], osc: [Float])? {
        guard state == .playing else { return nil }
        captureLock.lock()
        let count = captureSamples.count
        guard count >= 64 else { captureLock.unlock(); return nil }
        let sr = captureSampleRate
        let age = CFAbsoluteTimeGetCurrent() - captureTime
        // Slide the analysis window through the latest tap buffer in real time.
        let start = min(max(0, count - analyzer.fftSize), max(0, Int(age * sr)))
        let available = captureSamples.withUnsafeBufferPointer { analyzer.load($0, start: start) }
        captureLock.unlock()

        let osc = oscPoints > 0 ? analyzer.oscilloscope(points: oscPoints, available: available) : []
        let spectrum = binCount > 0 ? analyzer.spectrum(bins: binCount, sampleRate: sr) : []
        return (spectrum, osc)
    }

    // MARK: - Media Keys & Now Playing

    private func setupMediaRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        // With nothing to play, a media key must not fall through to the "open files" dialog.
        let hasSomethingToPlay = { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.currentTrack != nil || self.idleNowPlayingTrack?() != nil
        }
        cc.playCommand.addTarget { [weak self] _ in
            guard hasSomethingToPlay() else { return .noActionableNowPlayingItem }
            self?.play(); return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            if self?.state == .playing { self?.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard hasSomethingToPlay() else { return .noActionableNowPlayingItem }
            self?.togglePlayPause(); return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in self?.stop(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.onNextRequested?(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.onPreviousRequested?(); return .success }
        // Fast-forward / rewind keys: the classic 5 s jumps.
        cc.skipForwardCommand.preferredIntervals = [5]
        cc.skipForwardCommand.addTarget { [weak self] _ in self?.seek(by: 5); return .success }
        cc.skipBackwardCommand.preferredIntervals = [5]
        cc.skipBackwardCommand.addTarget { [weak self] _ in self?.seek(by: -5); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        // Claim the media keys right away (otherwise macOS hands play/pause to Apple Music
        // until this app has produced sound).
        updateNowPlayingInfo()
    }

    /// macOS only elects an app as "now playing" (the media-key target) after it reports a
    /// playing state. At launch, announce the restored track as playing for a moment, then
    /// settle on the real (paused/stopped) state.
    /// Only take over the media keys when the user was listening in this player when it quit, and
    /// never while another app is producing sound (that would hijack its play/pause key).
    static func shouldClaimMediaKeysAtLaunch(restoredWasPlaying: Bool, otherAudioPlaying: Bool) -> Bool {
        restoredWasPlaying && !otherAudioPlaying
    }

    /// True when some process is doing I/O on the default output device (public CoreAudio API).
    static func isOtherAudioPlaying() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    public func claimMediaKeys() {
        guard state != .playing, currentTrack ?? idleNowPlayingTrack?() != nil else { return }
        updateNowPlayingInfo()
        MPNowPlayingInfoCenter.default().playbackState = .playing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateNowPlayingInfo() }
    }

    /// Track to advertise to the system while nothing is loaded (the playlist's current/first
    /// entry), so the media keys keep targeting this player after launch or Stop.
    public var idleNowPlayingTrack: (() -> Track?)?

    public func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack ?? idleNowPlayingTrack?() else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state == .stopped ? 0 : currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0
        ]
        if let cached = artworkCache[track.url] {
            if let art = cached {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
            }
        } else {
            loadArtwork(for: track)
        }
        center.nowPlayingInfo = info
        switch state {
        case .playing: center.playbackState = .playing
        case .paused: center.playbackState = .paused
        // Stopped-with-a-track is reported as paused: a "stopped" app loses the media keys.
        case .stopped: center.playbackState = .paused
        }
    }

    private func loadArtwork(for track: Track) {
        let url = track.url
        guard !artworkLoading.contains(url) else { return }
        artworkLoading.insert(url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image: NSImage? = autoreleasepool {
                let asset = AVURLAsset(url: url)
                for item in asset.metadata where item.commonKey == .commonKeyArtwork {
                    if let data = item.dataValue, let img = NSImage(data: data) { return img }
                }
                return nil
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.artworkLoading.remove(url)
                // Cover art can be multi-MB once decoded: keep only a few files' worth.
                if self.artworkCache.count >= 4 { self.artworkCache.removeAll() }
                self.artworkCache[url] = .some(image)
                if image != nil, self.currentTrack?.url == url { self.updateNowPlayingInfo() }
            }
        }
    }
}

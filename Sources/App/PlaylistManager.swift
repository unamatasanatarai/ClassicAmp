import Foundation
import AVFoundation
import AudioToolbox

public enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case track
}

public struct Track: Identifiable, Equatable, Codable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var isCueSegment: Bool
    public var cueStartTime: TimeInterval
    public var cueEndTime: TimeInterval?
    public var bitrate: Int?
    public var sampleRate: Double?
    public var channels: Int?
    public var missing: Bool
    public var genre: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 0,
        isCueSegment: Bool = false,
        cueStartTime: TimeInterval = 0,
        cueEndTime: TimeInterval? = nil,
        bitrate: Int? = nil,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        missing: Bool = false,
        genre: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.artist = artist ?? "Unknown Artist"
        self.album = album ?? "Unknown Album"
        self.duration = duration
        self.isCueSegment = isCueSegment
        self.cueStartTime = cueStartTime
        self.cueEndTime = cueEndTime
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.missing = missing
        self.genre = genre
    }

    /// True for tracks that are segments of the same physical file and play back-to-back.
    public func isGaplessSuccessor(of previous: Track) -> Bool {
        guard isCueSegment, previous.isCueSegment, url == previous.url,
              let prevEnd = previous.cueEndTime else { return false }
        return abs(cueStartTime - prevEnd) < 0.001
    }

    public var displayTitle: String {
        if artist != "Unknown Artist" && !artist.isEmpty {
            return "\(artist) - \(title)"
        }
        return title
    }

    /// Whole seconds for display: non-finite, negative or absurd values (from hostile or broken
    /// playlist/CUE files) become 0 instead of trapping in `Int(_:)`.
    public static func wholeSeconds(_ t: TimeInterval) -> Int {
        guard t.isFinite, t > 0, t <= maxDuration else { return 0 }
        return Int(t.rounded())
    }

    /// Durations from text formats are trusted only when finite and below ~115 days.
    public static let maxDuration: TimeInterval = 10_000_000

    /// Average bitrate in kbps, or nil when the inputs are absurd. File headers are untrusted:
    /// a crafted sample rate can make `duration` tiny, and `Int(_:)` traps on huge values.
    public static func bitrateKbps(fileSize: Int, duration: TimeInterval) -> Int? {
        guard fileSize > 0, duration.isFinite, duration > 0 else { return nil }
        let kbps = Double(fileSize) * 8.0 / duration / 1000.0
        guard kbps.isFinite, kbps >= 1, kbps <= 100_000 else { return nil }
        return Int(kbps)
    }

    public static func sanitizedDuration(_ t: TimeInterval?) -> TimeInterval {
        guard let t = t, t.isFinite, t >= 0, t <= maxDuration else { return 0 }
        return t
    }

    public var formattedDuration: String {
        let totalSecs = Track.wholeSeconds(duration)
        let hours = totalSecs / 3600
        let minutes = (totalSecs % 3600) / 60
        let seconds = totalSecs % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

public final class PlaylistManager {
    public private(set) var tracks: [Track] = [] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every edit of `tracks`; persistence rewrites playlist.json only when it moves.
    public private(set) var revision = 0

    /// Sum of all track lengths in whole seconds, recomputed only after the playlist changes
    /// (the playlist window shows it on every redraw; summing 10k tracks each time is wasteful).
    public var totalSeconds: Int {
        if totalSecondsRevision != revision {
            totalSecondsCache = tracks.withUnsafeBufferPointer { $0.reduce(0) { $0 + Track.wholeSeconds($1.duration) } }
            totalSecondsRevision = revision
        }
        return totalSecondsCache
    }
    private var totalSecondsCache = 0
    private var totalSecondsRevision = -1
    public private(set) var selectedIndices: IndexSet = []
    public var currentIndex: Int? {
        didSet {
            if !shuffleEnabledInternalUpdate, shuffleEnabled, let curr = currentIndex, let pos = shuffleQueue.firstIndex(of: curr) {
                shuffleQueue.remove(at: pos)
            }
        }
    }
    public var shuffleEnabled: Bool = false {
        didSet {
            if shuffleEnabled {
                rebuildShuffleQueue()
            } else {
                shuffleQueue.removeAll()
                shuffleHistory.removeAll()
            }
            if oldValue != shuffleEnabled {
                Events.post(.ampModesChanged)
                Events.markDirty()
            }
        }
    }
    public var repeatMode: RepeatMode = .all {
        didSet { Events.post(.ampModesChanged); Events.markDirty() }
    }

    private var shuffleQueue: [Int] = []
    private var shuffleHistory: [Int] = []


    /// Lowercased UTF-8 search keys for every track, packed into one contiguous buffer.
    /// `offsets` holds 8 Ints per track: (start, length) of title, artist, display title, file name.
    private struct SearchIndex {
        var bytes: [UInt8] = []
        var offsets: [Int] = []
        var count: Int { offsets.count / 8 }
    }
    private var searchIndex: SearchIndex?

    public init() {}

    private func notifyChanged() {
        searchIndex = nil
        Events.post(.ampPlaylistChanged)
        Events.markDirty()
    }

    /// Runs a reorder while keeping `currentIndex` pointing at the same track.
    private func preservingCurrent(_ body: () -> Void) {
        let currentID = currentTrack?.id
        let shuffleWasOn = shuffleEnabled
        body()
        if let id = currentID {
            let idx = tracks.firstIndex { $0.id == id }
            // Avoid the didSet side effect on the shuffle queue; it is rebuilt below.
            shuffleEnabledInternalUpdate = true
            currentIndex = idx
            shuffleEnabledInternalUpdate = false
        }
        if shuffleWasOn { rebuildShuffleQueue() }
    }
    private var shuffleEnabledInternalUpdate = false

    public var count: Int {
        return tracks.count
    }

    public var currentTrack: Track? {
        guard let idx = currentIndex, idx >= 0 && idx < tracks.count else { return nil }
        return tracks[idx]
    }

    // MARK: - Queue & Navigation

    public func nextIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }

        if repeatMode == .track, let curr = currentIndex {
            return curr
        }

        if shuffleEnabled {
            if shuffleQueue.isEmpty {
                if repeatMode == .off {
                    return nil
                }
                rebuildShuffleQueue()
            }
            if !shuffleQueue.isEmpty {
                let next = shuffleQueue.removeFirst()
                shuffleHistory.append(next)
                return next
            }
        }

        guard let current = currentIndex else {
            return 0
        }

        let next = current + 1
        if next < tracks.count {
            return next
        } else if repeatMode == .all {
            return 0
        } else {
            return nil
        }
    }

    public func previousIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }

        if shuffleEnabled && !shuffleHistory.isEmpty {
            _ = shuffleHistory.popLast() // current
            if let prev = shuffleHistory.popLast() {
                return prev
            }
        }

        guard let current = currentIndex else {
            return 0
        }

        let prev = current - 1
        if prev >= 0 {
            return prev
        } else if repeatMode == .all {
            return tracks.count - 1
        } else {
            return 0
        }
    }

    public func rebuildShuffleQueue() {
        var pool = Array(0..<tracks.count)
        if let current = currentIndex, let pos = pool.firstIndex(of: current) {
            pool.remove(at: pos)
        }
        // Fisher-Yates shuffle
        for i in stride(from: pool.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            if i != j {
                pool.swapAt(i, j)
            }
        }
        shuffleQueue = pool
    }

    // MARK: - Modification

    /// `validate: false` leaves the missing-file check to `validateMissingStatusAsync()`
    /// (one stat per track: thousands of them, or a slow network volume, must not block launch).
    public func setTracks(_ newTracks: [Track], validate: Bool = true) {
        tracks = newTracks
        if validate { validateMissingStatus() }
        if shuffleEnabled {
            rebuildShuffleQueue()
        }
        notifyChanged()
    }

    public func addTracks(_ newTracks: [Track]) {
        let start = tracks.count
        tracks.append(contentsOf: newTracks)
        if shuffleEnabled {
            for i in start..<tracks.count {
                let insertPos = Int.random(in: 0...shuffleQueue.count)
                shuffleQueue.insert(i, at: insertPos)
            }
        }
        notifyChanged()
    }

    public func remove(at indices: IndexSet) {
        var newTracks: [Track] = []
        var newCurrentIndex: Int? = currentIndex

        for (idx, track) in tracks.enumerated() {
            if !indices.contains(idx) {
                newTracks.append(track)
            } else if let curr = currentIndex {
                if idx == curr {
                    newCurrentIndex = nil
                } else if idx < curr {
                    newCurrentIndex = (newCurrentIndex ?? 1) - 1
                }
            }
        }

        tracks = newTracks
        if let nci = newCurrentIndex, nci >= tracks.count {
            self.currentIndex = tracks.isEmpty ? nil : tracks.count - 1
        } else {
            self.currentIndex = newCurrentIndex
        }

        selectedIndices.removeAll()
        if shuffleEnabled {
            rebuildShuffleQueue()
        }
        notifyChanged()
    }

    public func removeSelected() {
        remove(at: selectedIndices)
    }

    public func cropSelected() {
        guard !selectedIndices.isEmpty else { return }
        var toKeep: [Track] = []
        for idx in selectedIndices {
            if idx < tracks.count {
                toKeep.append(tracks[idx])
            }
        }
        tracks = toKeep
        selectedIndices = IndexSet(integersIn: 0..<tracks.count)
        currentIndex = nil
        if shuffleEnabled {
            rebuildShuffleQueue()
        }
        notifyChanged()
    }

    public func removeMissing() {
        let missingIndices = IndexSet(tracks.indices.filter { tracks[$0].missing })
        remove(at: missingIndices)
    }

    public func clear() {
        tracks.removeAll()
        selectedIndices.removeAll()
        currentIndex = nil
        shuffleQueue.removeAll()
        shuffleHistory.removeAll()
        notifyChanged()
    }

    public func moveTracks(from sourceIndices: IndexSet, to destinationIndex: Int) {
        var moving: [Track] = []
        var remaining: [Track] = []

        for (idx, track) in tracks.enumerated() {
            if sourceIndices.contains(idx) {
                moving.append(track)
            } else {
                remaining.append(track)
            }
        }

        var insertIndex = destinationIndex
        let beforeCount = sourceIndices.filter { $0 < destinationIndex }.count
        insertIndex -= beforeCount
        insertIndex = max(0, min(insertIndex, remaining.count))

        remaining.insert(contentsOf: moving, at: insertIndex)
        preservingCurrent { tracks = remaining }
        selectedIndices = IndexSet(integersIn: insertIndex..<(insertIndex + moving.count))
        notifyChanged()
    }

    // MARK: - Sorting

    public func sortByTitle() {
        preservingCurrent { tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
        selectedIndices.removeAll()
        notifyChanged()
    }

    public func sortByFilename() {
        preservingCurrent { tracks.sort { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending } }
        selectedIndices.removeAll()
        notifyChanged()
    }

    public func sortByPath() {
        preservingCurrent { tracks.sort { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending } }
        selectedIndices.removeAll()
        notifyChanged()
    }

    /// Shortest first; tracks with an unknown length (0) go last, ties keep title order.
    /// Use Reverse List afterwards for longest first.
    public func sortByDuration() {
        preservingCurrent {
            tracks.sort { a, b in
                let da = a.duration > 0 ? a.duration : .infinity
                let db = b.duration > 0 ? b.duration : .infinity
                if da != db { return da < db }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        selectedIndices.removeAll()
        notifyChanged()
    }

    /// Randomizes the playlist order itself (Fisher-Yates). Unlike Shuffle mode, this permanently
    /// reorders the list; the currently playing track keeps playing and stays marked as current.
    public func randomizeOrder() {
        guard tracks.count > 1 else { return }
        preservingCurrent {
            for i in stride(from: tracks.count - 1, through: 1, by: -1) {
                tracks.swapAt(i, Int.random(in: 0...i))
            }
        }
        selectedIndices.removeAll()
        notifyChanged()
    }

    public func reverseOrder() {
        preservingCurrent { tracks.reverse() }
        selectedIndices.removeAll()
        notifyChanged()
    }

    // MARK: - Selection

    public func setSelection(_ indices: IndexSet) {
        selectedIndices = indices.filteredIndexSet { $0 >= 0 && $0 < tracks.count }
    }

    public func insertTracks(_ newTracks: [Track], at index: Int) {
        let at = max(0, min(index, tracks.count))
        preservingCurrent { tracks.insert(contentsOf: newTracks, at: at) }
        selectedIndices = IndexSet(integersIn: at..<(at + newTracks.count))
        notifyChanged()
    }

    public func updateTrack(_ track: Track) {
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[idx] = track
        searchIndex = nil
        Events.post(.ampPlaylistChanged)
    }

    public func selectAll() {
        selectedIndices = IndexSet(integersIn: 0..<tracks.count)
    }

    public func selectNone() {
        selectedIndices.removeAll()
    }

    public func invertSelection() {
        var newSet = IndexSet()
        for i in 0..<tracks.count {
            if !selectedIndices.contains(i) {
                newSet.insert(i)
            }
        }
        selectedIndices = newSet
    }

    // MARK: - Jump-to-File Search

    public func search(query: String) -> [Track] {
        let q = Array(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        if q.isEmpty {
            return tracks
        }
        if searchIndex == nil || searchIndex!.count != tracks.count {
            var index = SearchIndex()
            index.offsets.reserveCapacity(tracks.count * 8)
            for t in tracks {
                for key in [t.title, t.artist, t.displayTitle, t.url.lastPathComponent] {
                    let utf8 = Array(key.lowercased().utf8)
                    index.offsets.append(index.bytes.count)
                    index.offsets.append(utf8.count)
                    index.bytes.append(contentsOf: utf8)
                }
            }
            searchIndex = index
        }
        guard let index = searchIndex else { return [] }

        var tier1: [Int] = [] // Prefix match
        var tier2: [Int] = [] // Word-boundary match
        var tier3: [Int] = [] // Substring match
        let n = index.count
        let qn = q.count

        index.bytes.withUnsafeBufferPointer { bp in
            index.offsets.withUnsafeBufferPointer { op in
                q.withUnsafeBufferPointer { qp in
                    guard let base = bp.baseAddress, let qb = qp.baseAddress else { return }
                    func hasPrefix(_ start: Int, _ len: Int) -> Bool {
                        len >= qn && memcmp(base + start, qb, qn) == 0
                    }
                    func firstHit(_ start: Int, _ len: Int, from: Int) -> Int? {
                        guard from + qn <= len, let p = memmem(base + start + from, len - from, qb, qn) else { return nil }
                        return UnsafeRawPointer(base + start).distance(to: UnsafeRawPointer(p))
                    }
                    for i in 0..<n {
                        let o = i * 8
                        if hasPrefix(op[o], op[o + 1]) || hasPrefix(op[o + 2], op[o + 3]) || hasPrefix(op[o + 4], op[o + 5]) {
                            tier1.append(i)
                            continue
                        }
                        let ds = op[o + 4], dl = op[o + 5]
                        if var hit = firstHit(ds, dl, from: 0) {
                            var boundary = false
                            while true {
                                if hit == 0 || !PlaylistManager.isWordByte(base[ds + hit - 1]) { boundary = true; break }
                                guard let next = firstHit(ds, dl, from: hit + 1) else { break }
                                hit = next
                            }
                            if boundary { tier2.append(i) } else { tier3.append(i) }
                        } else if firstHit(op[o + 6], op[o + 7], from: 0) != nil {
                            tier3.append(i)
                        }
                    }
                }
            }
        }
        return (tier1 + tier2 + tier3).map { tracks[$0] }
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b >= 0x80
    }

    // MARK: - Validation

    public func validateMissingStatus() {
        let fm = FileManager.default
        for i in 0..<tracks.count {
            let exists = fm.fileExists(atPath: tracks[i].url.path)
            if tracks[i].missing == exists { tracks[i].missing = !exists }
        }
    }

    /// Checks every track's file on a background queue, then applies only the flags that
    /// changed (matched by track id, so edits made in the meantime are respected).
    public func validateMissingStatusAsync(completion: (() -> Void)? = nil) {
        let snapshot = tracks.map { ($0.id, $0.url, $0.missing) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var changed: [UUID: Bool] = [:]
            for (id, url, missing) in snapshot {
                let nowMissing = !fm.fileExists(atPath: url.path)
                if nowMissing != missing { changed[id] = nowMissing }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !changed.isEmpty {
                    for i in self.tracks.indices {
                        if let m = changed[self.tracks[i].id], self.tracks[i].missing != m { self.tracks[i].missing = m }
                    }
                    self.searchIndex = nil
                    Events.post(.ampPlaylistChanged)
                }
                completion?()
            }
        }
    }

    // MARK: - M3U / PLS Import & Export

    /// Playlist files are line-based: a CR/LF inside a title or path would split the entry.
    private static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }

    public func exportM3U(to url: URL) throws {
        var content = "#EXTM3U\n"
        for track in tracks {
            let secs = Track.wholeSeconds(track.duration)
            content += "#EXTINF:\(secs),\(Self.singleLine(track.displayTitle))\n"
            content += "\(Self.singleLine(track.url.path))\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func exportPLS(to url: URL) throws {
        var content = "[playlist]\n"
        content += "NumberOfEntries=\(tracks.count)\n"
        for (i, track) in tracks.enumerated() {
            let idx = i + 1
            content += "File\(idx)=\(Self.singleLine(track.url.path))\n"
            content += "Title\(idx)=\(Self.singleLine(track.displayTitle))\n"
            content += "Length\(idx)=\(Track.wholeSeconds(track.duration))\n"
        }
        content += "Version=2\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func parseM3U(url: URL) throws -> [Track] {
        let data = try Data(contentsOf: url)
        let content = CueSheetParser.decodeStringWithEncodings(data) ?? ""
        let lines = content.components(separatedBy: .newlines)
        var result: [Track] = []
        var pendingTitle: String?
        var pendingDuration: TimeInterval = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                let meta = String(line.dropFirst("#EXTINF:".count))
                if let commaIdx = meta.firstIndex(of: ",") {
                    let secStr = String(meta[..<commaIdx])
                    pendingDuration = Track.sanitizedDuration(Double(secStr))
                    pendingTitle = String(meta[meta.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
                }
            } else if !line.hasPrefix("#") {
                let trackURL = CueSheetParser.resolveAudioFile(filename: line, baseURL: url.deletingLastPathComponent())
                let (artist, title) = parseArtistAndTitle(pendingTitle ?? trackURL.deletingPathExtension().lastPathComponent)
                let track = Track(
                    url: trackURL,
                    title: title,
                    artist: artist,
                    duration: pendingDuration
                )
                result.append(track)
                pendingTitle = nil
                pendingDuration = 0
            }
        }
        return result
    }

    public static func parsePLS(url: URL) throws -> [Track] {
        let data = try Data(contentsOf: url)
        let content = CueSheetParser.decodeStringWithEncodings(data) ?? ""
        let lines = content.components(separatedBy: .newlines)

        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: TimeInterval] = [:]

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("[") {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = parts[1]

            if key.lowercased().hasPrefix("file"), let num = Int(key.dropFirst(4)) {
                files[num] = val
            } else if key.lowercased().hasPrefix("title"), let num = Int(key.dropFirst(5)) {
                titles[num] = val
            } else if key.lowercased().hasPrefix("length"), let num = Int(key.dropFirst(6)) {
                lengths[num] = Track.sanitizedDuration(Double(val))
            }
        }

        let sortedKeys = files.keys.sorted()
        var result: [Track] = []
        for key in sortedKeys {
            guard let filename = files[key] else { continue }
            let trackURL = CueSheetParser.resolveAudioFile(filename: filename, baseURL: url.deletingLastPathComponent())
            let rawTitle = titles[key] ?? trackURL.deletingPathExtension().lastPathComponent
            let (artist, title) = parseArtistAndTitle(rawTitle)
            let duration = lengths[key] ?? 0
            result.append(Track(url: trackURL, title: title, artist: artist, duration: duration))
        }
        return result
    }

    public static func parseArtistAndTitle(_ raw: String) -> (artist: String, title: String) {
        if let dashIdx = raw.range(of: " - ") {
            let artist = String(raw[..<dashIdx.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(raw[dashIdx.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (artist, title)
        }
        return ("Unknown Artist", raw)
    }

    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf", "alac", "mp4", "ogg", "opus"
    ]

    public static func isAudioFile(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    /// True for files that are not really on disk (iCloud placeholders, dataless or empty files).
    public static func isStreamingPlaceholder(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") && url.pathExtension.lowercased() == "icloud" {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
            return true
        }
        return (values?.fileSize ?? 0) == 0
    }

    // Ingest local files or folders
    public static func loadTrackFromAudioFile(url: URL) -> Track? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let fast = fastTrackInfo(url: url) { return fast }
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var genre: String?
        var duration: TimeInterval = 0

        for item in asset.metadata {
            if let commonKey = item.commonKey?.rawValue {
                switch commonKey {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    if let val = item.stringValue, !val.isEmpty { title = val }
                case AVMetadataKey.commonKeyArtist.rawValue:
                    if let val = item.stringValue, !val.isEmpty { artist = val }
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    if let val = item.stringValue, !val.isEmpty { album = val }
                default:
                    break
                }
            }
            if genre == nil, let id = item.identifier,
               [AVMetadataIdentifier.iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre,
                .iTunesMetadataPredefinedGenre].contains(id),
               let val = item.stringValue, !val.isEmpty {
                genre = val
            }
        }
        if artist == "Unknown Artist" && title == url.deletingPathExtension().lastPathComponent {
            let parsed = parseArtistAndTitle(title)
            artist = parsed.artist
            title = parsed.title
        }

        if let audioFile = try? AVAudioFile(forReading: url) {
            let sampleRate = audioFile.fileFormat.sampleRate
            if sampleRate > 0 {
                duration = Track.sanitizedDuration(Double(audioFile.length) / sampleRate)
            }
            let channels = Int(audioFile.fileFormat.channelCount)
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let bitrate = Track.bitrateKbps(fileSize: fileSize, duration: duration)

            return Track(
                url: url,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                bitrate: bitrate,
                sampleRate: sampleRate,
                channels: channels,
                genre: genre
            )
        }

        // Unreadable/corrupt file: keep it listed but flagged so playback skips it.
        return Track(url: url, title: title, artist: artist, album: album, duration: duration, missing: true, genre: genre)
    }

    /// Core Audio's AudioFile API reads tags and format ~4x faster than AVURLAsset + AVAudioFile,
    /// which matters when importing thousands of files. Returns nil (use the AVFoundation path)
    /// when the file can't be opened or carries no title/artist tags.
    private static func fastTrackInfo(url: URL) -> Track? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let file = fileID else { return nil }
        defer { AudioFileClose(file) }

        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
              let tags = info?.takeRetainedValue() as? [String: Any] else { return nil }
        func tag(_ key: String) -> String? {
            guard let v = tags[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard tag(kAFInfoDictionary_Title) != nil || tag(kAFInfoDictionary_Artist) != nil else { return nil }

        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr,
              asbd.mSampleRate > 0 else { return nil }

        // Exact length: valid frames from the packet table (excludes encoder priming/remainder).
        var duration: TimeInterval = 0
        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr, table.mNumberValidFrames > 0 {
            duration = Double(table.mNumberValidFrames) / asbd.mSampleRate
        } else {
            var packets: UInt64 = 0
            size = UInt32(MemoryLayout<UInt64>.size)
            if asbd.mFramesPerPacket > 0,
               AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr {
                duration = Double(packets) * Double(asbd.mFramesPerPacket) / asbd.mSampleRate
            } else {
                var est: Double = 0
                size = UInt32(MemoryLayout<Double>.size)
                AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &est)
                duration = est
            }
        }
        duration = Track.sanitizedDuration(duration)
        guard duration > 0 else { return nil }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Track(
            url: url,
            title: tag(kAFInfoDictionary_Title) ?? url.deletingPathExtension().lastPathComponent,
            artist: tag(kAFInfoDictionary_Artist) ?? "Unknown Artist",
            album: tag(kAFInfoDictionary_Album) ?? "Unknown Album",
            duration: duration,
            bitrate: Track.bitrateKbps(fileSize: fileSize, duration: duration),
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            genre: tag(kAFInfoDictionary_Genre)
        )
    }
}

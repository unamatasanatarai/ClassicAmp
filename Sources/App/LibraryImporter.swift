import Foundation
import AVFoundation

/// Turns dropped/opened URLs (files, folders, playlists, CUE sheets) into playlist tracks.
/// Runs off the main thread; never throws — unreadable inputs are skipped and logged.
public enum LibraryImporter {
    public struct Result {
        public var tracks: [Track] = []
        public var skippedStreaming: Int = 0
        public var skins: [URL] = []
    }

    /// Reports (files processed, files total) for large imports; called off the main thread.
    public typealias Progress = (Int, Int) -> Void

    public static func importURLs(_ urls: [URL], progress: Progress? = nil) -> Result {
        var result = Result()
        for url in urls {
            importOne(url, into: &result, progress: progress)
        }
        return result
    }

    public static func importAsync(_ urls: [URL], progress: Progress? = nil, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = importURLs(urls, progress: progress)
            DispatchQueue.main.async { completion(r) }
        }
    }

    private static func importOne(_ url: URL, into result: inout Result, progress: Progress? = nil) {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            NSLog("Import: missing path %@", url.path)
            return
        }

        if isDir.boolValue {
            importDirectory(url, into: &result, progress: progress)
            return
        }

        switch ext {
        case "wsz":
            result.skins.append(url)
        case "cue":
            result.tracks.append(contentsOf: tracksFromCue(url))
        case "m3u", "m3u8":
            if let t = try? PlaylistManager.parseM3U(url: url) { result.tracks.append(contentsOf: validated(t)) }
        case "pls":
            if let t = try? PlaylistManager.parsePLS(url: url) { result.tracks.append(contentsOf: validated(t)) }
        default:
            guard PlaylistManager.isAudioFile(url) else { return }
            if PlaylistManager.isStreamingPlaceholder(url) {
                result.skippedStreaming += 1
                return
            }
            if ext == "flac", let comments = flacVorbisComments(url), let cueText = comments["CUESHEET"] {
                // cueTracks() opens the file once and clamps the last track to its real length.
                var sheet = CueSheetParser.parse(content: cueText, baseURL: url.deletingLastPathComponent())
                if sheet.genre == nil { sheet.genre = comments["GENRE"] }
                let tracks = cueTracks(sheet, overridingFile: url)
                if !tracks.isEmpty {
                    result.tracks.append(contentsOf: tracks)
                    return
                }
            }
            if let t = PlaylistManager.loadTrackFromAudioFile(url: url) {
                result.tracks.append(t)
            }
        }
    }

    private static func importDirectory(_ dir: URL, into result: inout Result, progress: Progress?) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsPackageDescendants]) else { return }
        var audio: [URL] = []
        var cues: [URL] = []
        var placeholders = 0
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "icloud" { placeholders += 1; continue }
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            if ext == "cue" { cues.append(fileURL) } else if PlaylistManager.isAudioFile(fileURL) { audio.append(fileURL) }
        }
        result.skippedStreaming += placeholders

        // Audio files covered by a CUE sheet are represented by its virtual tracks instead.
        var covered = Set<String>()
        var cueTracksByDir: [Track] = []
        for cue in cues.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let tracks = tracksFromCue(cue)
            tracks.forEach { covered.insert($0.url.standardizedFileURL.path) }
            cueTracksByDir.append(contentsOf: tracks)
        }
        result.tracks.append(contentsOf: cueTracksByDir)

        let files = audio
            .filter { !covered.contains($0.standardizedFileURL.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        // Metadata reads are I/O + decoder bound: fan out across cores, keep the sorted order,
        // and drain autoreleased AVFoundation objects per file (otherwise memory grows by GBs).
        var partials = [Result](repeating: Result(), count: files.count)
        let lock = NSLock()
        var done = 0
        let step = max(1, files.count / 100)
        partials.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                autoreleasepool {
                    var r = Result()
                    importOne(files[i], into: &r)
                    (base + i).pointee = r
                }
                guard let progress = progress else { return }
                lock.lock(); done += 1; let n = done; lock.unlock()
                if n % step == 0 || n == files.count { progress(n, files.count) }
            }
        }
        for r in partials {
            result.tracks.append(contentsOf: r.tracks)
            result.skippedStreaming += r.skippedStreaming
            result.skins.append(contentsOf: r.skins)
        }
    }

    public static func tracksFromCue(_ url: URL) -> [Track] {
        // One parse, one open of the audio file: cueTracks() ends the last track at the file's length.
        guard let sheet = try? CueSheetParser.parse(url: url) else { return [] }
        return cueTracks(sheet, overridingFile: nil)
    }

    private static func cueTracks(_ sheet: CueSheet, overridingFile: URL?) -> [Track] {
        var props: [URL: (Double?, Int?, Int?, TimeInterval?)] = [:]
        return sheet.tracks.map { ct in
            let fileURL = overridingFile ?? ct.audioFileURL
            if props[fileURL] == nil {
                if let f = try? AVAudioFile(forReading: fileURL) {
                    let dur = Track.sanitizedDuration(Double(f.length) / max(1, f.fileFormat.sampleRate))
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let kbps = Track.bitrateKbps(fileSize: size, duration: dur)
                    props[fileURL] = (f.fileFormat.sampleRate, Int(f.fileFormat.channelCount), kbps, dur)
                } else {
                    props[fileURL] = (nil, nil, nil, nil)
                }
            }
            let p = props[fileURL]!
            let missing = !FileManager.default.fileExists(atPath: fileURL.path) || p.0 == nil
            // Clamp segment bounds to the real file length (bad CUE timecodes must never crash).
            var start = ct.startTime
            var end = ct.endTime
            if let total = p.3 {
                start = min(start, total)
                end = end.map { min(max($0, start), total) } ?? total
            }
            let duration = end.map { max(0, $0 - start) } ?? ct.duration
            return Track(
                url: fileURL,
                title: ct.title,
                artist: ct.artist,
                album: sheet.albumTitle,
                duration: duration,
                isCueSegment: true,
                cueStartTime: start,
                cueEndTime: end,
                bitrate: p.2,
                sampleRate: p.0,
                channels: p.1,
                missing: missing,
                genre: sheet.genre
            )
        }
    }

    /// Reads every entry's tags in parallel (like folder imports), keeping the playlist order.
    private static func validated(_ tracks: [Track]) -> [Track] {
        var out = tracks
        out.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: tracks.count) { i in
                autoreleasepool { (base + i).pointee = validatedOne(tracks[i]) }
            }
        }
        return out
    }

    private static func validatedOne(_ t: Track) -> Track {
            guard FileManager.default.fileExists(atPath: t.url.path) else {
                var m = t
                m.missing = true
                return m
            }
            guard var full = PlaylistManager.loadTrackFromAudioFile(url: t.url) else { return t }
            // Prefer playlist-provided titles when the file has no tags.
            if full.artist == "Unknown Artist" && t.artist != "Unknown Artist" {
                full.artist = t.artist
                full.title = t.title
            }
            return Track(id: t.id, url: full.url, title: full.title, artist: full.artist, album: full.album,
                         duration: full.duration, bitrate: full.bitrate, sampleRate: full.sampleRate,
                         channels: full.channels, missing: full.missing, genre: full.genre)
    }

    public static func fileDuration(_ url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// All Vorbis comments of a FLAC file, keys uppercased (first occurrence wins).
    public static func flacVorbisComments(_ url: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        for _ in 0..<128 {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if type == 4 {
                guard length < 16 * 1024 * 1024, let block = try? handle.read(upToCount: length), block.count == length else { return nil }
                return parseVorbisComments([UInt8](block))
            }
            if isLast { return nil }
            guard let offset = try? handle.offset() else { return nil }
            try? handle.seek(toOffset: offset + UInt64(length))
        }
        return nil
    }

    private static func parseVorbisComments(_ b: [UInt8]) -> [String: String]? {
        var p = 0
        func le32() -> Int? {
            guard p + 4 <= b.count else { return nil }
            defer { p += 4 }
            return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
        }
        guard let vendorLen = le32(), p + vendorLen <= b.count else { return nil }
        p += vendorLen
        guard let count = le32() else { return nil }
        var result: [String: String] = [:]
        for _ in 0..<min(count, 10_000) {
            guard let len = le32(), p + len <= b.count else { break }
            let comment = String(decoding: b[p..<(p + len)], as: UTF8.self)
            p += len
            guard let eq = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<eq].uppercased()
            if result[key] == nil { result[key] = String(comment[comment.index(after: eq)...]) }
        }
        return result
    }
}

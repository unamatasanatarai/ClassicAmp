import Foundation

public struct CueTrack: Equatable {
    public let number: Int
    public let title: String
    public let artist: String
    public let audioFileURL: URL
    public let startTime: TimeInterval
    public var endTime: TimeInterval?
    public var duration: TimeInterval

    public init(
        number: Int,
        title: String,
        artist: String,
        audioFileURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        duration: TimeInterval = 0
    ) {
        self.number = number
        self.title = title
        self.artist = artist
        self.audioFileURL = audioFileURL
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
    }
}

public struct CueSheet: Equatable {
    public let albumArtist: String
    public let albumTitle: String
    public let audioFileURL: URL?
    public var tracks: [CueTrack]
    public var genre: String?

    public init(albumArtist: String, albumTitle: String, audioFileURL: URL?, tracks: [CueTrack], genre: String? = nil) {
        self.albumArtist = albumArtist
        self.albumTitle = albumTitle
        self.audioFileURL = audioFileURL
        self.tracks = tracks
        self.genre = genre
    }
}

public enum CueSheetParser {
    public static func parse(url: URL, totalFileDuration: TimeInterval? = nil) throws -> CueSheet {
        let data = try Data(contentsOf: url)
        let content = decodeStringWithEncodings(data) ?? ""
        return parse(content: content, baseURL: url.deletingLastPathComponent(), totalFileDuration: totalFileDuration)
    }

    public static func parse(content: String, baseURL: URL, totalFileDuration: TimeInterval? = nil) -> CueSheet {
        var albumArtist = "Unknown Artist"
        var albumTitle = "Unknown Album"
        var genre: String?
        var currentFile: URL?
        var parsedTracks: [CueTrack] = []

        var currentTrackNum: Int?
        var currentTrackTitle: String?
        var currentTrackArtist: String?
        var currentTrackStartTime: TimeInterval?

        let lines = content.components(separatedBy: .newlines)

        func finalizeTrack() {
            guard let trackNum = currentTrackNum,
                  let startTime = currentTrackStartTime,
                  let fileUrl = currentFile else {
                return
            }
            let title = currentTrackTitle ?? "Track \(trackNum)"
            let artist = currentTrackArtist ?? albumArtist
            let track = CueTrack(
                number: trackNum,
                title: title,
                artist: artist,
                audioFileURL: fileUrl,
                startTime: startTime,
                endTime: nil,
                duration: 0
            )
            parsedTracks.append(track)
            currentTrackTitle = nil
            currentTrackArtist = nil
            currentTrackStartTime = nil
            currentTrackNum = nil
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("REM GENRE") {
                let g = splitCueLine(line)
                if g.count >= 3 { genre = g[2...].joined(separator: " ") }
                continue
            }
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("REM") {
                continue
            }

            let parts = splitCueLine(line)
            guard let command = parts.first?.uppercased() else { continue }

            switch command {
            case "PERFORMER":
                let val = extractQuotedOrFull(parts: parts, from: 1)
                if currentTrackNum != nil {
                    currentTrackArtist = val
                } else {
                    albumArtist = val
                }

            case "TITLE":
                let val = extractQuotedOrFull(parts: parts, from: 1)
                if currentTrackNum != nil {
                    currentTrackTitle = val
                } else {
                    albumTitle = val
                }

            case "FILE":
                // FILE "name with spaces.wav" WAVE  |  FILE name.wav WAVE  — the last token is the file type.
                let filename: String
                if let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close {
                    filename = String(line[line.index(after: open)..<close])
                } else if parts.count >= 3 {
                    filename = parts[1..<(parts.count - 1)].joined(separator: " ")
                } else {
                    filename = parts.count > 1 ? parts[1] : ""
                }
                currentFile = resolveAudioFile(filename: filename, baseURL: baseURL)

            case "TRACK":
                finalizeTrack()
                if parts.count >= 2, let num = Int(parts[1]) {
                    currentTrackNum = num
                }

            case "INDEX":
                if parts.count >= 3 && parts[1] == "01" {
                    let timecode = parts[2]
                    currentTrackStartTime = parseTimecode(timecode)
                }

            default:
                break
            }
        }
        finalizeTrack()

        // Sanitize and calculate durations
        var sanitizedTracks: [CueTrack] = []
        var lastTime: TimeInterval = 0

        for var track in parsedTracks {
            if track.startTime < lastTime {
                // Sanitize non-monotonic timecodes
                track = CueTrack(
                    number: track.number,
                    title: track.title,
                    artist: track.artist,
                    audioFileURL: track.audioFileURL,
                    startTime: lastTime,
                    endTime: track.endTime,
                    duration: track.duration
                )
            }
            lastTime = track.startTime
            sanitizedTracks.append(track)
        }

        // Compute end times & durations
        for i in 0..<sanitizedTracks.count {
            if i + 1 < sanitizedTracks.count {
                let nextStart = sanitizedTracks[i + 1].startTime
                sanitizedTracks[i].endTime = nextStart
                sanitizedTracks[i].duration = max(0, nextStart - sanitizedTracks[i].startTime)
            } else if let total = totalFileDuration {
                let clampedTotal = max(sanitizedTracks[i].startTime, total)
                sanitizedTracks[i].endTime = clampedTotal
                sanitizedTracks[i].duration = max(0, clampedTotal - sanitizedTracks[i].startTime)
            } else {
                sanitizedTracks[i].duration = 0
            }
        }

        return CueSheet(
            albumArtist: albumArtist,
            albumTitle: albumTitle,
            audioFileURL: currentFile,
            tracks: sanitizedTracks,
            genre: genre
        )
    }

    public static func parseTimecode(_ timecode: String) -> TimeInterval {
        // Format: mm:ss:ff (where 1 frame = 1/75 sec)
        let pieces = timecode.split(separator: ":")
        guard pieces.count == 3,
              let mm = Double(pieces[0]),
              let ss = Double(pieces[1]),
              let ff = Double(pieces[2]) else {
            return 0
        }
        // "inf:00:00", "nan:…" and absurd values would poison every duration computed from them.
        return Track.sanitizedDuration((mm * 60.0) + ss + (ff / 75.0))
    }

    public static func resolveAudioFile(filename: String, baseURL: URL) -> URL {
        let fileManager = FileManager.default
        // file:// URLs, absolute paths and relative paths (with sub-folders) are honoured as written.
        if filename.lowercased().hasPrefix("file://"), let u = URL(string: filename), u.isFileURL {
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        let unixStyle = filename.replacingOccurrences(of: "\\", with: "/")
        if unixStyle.hasPrefix("/") {
            if fileManager.fileExists(atPath: unixStyle) { return URL(fileURLWithPath: unixStyle) }
        } else if !unixStyle.contains(":") {
            let relative = baseURL.appendingPathComponent(unixStyle).standardizedFileURL
            if fileManager.fileExists(atPath: relative.path) { return relative }
        }

        // Otherwise look for the bare file name next to the playlist/CUE (handles Windows
        // drive paths such as C:\Music\album.wav and moved albums).
        var cleanName = filename
        if let lastBackslash = cleanName.lastIndex(of: "\\") {
            cleanName = String(cleanName[cleanName.index(after: lastBackslash)...])
        }
        if let lastSlash = cleanName.lastIndex(of: "/") {
            cleanName = String(cleanName[cleanName.index(after: lastSlash)...])
        }

        let direct = baseURL.appendingPathComponent(cleanName)
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }

        // Try standard audio extensions if not found
        let baseStem = (cleanName as NSString).deletingPathExtension
        let exts = ["flac", "m4a", "mp3", "wav", "aiff", "aac"]
        for ext in exts {
            let candidate = baseURL.appendingPathComponent("\(baseStem).\(ext)")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Nothing found: keep an absolute path as written (shown as missing), else the local guess.
        return unixStyle.hasPrefix("/") ? URL(fileURLWithPath: unixStyle) : direct
    }

    private static func splitCueLine(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func extractQuotedOrFull(parts: [String], from index: Int) -> String {
        guard index < parts.count else { return "" }
        let joined = parts[index...].joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    public static func decodeStringWithEncodings(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        // UTF-8 (with or without BOM) is unambiguous when it validates.
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }

        // Let Foundation's detector score the legacy candidates.
        var converted: NSString?
        var lossy: ObjCBool = false
        let suggestions: [String.Encoding] = [.shiftJIS, .windowsCP1251, .windowsCP1252]
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: suggestions.map { NSNumber(value: $0.rawValue) },
                .allowLossyKey: false
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        if raw != 0, let s = converted as String? { return s }

        for enc in [String.Encoding.shiftJIS, .windowsCP1251, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

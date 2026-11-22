import Foundation
import AppKit
import Accelerate
import AVFoundation
import UniformTypeIdentifiers

public enum AppTests {
    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        // AppConfig tests
        testRunner("AppConfig returns valid non-empty application name") {
            assert(!AppConfig.appName.isEmpty, "App name should not be empty")
        }

        testRunner("AppConfig returns valid bundle identifier") {
            assert(!AppConfig.bundleIdentifier.isEmpty, "Bundle identifier should not be empty")
            assert(AppConfig.bundleIdentifier.contains("."), "Bundle identifier should be reverse-DNS style")
        }

        testRunner("AppConfig provides version string") {
            assert(!AppConfig.version.isEmpty, "Version should not be empty")
        }

        testRunner("AppConfig provides build number") {
            assert(!AppConfig.buildNumber.isEmpty, "Build number should not be empty")
        }

        testRunner("StatusBarController initializes menu correctly") {
            let controller = StatusBarController()
            assert(controller.currentMenu.items.count >= 2, "Menu should have items")
            assert(controller.currentMenu.items.contains { $0.title.contains("Quit") }, "Menu should contain quit item")
        }

        // CueSheetParser tests
        testRunner("CueSheetParser parses timecodes accurately") {
            let t1 = CueSheetParser.parseTimecode("00:00:00")
            assert(t1 == 0.0, "00:00:00 should be 0s")

            let t2 = CueSheetParser.parseTimecode("01:08:00")
            assert(t2 == 68.0, "01:08:00 should be 68s")

            let t3 = CueSheetParser.parseTimecode("02:30:37")
            let expected = (2.0 * 60.0) + 30.0 + (37.0 / 75.0)
            assert(abs(t3 - expected) < 0.001, "02:30:37 should match frame calculation")
        }

        testRunner("CueSheetParser resolves Windows backslash paths to basename") {
            let base = URL(fileURLWithPath: "/Music")
            let resolved = CueSheetParser.resolveAudioFile(filename: "C:\\Music\\Album\\track.flac", baseURL: base)
            assert(resolved.lastPathComponent == "track.flac", "Should resolve to basename")
        }

        testRunner("CueSheetParser parses multi-track CUE sheets with gapless boundaries") {
            let cueContent = """
            PERFORMER "Pink Floyd"
            TITLE "The Dark Side of the Moon"
            FILE "album.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Speak to Me"
                PERFORMER "Pink Floyd"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Breathe"
                PERFORMER "Pink Floyd"
                INDEX 01 01:08:00
              TRACK 03 AUDIO
                TITLE "On the Run"
                PERFORMER "Pink Floyd"
                INDEX 01 03:57:00
            """
            let base = URL(fileURLWithPath: "/tmp")
            let sheet = CueSheetParser.parse(content: cueContent, baseURL: base, totalFileDuration: 500.0)

            assert(sheet.albumTitle == "The Dark Side of the Moon", "Album title should match")
            assert(sheet.albumArtist == "Pink Floyd", "Artist should match")
            assert(sheet.tracks.count == 3, "Should parse 3 tracks")

            // Track 1
            assert(sheet.tracks[0].title == "Speak to Me", "Track 1 title")
            assert(sheet.tracks[0].startTime == 0.0, "Track 1 start time")
            assert(sheet.tracks[0].endTime == 68.0, "Track 1 end time")
            assert(sheet.tracks[0].duration == 68.0, "Track 1 duration")

            // Track 2
            assert(sheet.tracks[1].title == "Breathe", "Track 2 title")
            assert(sheet.tracks[1].startTime == 68.0, "Track 2 start time")
            let t3Start = (3.0 * 60.0) + 57.0
            assert(sheet.tracks[1].endTime == t3Start, "Track 2 end time")
            assert(sheet.tracks[1].duration == t3Start - 68.0, "Track 2 duration")

            // Track 3
            assert(sheet.tracks[2].endTime == 500.0, "Final track ends at totalFileDuration")
        }

        testRunner("CueSheetParser sanitizes non-monotonic timecodes") {
            let badCue = """
            FILE "test.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Track 1"
                INDEX 01 02:00:00
              TRACK 02 AUDIO
                TITLE "Track 2"
                INDEX 01 01:00:00
            """
            let sheet = CueSheetParser.parse(content: badCue, baseURL: URL(fileURLWithPath: "/tmp"))
            assert(sheet.tracks.count == 2)
            assert(sheet.tracks[1].startTime >= sheet.tracks[0].startTime, "Timecodes must be monotonic")
        }

        // PlaylistManager tests
        testRunner("PlaylistManager adds tracks and handles selection") {
            let manager = PlaylistManager()
            assert(manager.count == 0)

            let t1 = Track(url: URL(fileURLWithPath: "/tmp/song1.mp3"), title: "Song 1", artist: "Artist A", duration: 180)
            let t2 = Track(url: URL(fileURLWithPath: "/tmp/song2.mp3"), title: "Song 2", artist: "Artist B", duration: 240)

            manager.addTracks([t1, t2])
            assert(manager.count == 2, "Should have 2 tracks")
            assert(manager.totalSeconds == 420, "Total should be 420 seconds")

            manager.setSelection([1])
            assert(manager.selectedIndices.contains(1), "Index 1 should be selected")
            manager.selectAll()
            assert(manager.selectedIndices.count == 2, "Select all selects both")
            manager.selectNone()
            assert(manager.selectedIndices.isEmpty, "Select none clears selection")
        }

        testRunner("PlaylistManager Fisher-Yates non-repeating shuffle guarantees all tracks play once") {
            let manager = PlaylistManager()
            var tracks: [Track] = []
            for i in 0..<10 {
                tracks.append(Track(url: URL(fileURLWithPath: "/tmp/song\(i).mp3"), title: "Song \(i)", duration: 60))
            }
            manager.setTracks(tracks)
            manager.shuffleEnabled = true
            manager.currentIndex = 0

            var playedIndices: Set<Int> = [0]
            for _ in 0..<9 {
                if let next = manager.nextIndex() {
                    assert(!playedIndices.contains(next), "Every track in shuffle must play once before repeating")
                    playedIndices.insert(next)
                    manager.currentIndex = next
                }
            }
            assert(playedIndices.count == 10, "All 10 tracks must be played once")
        }

        testRunner("PlaylistManager Jump-to-File executes 3-tiered search ranking") {
            let manager = PlaylistManager()
            let t1 = Track(url: URL(fileURLWithPath: "/tmp/1.mp3"), title: "Pink Floyd - Time")
            let t2 = Track(url: URL(fileURLWithPath: "/tmp/2.mp3"), title: "Floydian Slip")
            let t3 = Track(url: URL(fileURLWithPath: "/tmp/3.mp3"), title: "Something about Pink")

            manager.setTracks([t3, t2, t1])
            let results = manager.search(query: "pink")

            assert(!results.isEmpty, "Results should not be empty")
            // Tier 1 prefix match should be first
            assert(results[0].title.lowercased().hasPrefix("pink"), "Prefix match must rank first")
        }

        testRunner("PlaylistManager exports and imports M3U format") {
            let manager = PlaylistManager()
            let t1 = Track(url: URL(fileURLWithPath: "/tmp/test1.mp3"), title: "Test Title 1", artist: "Artist 1", duration: 125)
            manager.addTracks([t1])

            let exportURL = URL(fileURLWithPath: "/tmp/test_export.m3u")
            try manager.exportM3U(to: exportURL)

            let imported = try PlaylistManager.parseM3U(url: exportURL)
            assert(imported.count == 1, "Should import 1 track")
            assert(imported[0].title == "Test Title 1", "Title should match")
            assert(imported[0].duration == 125, "Duration should match")
            try? FileManager.default.removeItem(at: exportURL)
        }

        // EqualizerPresets tests
        testRunner("EqualizerPresets includes 18 factory presets with 10 bands") {
            assert(EqualizerPresets.factoryPresets.count == 18, "Must contain exactly 18 factory presets")
            for preset in EqualizerPresets.factoryPresets {
                assert(preset.bands.count == 10, "\(preset.name) must have 10 frequency bands")
            }
        }

        testRunner("EqualizerPresets auto-matches genres") {
            let rock = EqualizerPresets.matchPreset(forGenre: "Alternative Rock")
            assert(rock?.name == "Rock", "Should match Rock preset")

            let pop = EqualizerPresets.matchPreset(forGenre: "Synth Pop")
            assert(pop?.name == "Pop", "Should match Pop preset")

            let classical = EqualizerPresets.matchPreset(forGenre: "Symphony Orchestra")
            assert(classical?.name == "Classical", "Should match Classical preset")
        }

        // SkinEngine tests
        testRunner("SkinEngine parses PLEDIT.TXT colors") {
            let pleditTxt = """
            [Text]
            Normal=#00FF00
            Current=#FFFFFF
            NormalBG=#000000
            SelectedBG=#0000C6
            Font=Courier
            """
            let colors = SkinParser().parsePleditTxt(pleditTxt)
            assert(colors.fontName == "Courier", "Font should be Courier")
            assert(colors.normalText.redComponent == 0.0 && colors.normalText.greenComponent == 1.0, "Normal should be #00FF00")
        }

        testRunner("SkinEngine parses VISCOLOR.TXT 24 color palette") {
            var visContent = ""
            for i in 0..<24 {
                visContent += "\(i * 10),\(i * 10),\(i * 10)\n"
            }
            let vis = SkinParser().parseViscolorTxt(visContent)
            assert(vis.colors.count == 24, "Must parse 24 colors")
        }

        testRunner("SkinEngine loads bundled base-2.91 skin successfully") {
            let skin = SkinEngine.shared
            skin.loadDefaultSkin()
            assert(skin.getCGImage(named: "MAIN.BMP") != nil, "MAIN.BMP must be loaded")
            assert(skin.getCGImage(named: "CBUTTONS.BMP") != nil, "CBUTTONS.BMP must be loaded")
            assert(skin.getCGImage(named: "EQMAIN.BMP") != nil, "EQMAIN.BMP must be loaded")
            assert(skin.getCGImage(named: "PLEDIT.BMP") != nil, "PLEDIT.BMP must be loaded")
        }

        // WindowManager tests
        testRunner("WindowManager scales snap distance proportionally in Double-Size mode") {
            let wm = WindowManager.shared
            wm.setDoubleSize(false)
            assert(wm.snapDistance == 10.0, "Normal snap distance must be 10pt")

            wm.setDoubleSize(true)
            assert(wm.snapDistance == 20.0, "Double-size snap distance must be 20pt")
            wm.setDoubleSize(false)
        }

        testRunner("WindowManager computes glued clusters correctly") {
            let wm = WindowManager.shared
            wm.breakBonds(for: .main)
            wm.breakBonds(for: .equalizer)
            wm.breakBonds(for: .playlist)

            wm.addBond(between: .main, and: .equalizer)
            wm.addBond(between: .equalizer, and: .playlist)

            let cluster = wm.cluster(for: .main)
            assert(cluster.count == 3, "All 3 windows should be in the glued cluster")
            assert(cluster.contains(.main) && cluster.contains(.equalizer) && cluster.contains(.playlist))
        }

        // ZipArchive (in-process .wsz reader)
        testRunner("ZipArchive extracts the bundled skin in memory with lowercased names") {
            guard let url = AppConfig.bundledSkinURL else { throw TestError.failed("bundled skin missing") }
            let files = try ZipArchive.extract(data: try Data(contentsOf: url))
            assert(files["main.bmp"] != nil, "main.bmp must be present")
            assert(files["pledit.txt"] != nil, "pledit.txt must be present")
            assert(files.count >= 20, "Base skin has ~29 entries")
        }

        testRunner("ZipArchive rejects path traversal, truncation and corrupt data") {
            func storedZip(name: String, payload: [UInt8], crc: UInt32? = nil) -> Data {
                func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
                func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
                let n = Array(name.utf8)
                let c = crc ?? ZipArchive.crc32(payload)
                var local: [UInt8] = le32(0x04034B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                local += le32(c) + le32(UInt32(payload.count)) + le32(UInt32(payload.count)) + le16(n.count) + le16(0) + n + payload
                var central: [UInt8] = le32(0x02014B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                central += le32(c) + le32(UInt32(payload.count)) + le32(UInt32(payload.count)) + le16(n.count) + le16(0) + le16(0)
                central += le16(0) + le16(0) + le32(0) + le32(0) + n
                let eocd: [UInt8] = le32(0x06054B50) + le16(0) + le16(0) + le16(1) + le16(1)
                    + le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0)
                return Data(local + central + eocd)
            }
            let ok = try ZipArchive.extract(data: storedZip(name: "Skin/MAIN.BMP", payload: [1, 2, 3]))
            assert(ok["main.bmp"] == Data([1, 2, 3]), "Nested entries flatten to lowercased basenames")

            var rejected = 0
            for bad in [storedZip(name: "../../evil.bmp", payload: [1]),
                        storedZip(name: "x.bmp", payload: [1, 2], crc: 0xDEADBEEF),
                        storedZip(name: "x.bmp", payload: [1, 2]).prefix(30),
                        Data("not a zip at all".utf8)] {
                do { _ = try ZipArchive.extract(data: Data(bad)) } catch { rejected += 1 }
            }
            assert(rejected == 4, "Traversal, CRC mismatch, truncation and garbage must all be rejected")
        }

        testRunner("SkinEngine keeps the current skin when a corrupt archive is loaded") {
            let skin = SkinEngine.shared
            skin.loadDefaultSkin()
            let bad = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("amp_bad_\(UUID().uuidString).wsz")
            try Data("PK\u{3}\u{4}garbage".utf8).write(to: bad)
            defer { try? FileManager.default.removeItem(at: bad) }
            assert(skin.loadSkin(at: bad) == false, "Corrupt skin must fail")
            assert(skin.getCGImage(named: "MAIN.BMP") != nil, "Previous skin must remain active")
        }

        testRunner("Bitmap font normalizes case, diacritics and unsupported characters") {
            assert(SkinEngine.normalizeForBitmapFont("Chylińska") == "CHYLINSKA")
            assert(SkinEngine.normalizeForBitmapFont("a<b>") == "A(B)")
            assert(SkinEngine.normalizeForBitmapFont("日本") == "  ", "Unknown glyphs become spaces")
        }

        testRunner("CueSheetParser strips the file-type token from FILE lines and reads REM GENRE") {
            let cue = """
            REM GENRE Rock
            FILE "C:\\Rips\\My Album.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            """
            let sheet = CueSheetParser.parse(content: cue, baseURL: URL(fileURLWithPath: "/tmp"))
            assert(sheet.audioFileURL?.lastPathComponent == "My Album.flac", "FILE must resolve to the quoted basename only")
            assert(sheet.genre == "Rock", "REM GENRE must be captured")
        }

        testRunner("Track gapless successor requires the same file and contiguous CUE bounds") {
            let url = URL(fileURLWithPath: "/tmp/album.flac")
            let a = Track(url: url, title: "A", duration: 60, isCueSegment: true, cueStartTime: 0, cueEndTime: 60)
            let b = Track(url: url, title: "B", duration: 60, isCueSegment: true, cueStartTime: 60, cueEndTime: 120)
            let c = Track(url: URL(fileURLWithPath: "/tmp/other.flac"), title: "C", isCueSegment: true, cueStartTime: 120)
            assert(b.isGaplessSuccessor(of: a), "Contiguous segments are gapless")
            assert(!c.isGaplessSuccessor(of: b), "A different file is not gapless")
            assert(!a.isGaplessSuccessor(of: b), "Order matters")
        }

        testRunner("WindowManager detects glued (touching) windows geometrically") {
            let main = NSRect(x: 100, y: 500, width: 275, height: 116)
            let below = NSRect(x: 100, y: 384, width: 275, height: 116)
            let side = NSRect(x: 375, y: 500, width: 275, height: 232)
            let apart = NSRect(x: 100, y: 300, width: 275, height: 116)
            assert(WindowManager.areTouching(main, below), "Stacked windows are glued")
            assert(WindowManager.areTouching(main, side), "Side-by-side windows are glued")
            assert(!WindowManager.areTouching(main, apart), "Separated windows are not glued")
        }

        testRunner("ApplicationState decodes partial/legacy state files with defaults") {
            let json = #"{"volume": 0.5, "repeatMode": "track", "playlistTracks": [{"bogus": true}]}"#
            let state = try JSONDecoder().decode(ApplicationState.self, from: Data(json.utf8))
            assert(state.volume == 0.5, "Present fields are read")
            assert(state.repeatMode == .track)
            assert(state.eqBandGains.count == 10, "Missing fields fall back to defaults")
            assert(state.playlistTracks.isEmpty, "Malformed tracks are skipped, not fatal")
        }

        testRunner("PlaylistManager keeps the current track across sorting and reordering") {
            let manager = PlaylistManager()
            let tracks = ["C", "A", "B"].map { (name: String) in Track(url: URL(fileURLWithPath: "/tmp/\(name).mp3"), title: name) }
            manager.setTracks(tracks)
            manager.currentIndex = 0 // "C"
            manager.sortByTitle()
            assert(manager.currentTrack?.title == "C" && manager.currentIndex == 2, "Current follows the track after sort")
            manager.moveTracks(from: IndexSet(integer: 2), to: 0)
            assert(manager.currentTrack?.title == "C" && manager.currentIndex == 0, "Current follows the track after move")
        }

        testRunner("Unreadable audio files import as missing instead of failing") {
            let bad = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("amp_corrupt_\(UUID().uuidString).mp3")
            try Data(repeating: 0x42, count: 4096).write(to: bad)
            defer { try? FileManager.default.removeItem(at: bad) }
            let result = LibraryImporter.importURLs([bad])
            assert(result.tracks.count == 1 && result.tracks[0].missing, "Corrupt media is listed but flagged")
        }

        testRunner("Jump-to-File search over 10,000 tracks stays under 16 ms") {
            let manager = PlaylistManager()
            manager.setTracks((0..<10_000).map { Track(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), title: "Song number \($0)", artist: "Artist \($0 % 97)") })
            _ = manager.search(query: "warm") // builds the index once
            let start = CFAbsoluteTimeGetCurrent()
            let hits = manager.search(query: "artist 42")
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            assert(!hits.isEmpty)
            assert(ms < 16, "Search took \(ms) ms")
        }

        testRunner("PlaylistManager randomizes the list order, keeping every track and the current one") {
            let manager = PlaylistManager()
            let tracks = (0..<50).map { (i: Int) in Track(url: URL(fileURLWithPath: "/tmp/r\(i).mp3"), title: "T\(i)") }
            manager.setTracks(tracks)
            manager.currentIndex = 7
            let currentID = manager.currentTrack?.id
            manager.randomizeOrder()
            assert(Set(manager.tracks.map { $0.id }) == Set(tracks.map { $0.id }), "No track lost or duplicated")
            assert(manager.tracks.map { $0.id } != tracks.map { $0.id }, "Order changed (50! permutations)")
            assert(manager.currentTrack?.id == currentID, "Current track is preserved")
        }

        testRunner("Window shade rolls the EQ up to its title bar and pulls the docked playlist up with it") {
            let wm = WindowManager.shared
            let eq = EqualizerWindow()
            let pl = PlaylistWindow(playlistManager: PlaylistManager())
            wm.eqWindow = eq
            wm.playlistWindow = pl
            eq.setFrame(NSRect(x: 100, y: 500, width: 275, height: 116), display: false)
            pl.setFrame(NSRect(x: 100, y: 268, width: 275, height: 232), display: false)
            eq.orderFront(nil); pl.orderFront(nil)
            wm.recomputeBonds()
            wm.setShaded(.equalizer, true)
            assert(eq.frame == NSRect(x: 100, y: 602, width: 275, height: 14), "EQ keeps its top edge: \(eq.frame)")
            assert(eq.contentView === eq.shadeView)
            assert(pl.frame.maxY == eq.frame.minY, "Playlist stays docked: \(pl.frame)")
            wm.setShaded(.equalizer, false)
            assert(eq.frame == NSRect(x: 100, y: 500, width: 275, height: 116), "EQ unrolls: \(eq.frame)")
            assert(eq.contentView === eq.eqView)
            assert(pl.frame.maxY == 500, "Playlist moves back down: \(pl.frame)")
            eq.orderOut(nil); pl.orderOut(nil)
        }

        // MARK: Hostile-review regressions

        testRunner("F1: playlist/CUE durations of inf, nan or huge values import as finite and never crash formatting") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("f1-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "#EXTINF:inf,A - B\n/nonexistent/a.mp3\n#EXTINF:1e300,C - D\n/nonexistent/c.mp3\n#EXTINF:-1,E - F\n/nonexistent/e.mp3\n"
                .write(to: dir.appendingPathComponent("p.m3u"), atomically: true, encoding: .utf8)
            try "[playlist]\nFile1=/nonexistent/x.mp3\nLength1=nan\nNumberOfEntries=1\n"
                .write(to: dir.appendingPathComponent("p.pls"), atomically: true, encoding: .utf8)
            try "FILE \"missing.wav\" WAVE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n TRACK 02 AUDIO\n  INDEX 01 inf:00:00\n TRACK 03 AUDIO\n  INDEX 01 nan:00:00\n"
                .write(to: dir.appendingPathComponent("p.cue"), atomically: true, encoding: .utf8)
            for name in ["p.m3u", "p.pls", "p.cue"] {
                let tracks = LibraryImporter.importURLs([dir.appendingPathComponent(name)]).tracks
                assert(!tracks.isEmpty, "\(name) imported nothing")
                for t in tracks {
                    assert(t.duration.isFinite && t.duration >= 0, "\(name): duration \(t.duration)")
                    assert(t.cueStartTime.isFinite && (t.cueEndTime ?? 0).isFinite, "\(name): cue bounds \(t.cueStartTime) \(String(describing: t.cueEndTime))")
                }
                assert((try? JSONEncoder().encode(tracks)) != nil, "\(name): tracks must stay JSON-encodable")
            }
            // Formatting must survive non-finite values that reach a Track from anywhere else.
            for bad in [Double.infinity, -Double.infinity, Double.nan, 1e300, -5] {
                let t = Track(url: URL(fileURLWithPath: "/tmp/x.mp3"), title: "x", duration: bad)
                assert(t.formattedDuration == "00:00", "formattedDuration(\(bad)) = \(t.formattedDuration)")
                assert(RetroLCDView.shortTime(bad) == "0:00", "shortTime(\(bad))")
            }
            let pm = PlaylistManager()
            pm.setTracks([Track(url: URL(fileURLWithPath: "/tmp/y.mp3"), title: "y", duration: .infinity)])
            _ = pm.totalSeconds
        }

        testRunner("F2: skin images with oversized dimensions are skipped before decoding; required MAIN.BMP oversize rejects the skin") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("f2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            func png(_ w: Int, _ h: Int) -> Data {
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
                return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            }
            let base = try ZipArchive.extract(data: Data(contentsOf: URL(fileURLWithPath: "Resources/base-2.91.wsz")))
            // Valid MAIN.BMP, oversized TEXT.BMP: skin loads, the oversized sprite is dropped.
            try base["main.bmp"]!.write(to: dir.appendingPathComponent("MAIN.BMP"))
            try png(5000, 5000).write(to: dir.appendingPathComponent("TEXT.BMP"))
            let skin = try SkinEngine.buildSkin(at: dir)
            assert(skin.images["main.bmp"] != nil)
            assert(skin.images["text.bmp"] == nil, "5000x5000 TEXT.BMP must be refused")
            // Oversized MAIN.BMP: the whole skin is rejected.
            try png(5000, 5000).write(to: dir.appendingPathComponent("MAIN.BMP"))
            assert((try? SkinEngine.buildSkin(at: dir)) == nil, "oversized MAIN.BMP must reject the skin")
        }

        testRunner("F6: exported M3U/PLS cannot be split by titles or paths containing line breaks") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("f6-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let pm = PlaylistManager()
            pm.setTracks([Track(url: URL(fileURLWithPath: "/tmp/one.mp3"), title: "Line1\n/injected/path.mp3\r\nLine3", artist: "Art", duration: 10)])
            try pm.exportM3U(to: dir.appendingPathComponent("o.m3u"))
            try pm.exportPLS(to: dir.appendingPathComponent("o.pls"))
            let m3u = try PlaylistManager.parseM3U(url: dir.appendingPathComponent("o.m3u"))
            let pls = try PlaylistManager.parsePLS(url: dir.appendingPathComponent("o.pls"))
            assert(m3u.count == 1, "M3U entries: \(m3u.map { $0.url.path })")
            assert(pls.count == 1, "PLS entries: \(pls.map { $0.url.path })")
            assert(m3u[0].url.path == "/tmp/one.mp3", "absolute path must survive: \(m3u[0].url.path)")
            assert(pls[0].url.path == "/tmp/one.mp3")
        }

        testRunner("F7: saved playlists reload with absolute, relative (sub-folder) and bare-name paths intact") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("f7-\(UUID().uuidString)")
            let sub = dir.appendingPathComponent("Album")
            let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("f7-elsewhere-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: elsewhere) }
            let abs = elsewhere.appendingPathComponent("abs.mp3"), rel = sub.appendingPathComponent("rel.mp3"), bare = dir.appendingPathComponent("bare.mp3")
            for f in [abs, rel, bare] { try Data([0]).write(to: f) }
            try "\(abs.path)\nAlbum/rel.mp3\nC:\\Music\\bare.mp3\n".write(to: dir.appendingPathComponent("l.m3u"), atomically: true, encoding: .utf8)
            let paths = try PlaylistManager.parseM3U(url: dir.appendingPathComponent("l.m3u")).map { $0.url.standardizedFileURL.path }
            assert(paths == [abs, rel, bare].map { $0.standardizedFileURL.path }, "\(paths)")
        }

        testRunner("F3: segments longer than UInt32 frames are scheduled in chunks; non-finite CUE bounds never trap") {
            let long: Int64 = 28 * 3600 * 44_100 // 28 h audiobook at 44.1 kHz > UInt32.max frames
            guard let b = AudioEngine.segmentBounds(length: long, sampleRate: 44_100, cueStart: nil, cueEnd: nil, offset: 0) else {
                assertionFailure("long file must yield a segment"); return
            }
            assert(b.start == 0 && b.count == long)
            let chunks = AudioEngine.chunkSizes(b.count)
            assert(chunks.count == 2 && chunks.reduce(Int64(0)) { $0 + Int64($1) } == long, "\(chunks)")
            assert(AudioEngine.chunkSizes(0).isEmpty)
            assert(AudioEngine.chunkSizes(10) == [10])
            // Seek offset past the end, NaN/inf CUE times and NaN offsets: no segment, no trap.
            assert(AudioEngine.segmentBounds(length: 1000, sampleRate: 100, cueStart: nil, cueEnd: nil, offset: 20) == nil)
            for bad in [Double.nan, .infinity] {
                _ = AudioEngine.segmentBounds(length: 1000, sampleRate: 100, cueStart: bad, cueEnd: bad, offset: 0)
                _ = AudioEngine.segmentBounds(length: 1000, sampleRate: 100, cueStart: 1, cueEnd: 5, offset: bad)
            }
            let cue = AudioEngine.segmentBounds(length: 1000, sampleRate: 100, cueStart: 2, cueEnd: 5, offset: 1)
            assert(cue?.start == 300 && cue?.count == 200, "\(String(describing: cue))")
        }

        testRunner("F4: the periodic save writes a small state file and rewrites the playlist only after it changed") {
            let pm = PlaylistManager()
            let r0 = pm.revision
            pm.setTracks((0..<10_000).map { Track(url: URL(fileURLWithPath: "/tmp/\($0).m4a"), title: "Track \($0)", artist: "Artist", duration: 200) })
            assert(pm.revision != r0, "setTracks must bump the revision")
            let r1 = pm.revision
            pm.currentIndex = 5
            pm.setSelection([1, 2])
            assert(pm.revision == r1, "position/selection changes are not playlist edits")
            pm.reverseOrder()
            assert(pm.revision != r1, "reordering is a playlist edit")

            var state = ApplicationState()
            state.playbackPosition = 42
            let unchanged = try AppStateManager.encodePayloads(state: state, tracks: nil)
            assert(unchanged.playlist == nil)
            assert(unchanged.state.count < 16_384, "state.json must not carry the playlist: \(unchanged.state.count) bytes")
            let changed = try AppStateManager.encodePayloads(state: state, tracks: pm.tracks)
            let decoded = AppStateManager.decodePlaylist(changed.playlist!)
            assert(decoded?.count == 10_000 && decoded?.first?.id == pm.tracks.first?.id)
            // Legacy state.json (tracks embedded) still decodes for migration.
            var legacy = ApplicationState(); legacy.playlistTracks = Array(pm.tracks.prefix(3))
            let legacyData = try JSONEncoder().encode(legacy)
            let legacyDecoded = try JSONDecoder().decode(ApplicationState.self, from: legacyData)
            assert(legacyDecoded.playlistTracks.count == 3)
        }

        testRunner("F5: launch only claims the media keys when the player was playing at quit and nothing else is playing") {
            assert(AudioEngine.shouldClaimMediaKeysAtLaunch(restoredWasPlaying: true, otherAudioPlaying: false))
            assert(!AudioEngine.shouldClaimMediaKeysAtLaunch(restoredWasPlaying: true, otherAudioPlaying: true), "never steal from a playing app")
            assert(!AudioEngine.shouldClaimMediaKeysAtLaunch(restoredWasPlaying: false, otherAudioPlaying: false))
            _ = AudioEngine.isOtherAudioPlaying() // must not crash without an output device
        }

        testRunner("Media-key events decode play/next/previous with down, up and repeat states") {
            let down = MediaKeyMonitor.decode(subtype: 8, data1: (16 << 16) | (0x0A << 8))
            assert(down?.key == .play && down?.down == true && down?.isRepeat == false)
            let up = MediaKeyMonitor.decode(subtype: 8, data1: (17 << 16) | (0x0B << 8))
            assert(up?.key == .next && up?.down == false)
            let rep = MediaKeyMonitor.decode(subtype: 8, data1: (19 << 16) | (0x0A << 8) | 1)
            assert(rep?.key == .fast && rep?.isRepeat == true)
            assert(MediaKeyMonitor.decode(subtype: 7, data1: 16 << 16) == nil, "other subtypes are ignored")
            assert(MediaKeyMonitor.decode(subtype: 8, data1: 0 << 16) == nil, "volume/brightness keys are ignored")
            assert(MediaKeyMonitor.processIsRunning(named: "launchd"))
            assert(!MediaKeyMonitor.processIsRunning(named: "no-such-process-xyz"))
        }

        testRunner("Status bar menu offers Show Dock Icon; main window rolls up to a 14 px shade bar and back") {
            let controller = StatusBarController()
            assert(controller.currentMenu.items.contains { $0.title == "Show Dock Icon" })
            let wm = WindowManager.shared
            let main = MainWindow()
            wm.mainWindow = main
            main.setFrame(NSRect(x: 50, y: 600, width: 275, height: 116), display: false)
            main.orderFront(nil)
            wm.setShaded(.main, true)
            assert(main.frame == NSRect(x: 50, y: 702, width: 275, height: 14), "\(main.frame)")
            assert(main.contentView === main.shadeView)
            wm.setShaded(.main, false)
            assert(main.frame.height == 116 && main.contentView === main.mainView)
            main.orderOut(nil)
        }

        testRunner("SpectrumAnalyzer matches the original per-frame analysis exactly (sine sweep, noise, silence)") {
            // Verbatim copy of the pre-optimisation AudioEngine.analyze math, as the reference.
            func reference(_ window0: [Float], sr: Double, bins: Int, oscPoints: Int, available: Int) -> ([Float], [Float]) {
                let n = 1024
                var window = window0
                var setupHann = [Float](repeating: 0, count: n)
                vDSP_hann_window(&setupHann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
                let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
                defer { vDSP_destroy_fftsetup(setup) }
                var osc = [Float](repeating: 0, count: oscPoints)
                let step = max(1, available / oscPoints)
                for i in 0..<oscPoints { osc[i] = window[min(available - 1, i * step)] }
                vDSP_vmul(window, 1, setupHann, 1, &window, 1, vDSP_Length(n))
                var real = [Float](repeating: 0, count: n / 2), imag = real, mags = real
                real.withUnsafeMutableBufferPointer { rp in imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    window.withUnsafeBytes { raw in vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2)) }
                    vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                } }
                var spectrum = [Float](repeating: 0, count: bins)
                let minF: Float = 20, maxF: Float = 20000
                let ratio = pow(maxF / minF, 1.0 / Float(bins)), binHz = Float(sr) / Float(n)
                for i in 0..<bins {
                    let fLow = minF * pow(ratio, Float(i)), fHigh = minF * pow(ratio, Float(i + 1))
                    let kLow = max(1, min(n / 2 - 1, Int(fLow / binHz)))
                    let kHigh = max(kLow + 1, min(n / 2, Int(ceil(fHigh / binHz))))
                    var peak: Float = 0
                    for k in kLow..<kHigh { peak = max(peak, mags[k]) }
                    let db = 10 * log10(max(1e-12, peak / Float(n * n / 16)))
                    spectrum[i] = max(0, min(1, (db + 70) / 70))
                }
                return (spectrum, osc)
            }
            let analyzer = SpectrumAnalyzer()
            var rng = SystemRandomNumberGenerator()
            let inputs: [(String, [Float])] = [
                ("sweep", (0..<3000).map { i in sinf(Float(i) * Float(i) * 0.00002) * 0.8 }),
                ("noise", (0..<3000).map { _ in Float.random(in: -1...1, using: &rng) }),
                ("silence", [Float](repeating: 0, count: 3000)),
                ("short", (0..<300).map { i in sinf(Float(i) * 0.3) })
            ]
            for (name, samples) in inputs {
                for (sr, start) in [(44_100.0, 0), (48_000.0, 1500), (96_000.0, 2500)] {
                    let available = samples.withUnsafeBufferPointer { analyzer.load($0, start: min(start, max(0, samples.count - 1))) }
                    let s0 = min(start, max(0, samples.count - 1))
                    var win = [Float](repeating: 0, count: 1024)
                    for i in 0..<available { win[i] = samples[s0 + i] }
                    let ref = reference(win, sr: sr, bins: 32, oscPoints: 76, available: available)
                    let osc = analyzer.oscilloscope(points: 76, available: available)
                    let spec = analyzer.spectrum(bins: 32, sampleRate: sr)
                    assert(osc == ref.1, "\(name)@\(sr): oscilloscope differs")
                    for i in 0..<32 { assert(abs(spec[i] - ref.0[i]) < 1e-6, "\(name)@\(sr) bin \(i): \(spec[i]) vs \(ref.0[i])") }
                }
            }
        }

        testRunner("Playlist total length is cached and refreshed after edits") {
            let pm = PlaylistManager()
            pm.setTracks([Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", duration: 61),
                          Track(url: URL(fileURLWithPath: "/tmp/b.mp3"), title: "b", duration: .nan)])
            assert(pm.totalSeconds == 61)
            pm.addTracks([Track(url: URL(fileURLWithPath: "/tmp/c.mp3"), title: "c", duration: 120)])
            assert(pm.totalSeconds == 181, "cache must follow edits: \(pm.totalSeconds)")
        }

        testRunner("Status bar icon: clicks go to the controller (left = show player, right = menu), no menu attached") {
            let controller = StatusBarController()
            let item = controller.currentStatusItem
            assert(item.menu == nil, "an attached menu would swallow left clicks")
            assert(item.button?.action != nil && item.button?.target === controller)
            assert(!controller.currentMenu.items.isEmpty)
        }

        testRunner("R1: animations run only while their window is actually on screen") {
            assert(VisualizerView.shouldAnimate(visible: true, mode: .spectrum, playing: true, idle: true))
            assert(!VisualizerView.shouldAnimate(visible: false, mode: .spectrum, playing: true, idle: false), "hidden/covered: no frames")
            assert(!VisualizerView.shouldAnimate(visible: true, mode: .off, playing: true, idle: false))
            assert(VisualizerView.shouldAnimate(visible: true, mode: .oscilloscope, playing: false, idle: false), "let peaks fall after stop")
            assert(!VisualizerView.shouldAnimate(visible: true, mode: .spectrum, playing: false, idle: true))
            // A window that was never shown is not on screen.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
            let v = VisualizerView(frame: NSRect(x: 0, y: 0, width: 76, height: 16))
            w.contentView?.addSubview(v)
            assert(!v.isOnScreen)
        }

        testRunner("R2: status icon opens the menu for right-click, Control-click and accessibility presses") {
            assert(StatusBarController.wantsMenu(eventType: nil, modifiers: []), "AXPress / VoiceOver has no mouse event")
            assert(StatusBarController.wantsMenu(eventType: .rightMouseUp, modifiers: []))
            assert(StatusBarController.wantsMenu(eventType: .leftMouseUp, modifiers: [.control]))
            assert(!StatusBarController.wantsMenu(eventType: .leftMouseUp, modifiers: []), "plain left click shows the player")
        }

        testRunner("PlaylistManager sorts by duration, shortest first, unknown lengths last") {
            let manager = PlaylistManager()
            let durations: [TimeInterval] = [240, 0, 61, 3600, 61, 5]
            manager.setTracks(durations.enumerated().map { i, d in
                Track(url: URL(fileURLWithPath: "/tmp/d\(i).mp3"), title: "T\(i)", duration: d)
            })
            manager.currentIndex = 0 // the 240 s track
            let currentID = manager.currentTrack?.id
            manager.sortByDuration()
            assert(manager.tracks.map { $0.duration } == [5, 61, 61, 240, 3600, 0], "\(manager.tracks.map { $0.duration })")
            assert(manager.tracks[1].title == "T2" && manager.tracks[2].title == "T4", "Ties keep title order")
            assert(manager.currentTrack?.id == currentID, "Current track is preserved")
        }

        testRunner("Default player: every audio type resolves and nothing is changed outside a built .app") {
            let ids = DefaultPlayer.audioTypes.map { $0.identifier }
            assert(ids.contains("public.mp3") && ids.contains("com.apple.m4a-audio") && ids.contains("public.mpeg-4-audio"), "\(ids)")
            assert(DefaultPlayer.audioTypes.count == 9, "all declared types resolve: \(ids)")
            assert(DefaultPlayer.appBundleURL == nil, "the test binary is not an .app bundle")
            assert(!DefaultPlayer.isDefault)
            var failed: [UTType]?
            DefaultPlayer.makeDefault { failed = $0 } // must refuse synchronously, touching no system setting
            assert(failed?.count == DefaultPlayer.audioTypes.count)
            let status = StatusBarController()
            assert(status.currentMenu.items.contains { $0.title == "Set \(AppConfig.appName) as Default Player" && $0.target != nil },
                   "status bar menu offers it too")
        }

        testRunner("H1: a skin's extra bitmaps are never inflated or decoded (memory bomb); used sprites still load") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("h1-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let ctx = CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 800,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            let wsz = try Data(contentsOf: URL(fileURLWithPath: "Resources/base-2.91.wsz"))
            let base = try ZipArchive.extract(data: wsz)
            try base["main.bmp"]!.write(to: dir.appendingPathComponent("MAIN.BMP"))
            try base["text.bmp"]!.write(to: dir.appendingPathComponent("TEXT.BMP"))
            for i in 0..<20 { try png.write(to: dir.appendingPathComponent("JUNK\(i).BMP")) }
            try png.write(to: dir.appendingPathComponent("MAIN.PNG"))
            let skin = try SkinEngine.buildSkin(at: dir)
            assert(Set(skin.images.keys) == ["main.bmp", "text.bmp"], "decoded: \(skin.images.keys.sorted())")
            // Archive path: the filter is applied before inflating.
            let filtered = try ZipArchive.extract(data: wsz, wanted: SkinEngine.isSkinFile)
            assert(!filtered.isEmpty && filtered.keys.allSatisfy(SkinEngine.isSkinFile), "\(filtered.keys.sorted())")
            assert(filtered.count < base.count, "the bundled skin carries files the player never reads")
            assert(filtered["main.bmp"] == base["main.bmp"], "filtered entries are byte-identical")
        }

        testRunner("H2: absurd sample rates/durations from file headers never trap the bitrate math") {
            assert(Track.bitrateKbps(fileSize: 1_000_000, duration: 1e-300) == nil, "Int(8e303) would trap")
            assert(Track.bitrateKbps(fileSize: 1_000_000, duration: .infinity) == nil)
            assert(Track.bitrateKbps(fileSize: 1_000_000, duration: .nan) == nil)
            assert(Track.bitrateKbps(fileSize: 0, duration: 10) == nil)
            assert(Track.bitrateKbps(fileSize: 4_000_000, duration: 250) == 128)
        }

        testRunner("H3: a flat EQ is bypassed, any non-zero band or preamp engages it") {
            assert(AudioEngine.eqIsFlat(preamp: 0, bands: Array(repeating: 0, count: 10)))
            assert(!AudioEngine.eqIsFlat(preamp: 0.5, bands: Array(repeating: 0, count: 10)))
            var b = Array(repeating: Float(0), count: 10); b[9] = -3
            assert(!AudioEngine.eqIsFlat(preamp: 0, bands: b))
        }

        testRunner("H4: CUE import opens the audio once and still ends the last track at the file's real length") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("h4-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            do {
                let f = try AVAudioFile(forWriting: dir.appendingPathComponent("album.wav"), settings: fmt.settings)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100 * 3)!
                buf.frameLength = 44_100 * 3
                try f.write(from: buf)
            }
            try """
            FILE "album.wav" WAVE
              TRACK 01 AUDIO
                TITLE "One"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Two"
                INDEX 01 00:01:00
            """.write(to: dir.appendingPathComponent("album.cue"), atomically: true, encoding: .utf8)
            let tracks = LibraryImporter.tracksFromCue(dir.appendingPathComponent("album.cue"))
            assert(tracks.count == 2)
            assert(abs(tracks[0].duration - 1) < 0.001 && abs(tracks[1].duration - 2) < 0.001, "\(tracks.map { $0.duration })")
            assert(abs((tracks[1].cueEndTime ?? 0) - 3) < 0.001, "last track ends at the file length")
            assert(tracks[1].isGaplessSuccessor(of: tracks[0]))
            assert(tracks[0].bitrate != nil && !tracks[0].missing)
        }

        testRunner("H5: restored playlists are checked for missing files off the main thread") {
            let pm = PlaylistManager()
            let gone = Track(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mp3"), title: "gone")
            let here = Track(url: URL(fileURLWithPath: "Resources/base-2.91.wsz"), title: "here", missing: true)
            pm.setTracks([gone, here], validate: false)
            assert(!pm.tracks[0].missing, "no synchronous stat with validate: false")
            var done = false
            pm.validateMissingStatusAsync { done = true }
            let deadline = Date().addingTimeInterval(5)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            assert(done && pm.tracks[0].missing && !pm.tracks[1].missing, "\(pm.tracks.map { $0.missing })")
        }
    }
}

enum TestError: Error {
    case failed(String)
}

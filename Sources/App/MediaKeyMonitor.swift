import AppKit
import Darwin

/// Keyboard media keys (play/pause, next, previous, fast-forward, rewind).
///
/// Normally macOS's remote-control daemon (`rcd`) receives these keys and forwards them to the
/// "now playing" app, which `AudioEngine` handles through `MPRemoteCommandCenter`. Many people
/// disable `rcd` (it makes the play key launch Apple Music), and then the keys reach no app at
/// all. While `rcd` is not running, this monitor reads the raw media-key events itself.
/// While it *is* running the events are ignored here, so a key is never handled twice.
public final class MediaKeyMonitor {
    public static let shared = MediaKeyMonitor()

    private var monitors: [Any] = []
    private var rcdCheckedAt: CFAbsoluteTime = 0
    private var rcdRunningCached = false

    private init() {}

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    enum Key: Int {
        case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
    }

    public func start() {
        guard monitors.isEmpty else { return }
        // Global: keys pressed while another app is in front. Local: while this player is in front.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { [weak self] e in
            self?.handle(e)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { [weak self] e in
            (self?.handle(e) ?? false) ? nil : e
        }) { monitors.append(l) }
    }

    /// Decodes an `NSEvent.systemDefined` media-key event: (key, isDown, isRepeat).
    static func decode(subtype: Int16, data1: Int) -> (key: Key, down: Bool, isRepeat: Bool)? {
        guard subtype == 8 else { return nil } // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        guard let key = Key(rawValue: code) else { return nil }
        return (key, (flags & 0xFF00) >> 8 == 0x0A, flags & 0x1 != 0)
    }

    /// Returns true when the event was a media key this monitor acted on.
    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard let k = MediaKeyMonitor.decode(subtype: event.subtype.rawValue, data1: event.data1), k.down else { return false }
        guard !rcdIsRunning() else { return false } // rcd forwards it to MPRemoteCommandCenter instead
        let engine = AudioEngine.shared
        let player = PlayerController.shared
        switch k.key {
        case .play:
            guard !k.isRepeat else { return true }
            // Media keys never open the file dialog: with nothing to play they do nothing.
            if engine.currentTrack == nil && player.playlist.count == 0 { return true }
            engine.togglePlayPause()
        case .next:
            guard !k.isRepeat else { return true }
            player.playNext()
        case .previous:
            guard !k.isRepeat else { return true }
            player.playPrevious()
        case .fast:
            engine.seek(by: 5)
        case .rewind:
            engine.seek(by: -5)
        }
        return true
    }

    /// Whether macOS's remote-control daemon is alive (checked at most every 2 s).
    private func rcdIsRunning() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - rcdCheckedAt < 2 { return rcdRunningCached }
        rcdCheckedAt = now
        rcdRunningCached = MediaKeyMonitor.processIsRunning(named: "rcd")
        return rcdRunningCached
    }

    static func processIsRunning(named name: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        size += size / 8 // processes may appear between the two calls
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        let n = size / MemoryLayout<kinfo_proc>.stride
        for i in 0..<n {
            var comm = procs[i].kp_proc.p_comm
            let len = MemoryLayout.size(ofValue: comm)
            let pname = withUnsafePointer(to: &comm) { $0.withMemoryRebound(to: CChar.self, capacity: len) { String(cString: $0) } }
            if pname == name { return true }
        }
        return false
    }
}

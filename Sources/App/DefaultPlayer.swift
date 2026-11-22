import AppKit
import UniformTypeIdentifiers

/// "Set as Default Player": makes this app the Finder default for common audio file types.
/// The types must also be declared in Info.plist (CFBundleDocumentTypes, see scripts/build.sh),
/// otherwise LaunchServices refuses the association.
public enum DefaultPlayer {
    /// Audio types Finder should open here. `public.audio` itself is not set: it is an abstract
    /// parent type, and files are matched by their concrete type.
    static let audioTypes: [UTType] = [
        "public.mp3", "public.mpeg-4-audio", "com.apple.m4a-audio", "public.aac-audio", "org.xiph.flac",
        "com.microsoft.waveform-audio", "public.aiff-audio", "public.aifc-audio", "com.apple.coreaudio-format"
    ].compactMap { UTType($0) }

    /// The running app's bundle, or nil when not launched from a built .app (e.g. the test binary).
    static var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? url : nil
    }

    /// True when every audio type already opens in this app (matched by bundle id, so another
    /// copy of the same app counts too).
    public static var isDefault: Bool {
        guard let id = Bundle.main.bundleIdentifier, appBundleURL != nil else { return false }
        return audioTypes.allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Bundle(url: $0)?.bundleIdentifier } == id
        }
    }

    /// Registers this app as the default for every audio type, one at a time (macOS may ask the
    /// user to confirm), then reports the outcome. `completion` runs on the main thread with
    /// the types that could not be changed.
    public static func makeDefault(completion: (([UTType]) -> Void)? = nil) {
        guard let app = appBundleURL else {
            completion?(audioTypes)
            return
        }
        var failed: [UTType] = []
        func next(_ i: Int) {
            guard i < audioTypes.count else {
                completion?(failed)
                return
            }
            let type = audioTypes[i]
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        NSLog("Default player: %@ not changed: %@", type.identifier, error.localizedDescription)
                        failed.append(type)
                    }
                    next(i + 1)
                }
            }
        }
        next(0)
    }

    /// Menu action: set the defaults and tell the user how it went.
    public static func makeDefaultInteractively() {
        guard appBundleURL != nil else {
            showAlert("Cannot set the default player",
                      "\(AppConfig.appName) must be running from its .app bundle (build it with make build).")
            return
        }
        makeDefault { failed in
            if failed.isEmpty {
                Events.status("\(AppConfig.appName.uppercased()) IS NOW THE DEFAULT PLAYER")
                return
            }
            let names = failed.map { $0.preferredFilenameExtension.map { ".\($0)" } ?? $0.identifier }
            showAlert(failed.count == audioTypes.count ? "Could not set the default player" : "Some file types were not changed",
                      "Not changed: \(names.joined(separator: ", ")).\nYou can set them in Finder: Get Info ▸ Open with ▸ Change All…")
        }
    }

    private static func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

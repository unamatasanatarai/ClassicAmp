import Foundation

public enum AppConfig {
    public static var appName: String {
        return Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
    }

    public static var bundleIdentifier: String {
        return Bundle.main.bundleIdentifier ?? "com.classic.amp"
    }

    public static var version: String {
        guard let url = Bundle.main.url(forResource: "VERSION", withExtension: nil),
              let versionStr = try? String(contentsOf: url, encoding: .utf8) else {
            return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        }
        return versionStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var buildNumber: String {
        guard let url = Bundle.main.url(forResource: "BUILD_NUMBER", withExtension: nil),
              let buildStr = try? String(contentsOf: url, encoding: .utf8) else {
            return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        }
        return buildStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var appSupportDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(appName)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    /// The playlist lives in its own file so frequent state saves stay small.
    public static var playlistFileURL: URL {
        appSupportDirectory.appendingPathComponent("playlist.json")
    }

    public static var stateFileURL: URL {
        appSupportDirectory.appendingPathComponent("state.json")
    }

    public static var bundledSkinURL: URL? {
        if let url = Bundle.main.url(forResource: "base-2.91", withExtension: "wsz") {
            return url
        }
        let fallback = URL(fileURLWithPath: "Resources/base-2.91.wsz")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }
}

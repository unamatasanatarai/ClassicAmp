import AppKit

@main
struct AppMain {
    static func main() {
        SkinEngine.preloadBaseSkin()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

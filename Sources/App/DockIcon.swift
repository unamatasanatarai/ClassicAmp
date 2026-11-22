import AppKit

/// Show or hide the app's Dock icon (remembered across launches).
/// Hidden = "accessory" app: no Dock icon, no menu bar, not in ⌘-Tab; the player windows and
/// the menu-bar icon keep working.
public enum DockIcon {
    private static let key = "showDockIcon"

    public static var isVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Activation policy for launch.
    public static var launchPolicy: NSApplication.ActivationPolicy {
        isVisible ? .regular : .accessory
    }

    public static func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: key)
        guard NSApp.activationPolicy() != (visible ? .regular : .accessory) else { return }
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible {
            // AppKit only rebuilds the menu bar on (re)activation after leaving accessory mode.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.activate(ignoringOtherApps: true) }
        } else {
            // Leaving regular mode deactivates the app; keep the player in front.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

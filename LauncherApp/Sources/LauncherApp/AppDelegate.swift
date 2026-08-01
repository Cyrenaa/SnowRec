import AppKit

/// Application delegate for the menu-bar launcher.
///
/// Sets up the accessory activation policy and the status item on launch.
/// Later todos extend this class with task scheduling, menu items, and
/// notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong reference so the status item survives for the app's lifetime.
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory policy keeps the app out of the Dock and app switcher,
        // mirroring the rumps behavior in launcher.py.
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "❄️"
        // Empty menu for now; populated by later todos.
        item.menu = NSMenu()
        statusItem = item
    }
}

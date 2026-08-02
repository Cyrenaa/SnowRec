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

    /// Running/scheduled tasks. Empty until todos 18+ populate it; the menu
    /// only gains the 任务 section and ⏹ 停止全部 once active tasks exist.
    private var tasks: [Task] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory policy keeps the app out of the Dock and app switcher,
        // mirroring the rumps behavior in launcher.py.
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "❄️"
        statusItem = item

        // Prune logs older than 7 days before touching any state
        // (launcher.py _load_data calls _cleanup_old_logs first).
        LogCleanup.pruneOldLogs()

        // Recover state left over from a previous session: normalize history
        // statuses and kill orphan process groups (launcher.py 207-233 parity).
        // StateStore stays the single persistence entry point: load -> mutate
        // -> save.
        let store = StateStore()
        var state = store.load()
        OrphanRecovery.recover(in: &state)
        store.save(state)

        // Menu reflects the persisted history/presets at launch; the 任务
        // section appears once todos 18+ populate `tasks` (todo 17 replaces
        // this with a 5s rebuild).
        item.menu = MenuBuilder.buildMenu(tasks: tasks, state: state)
    }
}

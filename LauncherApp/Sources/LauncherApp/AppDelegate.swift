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
    /// Internal (not private) so the --menu-refresh-test QA flag can inject
    /// tasks without a GUI.
    var tasks: [Task] = []

    /// 5-second full-menu-rebuild timer (launcher.py:184-185 parity: created
    /// at init and started immediately). Held strongly so it is never
    /// deallocated; the target/selector style avoids the @Sendable closure
    /// isolation issue of the block-based API under Swift 6.
    private var refreshTimer: Timer?

    /// The menu most recently built by `rebuildMenu()`, kept regardless of
    /// whether a status item exists (QA flags read it without a GUI).
    private(set) var currentMenu: NSMenu?

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

        // Initial menu build, then the 5s full-rebuild timer starts
        // (launcher.py:184-185: timer created in __init__, started
        // immediately; each tick is a full rebuild).
        rebuildMenu()
        startRefreshTimer()
    }

    /// Starts the repeating 5-second refresh timer on the main run loop.
    /// The run loop must be running for it to fire: NSApp.run() keeps it
    /// alive in the real app, RunLoop.main.run(until:) in QA flags.
    func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 5, target: self, selector: #selector(refreshTick),
            userInfo: nil, repeats: true)
    }

    @objc private func refreshTick() {
        rebuildMenu()
    }

    /// Full menu rebuild (launcher.py:252-253 _tick -> _rebuild_menu).
    /// Reloads persisted state every tick so externally-written history/
    /// preset changes appear (launcher.py _tick reads _DATA which is mutated
    /// in place; Swift reloads from disk, equivalent observable), then
    /// replaces the menu object — the NSMenu equivalent of rumps
    /// clear+update (launcher.py:305-306).
    func rebuildMenu() {
        let state = StateStore().load()
        let menu = MenuBuilder.buildMenu(tasks: tasks, state: state)
        currentMenu = menu
        statusItem?.menu = menu
    }
}

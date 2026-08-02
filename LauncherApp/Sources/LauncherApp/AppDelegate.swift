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
        // Notification delegate installed early (idempotent) so foreground
        // banners can be presented by todo 23.
        Notifications.setup()

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
        // launcher.py:263-264: when no tasks are active, drop the finished/
        // stopped leftovers from the in-memory list.
        if tasks.filter({ MenuBuilder.activeStatuses.contains($0.status) }).isEmpty {
            tasks = []
        }
        // buildMenu() creates fresh DISABLED items every tick, so the action
        // items must be re-wired here — this is what survives the 5s rebuild.
        attachMenuActions(to: menu, state: state)
        currentMenu = menu
        statusItem?.menu = menu
    }

    /// Attaches target/action to the three new-task menu items (launcher.py:
    /// 266-268 callbacks), the ⭐ 收藏 submenu items (launcher.py:272-281),
    /// the 🕐 最近 submenu items (launcher.py:284-297) and the task items
    /// (launcher.py:261 callback). Called on EVERY rebuild because each
    /// rebuild builds a brand-new menu object — this is what survives the
    /// 5s refresh timer. Task/history/preset items are identified by their
    /// `representedObject` (attached by MenuBuilder), never by title.
    private func attachMenuActions(to menu: NSMenu, state: StateFile) {
        for item in menu.items {
            switch item.title {
            case "📝 下载字幕":
                item.target = self
                item.action = #selector(newSubtitleAction)
                item.isEnabled = true
            case "📻 录制广播":
                item.target = self
                item.action = #selector(newRadioAction)
                item.isEnabled = true
            case "📺 录制 TVer":
                item.target = self
                item.action = #selector(newTverAction)
                item.isEnabled = true
            case "⭐ 收藏":
                if let submenu = item.submenu {
                    attachPresetActions(to: submenu, state: state)
                }
            case "🕐 最近":
                if let submenu = item.submenu {
                    attachHistoryActions(to: submenu)
                }
            default:
                // Task item: the only menu item carrying a Task
                // representedObject (MenuBuilder attaches the LIVE task).
                if let task = item.representedObject as? Task {
                    item.target = self
                    item.action = #selector(taskInfoAction(_:))
                    item.isEnabled = true
                }
            }
        }
    }

    /// Wires the ⭐ 收藏 submenu: preset items → runPreset, ➕ 新建收藏... →
    /// savePreset, ✏️ 管理收藏... → managePresets (launcher.py:272-281
    /// callbacks). Preset items carry the Preset as `representedObject`,
    /// matched against the freshly-loaded state by name (launcher.py:411
    /// matches the menu title against _DATA at click time).
    private func attachPresetActions(to submenu: NSMenu, state: StateFile) {
        for item in submenu.items {
            switch item.title {
            case "  ➕ 新建收藏...":
                item.target = self
                item.action = #selector(savePresetAction)
                item.isEnabled = true
            case "  ✏️ 管理收藏...":
                item.target = self
                item.action = #selector(managePresetsAction)
                item.isEnabled = true
            default:
                // Preset item: MenuBuilder prefixes names with two spaces;
                // a preset renamed away simply stops matching (stays
                // disabled until the next rebuild).
                let name = item.title.trimmingCharacters(in: .whitespaces)
                guard let preset = state.presets.first(where: { $0.name == name }) else {
                    continue
                }
                item.representedObject = preset
                item.target = self
                item.action = #selector(runPresetAction(_:))
                item.isEnabled = true
            }
        }
    }

    /// Wires the 🕐 最近 submenu: history entries → rerunHistory (the entry
    /// comes from representedObject — its title carries a " [status]" tag
    /// that must NOT be parsed, launcher.py:458 strips it in Python),
    /// ❌ 清除全部 → clearHistory (launcher.py:292 callback).
    private func attachHistoryActions(to submenu: NSMenu) {
        for item in submenu.items {
            switch item.title {
            case "  ❌ 清除全部":
                item.target = self
                item.action = #selector(clearHistoryAction)
                item.isEnabled = true
            default:
                // History entry item: carries its HistoryEntry snapshot.
                // "(空)" carries none and stays disabled.
                guard let entry = item.representedObject as? HistoryEntry else {
                    continue
                }
                item.target = self
                item.action = #selector(rerunHistoryAction(_:))
                item.isEnabled = true
            }
        }
    }

    // MARK: - New-task actions (launcher.py:266-268)

    @objc private func newSubtitleAction() {
        DialogFlows.newSubtitle(delegate: self)
    }

    @objc private func newRadioAction() {
        DialogFlows.newRadio(delegate: self)
    }

    @objc private func newTverAction() {
        DialogFlows.newTver(delegate: self)
    }

    // MARK: - Preset actions (launcher.py:272-281)

    @objc private func savePresetAction() {
        PresetFlows.savePreset()
    }

    @objc private func managePresetsAction() {
        PresetFlows.managePresets()
    }

    @objc private func runPresetAction(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }
        PresetFlows.runPreset(delegate: self, preset: preset)
    }

    // MARK: - Task-info / history actions (launcher.py:261 / 284-297)

    @objc private func taskInfoAction(_ sender: NSMenuItem) {
        guard let task = sender.representedObject as? Task else { return }
        HistoryFlows.taskInfo(delegate: self, task: task)
    }

    @objc private func rerunHistoryAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        HistoryFlows.rerunHistory(delegate: self, entry: entry)
    }

    @objc private func clearHistoryAction() {
        HistoryFlows.clearHistory()
    }
}

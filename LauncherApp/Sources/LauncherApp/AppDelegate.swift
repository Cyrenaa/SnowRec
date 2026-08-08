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
    /// only gains the 任务 section and 停止全部 once active tasks exist.
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

    /// Retained target for the key-dialog 显示明文 toggle (target/action
    /// holds no strong reference). Cleared after the modal session.
    private var keyFieldToggler: AnyObject?

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
    /// 266-268 callbacks), the flat preset entries (launcher.py:272-281),
    /// the 最近 submenu items (launcher.py:284-297) and the task items
    /// (launcher.py:261 callback). Called on EVERY rebuild because each
    /// rebuild builds a brand-new menu object — this is what survives the
    /// 5s refresh timer. Task/history/preset items are identified by their
    /// `representedObject` (attached by MenuBuilder), never by title.
    private func attachMenuActions(to menu: NSMenu, state: StateFile) {
        for item in menu.items {
            switch item.title {
            case "下载字幕":
                item.target = self
                item.action = #selector(newSubtitleAction)
                item.isEnabled = true
            case "录制广播":
                item.target = self
                item.action = #selector(newRadioAction)
                item.isEnabled = true
            case "录制 TVer":
                item.target = self
                item.action = #selector(newTverAction)
                item.isEnabled = true
            case "新建收藏...":
                item.target = self
                item.action = #selector(savePresetAction)
                item.isEnabled = true
            case "最近":
                if let submenu = item.submenu {
                    attachHistoryActions(to: submenu)
                }
            case "设置 DeepSeek API Key...":
                item.target = self
                item.action = #selector(setDeepSeekKeyAction)
                item.isEnabled = true
            case "停止全部":
                // launcher.py:301 callback; only present when active tasks
                // exist (MenuBuilder is already conditional).
                item.target = self
                item.action = #selector(killAllAction)
                item.isEnabled = true
            case "重启":
                // launcher.py:303 callback = _restart_app.
                item.target = self
                item.action = #selector(restartAction)
                item.isEnabled = true
            case "退出":
                // launcher.py:303 callback = rumps.quit_application.
                item.target = self
                item.action = #selector(quitAction)
                item.isEnabled = true
            default:
                // Task item: the only menu item carrying a Task
                // representedObject (MenuBuilder attaches the LIVE task).
                if let task = item.representedObject as? Task {
                    item.target = self
                    item.action = #selector(taskInfoAction(_:))
                    item.isEnabled = true
                } else if let preset = state.presets.first(where: { $0.name == item.title }) {
                    // Flat preset row: matched by name against the freshly
                    // loaded state (launcher.py:411 parity); a preset renamed
                    // away simply stops matching (stays disabled until the
                    // next rebuild). Clicking the row runs the preset; its
                    // manage submenu (修改收藏/删除收藏) is attached below.
                    item.representedObject = preset
                    item.target = self
                    item.action = #selector(runPresetAction(_:))
                    item.isEnabled = true
                    if let submenu = item.submenu {
                        attachPresetManageActions(to: submenu, preset: preset)
                    }
                }
            }
        }
    }

    /// Wires a preset row's manage submenu: 修改 → edit flow, 删除 →
    /// confirm-and-remove. Both items carry the preset as representedObject.
    private func attachPresetManageActions(to submenu: NSMenu, preset: Preset) {
        for item in submenu.items {
            switch item.title {
            case "  修改":
                item.representedObject = preset
                item.target = self
                item.action = #selector(editPresetAction(_:))
                item.isEnabled = true
            case "  删除":
                item.representedObject = preset
                item.target = self
                item.action = #selector(deletePresetAction(_:))
                item.isEnabled = true
            default:
                break
            }
        }
    }

    /// Wires the 最近 submenu: history entries → rerunHistory (the entry
    /// comes from representedObject — its title carries a " [status]" tag
    /// that must NOT be parsed, launcher.py:458 strips it in Python),
    /// 清除全部 → clearHistory (launcher.py:292 callback).
    private func attachHistoryActions(to submenu: NSMenu) {
        for item in submenu.items {
            switch item.title {
            case "  清除全部":
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

    @objc private func editPresetAction(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }
        PresetFlows.editPreset(preset)
    }

    @objc private func deletePresetAction(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }
        PresetFlows.deletePreset(preset)
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

    // MARK: - DeepSeek API key action

    /// Shows the secure key entry dialog, then persists via KeyStore
    /// (HOME-scoped ~/.script_launcher_dev.key, 0600).
    @objc private func setDeepSeekKeyAction() {
        let alert = NSAlert()
        alert.messageText = "设置 DeepSeek API Key"
        alert.informativeText = "保存到 ~/.script_launcher_dev.key (0600 权限)。留空确认将清除已保存的 Key。"
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let initialKey = KeyStore.load() ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
        let secureField = NSSecureTextField(string: initialKey)
        secureField.placeholderString = "sk-..."
        // Secure fields hide the text and disable selection-copy; the
        // 显示明文 toggle swaps in a plain NSTextField (same frame) so the
        // key can be reviewed / selected / copied when needed.
        let plainField = NSTextField(string: initialKey)
        plainField.isHidden = true
        let fieldFrame = NSRect(x: 0, y: 0, width: 240, height: secureField.fittingSize.height)
        let fieldContainer = NSView(frame: fieldFrame)
        secureField.frame = fieldFrame
        plainField.frame = fieldFrame
        fieldContainer.addSubview(secureField)
        fieldContainer.addSubview(plainField)
        let showToggle = NSButton(checkboxWithTitle: "显示明文", target: nil, action: nil)
        let toggler = SecureFieldToggler(secure: secureField, plain: plainField)
        keyFieldToggler = toggler  // retained for the modal session
        showToggle.target = toggler
        showToggle.action = #selector(SecureFieldToggler.toggle(_:))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "API Key:"), fieldContainer],
            [NSTextField(labelWithString: ""), showToggle],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 240
        let fitting = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        alert.accessoryView = grid
        guard AlertPresenter.presentModal(alert) == .alertFirstButtonReturn else { return }
        keyFieldToggler = nil
        let finalKey = plainField.isHidden ? secureField.stringValue : plainField.stringValue
        KeyStore.save(finalKey)
    }

    // MARK: - Stop-all / quit actions (launcher.py:301-303)

    /// launcher.py:632-637 `_kill_all`: run the termination chain on every
    /// active task (运行中/等待启动), then drop the actually-stopped tasks
    /// from the list and rebuild the menu. Tasks whose stop was a no-op
    /// (handle-less, launcher.py:166) keep their status and stay — Python
    /// only removes tasks whose kill() really ran (已停止). Returns the
    /// stop results in iteration order for --killall-test QA.
    @discardableResult
    func killAll() async -> [Bool] {
        let active = tasks.filter { MenuBuilder.activeStatuses.contains($0.status) }
        var results: [Bool] = []
        var stoppedIDs = Set<ObjectIdentifier>()
        for task in active {
            let stopped = await TaskManager.stop(task, store: StateStore())
            results.append(stopped)
            if stopped { stoppedIDs.insert(ObjectIdentifier(task)) }
        }
        tasks = tasks.filter { !stoppedIDs.contains(ObjectIdentifier($0)) }
        rebuildMenu()
        return results
    }

    /// Menu-bar entry to `killAll()` (launcher.py:301 callback). The
    /// termination chain is async, so the click spawns a background task —
    /// same pattern as HistoryFlows.taskInfo's 停止 button.
    @objc private func killAllAction() {
        Swift.Task { @MainActor in
            _ = await killAll()
        }
    }

    /// 退出 = NSApp.terminate (launcher.py:304 rumps.quit_application).
    /// Child processes are NOT touched — they become orphans and are
    /// recovered on the next launch (OrphanRecovery, todo 10).
    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Restart action (launcher.py:310-320 _restart_app)

    /// launcher.py:310-320: confirm when active tasks exist (a relaunch
    /// would terminate them), then _save_data() parity and relaunch.
    @objc private func restartAction() {
        let active = tasks.filter { MenuBuilder.activeStatuses.contains($0.status) }
        if !active.isEmpty {
            let alert = NSAlert()
            alert.messageText = "重启"
            alert.informativeText = "有 \(active.count) 个任务正在运行，重启后将被终止，确定重启？"
            alert.addButton(withTitle: "确认")
            alert.addButton(withTitle: "取消")
            alert.buttons[1].keyEquivalent = "\u{1b}"
            guard AlertPresenter.presentModal(alert) == .alertFirstButtonReturn else { return }
        }
        // launcher.py:315 _save_data() parity: persist current state before
        // the relaunch.
        StateStore().save(StateStore().load())
        RestartSupport.performRestart()
    }
}

/// Swaps an NSSecureTextField with a plain NSTextField via the 显示明文
/// checkbox in the key dialog, so the stored key can be reviewed or
/// selected/copied when needed. Keeps both fields' values in sync.
private final class SecureFieldToggler: NSObject {
    private weak var secure: NSSecureTextField?
    private weak var plain: NSTextField?

    init(secure: NSSecureTextField, plain: NSTextField) {
        self.secure = secure
        self.plain = plain
    }

    @objc func toggle(_ sender: NSButton) {
        let showPlain = (sender.state == .on)
        if showPlain {
            plain?.stringValue = secure?.stringValue ?? ""
        } else {
            secure?.stringValue = plain?.stringValue ?? ""
        }
        plain?.isHidden = !showPlain
        secure?.isHidden = showPlain
    }
}

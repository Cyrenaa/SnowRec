import AppKit

/// Task-info, history-detail/rerun and clear-history flows, mirroring
/// launcher.py:457-490 (`_rerun_history` / `_clear_history`) and 592-629
/// (`_task_info`).
///
/// osascript → AppKit mapping (same as DialogFlows / PresetFlows):
/// `display dialog` → NSAlert; the info text (multiline) becomes
/// `informativeText`; buttons map 1:1 with `addButton(withTitle:)`.
///
/// Button/keyboard parity notes:
/// - launcher.py declares `default button "关闭"` AND `cancel button
///   "关闭"` (Return AND Escape both act as 关闭). NSAlert assigns only ONE
///   keyEquivalent per button, so the exact double-role cannot be
///   replicated on a single button. We give 关闭 the Escape keyEquivalent
///   (the cancel role — the critical one for "accidental keypress" safety);
///   Return triggers the FIRST button (停止), which matches the repo's
///   existing alert idiom (PresetFlows 确认/取消: first = default). Click
///   semantics are exact: `.alertFirstButtonReturn` = 停止/再次运行/确认.
/// - For `--history-test`, the post-confirm logic (rerunEntry /
///   stopTaskAndCleanup / clearHistoryData) is factored out of the alert
///   wrappers so QA can exercise the REAL pipeline without a modal.
@MainActor
enum HistoryFlows {

    // MARK: - 任务详情 (launcher.py:592-629)

    /// launcher.py:592-629 `_task_info`: show 任务/状态/已运行/日志/命令 in
    /// an alert titled 任务详情 with 停止/关闭; on 停止 AND an active
    /// status, run the termination chain, drop the stopped task and
    /// rebuild the menu (launcher.py:626-629). The task comes from the
    /// menu item's `representedObject` (the LIVE in-memory Task, so
    /// `terminationHandle` is present for active tasks).
    static func taskInfo(delegate: AppDelegate, task: Task) {
        let alert = NSAlert()
        alert.messageText = "任务详情"
        alert.alertStyle = .informational
        alert.informativeText = infoText(for: task)
        alert.addButton(withTitle: "停止")
        alert.addButton(withTitle: "关闭")
        // launcher.py: `cancel button "关闭"` — Escape closes without
        // stopping (a stray Escape must never kill a recording).
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard AlertPresenter.presentModal(alert) == .alertFirstButtonReturn else { return }
        // launcher.py:626: only stop when the task is still active.
        guard MenuBuilder.activeStatuses.contains(task.status) else { return }
        Swift.Task { @MainActor in
            await stopTaskAndCleanup(delegate: delegate, task: task)
        }
    }

    /// launcher.py:626-629: the post-停止 pipeline — termination chain,
    /// drop the stopped task from the list (launcher.py:628 filters out
    /// 已停止 tasks; only killed tasks ever carry that status, so removing
    /// exactly THIS task is the Swift analog), rebuild the menu. Returns
    /// whether a teardown actually ran (TaskManager.stop's own result).
    @discardableResult
    static func stopTaskAndCleanup(delegate: AppDelegate, task: Task) async -> Bool {
        let stopped = await TaskManager.stop(task, store: StateStore())
        delegate.tasks.removeAll { $0 === task }
        delegate.rebuildMenu()
        return stopped
    }

    /// launcher.py:602-613: the alert's info text. Elapsed uses
    /// LabelHelpers.elapsedLabel (X小时Y分Z秒), "-" when the task never
    /// started; log "-" when absent; cmd joined with single spaces.
    static func infoText(for task: Task) -> String {
        let elapsed: String
        if let started = task.startedAt {
            elapsed = LabelHelpers.elapsedLabel(
                seconds: Int(Date().timeIntervalSince(started)))
        } else {
            elapsed = "-"
        }
        return [
            "任务: \(task.name)",
            "状态: \(task.status)",
            "已运行: \(elapsed)",
            "日志: \(task.logPath ?? "-")",
            "",
            "命令: \(task.cmd.joined(separator: " "))",
        ].joined(separator: "\n")
    }

    // MARK: - 历史详情/重跑 (launcher.py:457-485)

    /// launcher.py:457-485 `_rerun_history`: show the ENTRY's label/status/
    /// log/cmd in an alert titled 历史详情 with 再次运行/关闭; on 再次运行
    /// rebuild the Task from the entry and spawn it (launcher.py:480-484).
    /// The entry comes from the menu item's `representedObject` (todo-20
    /// spec: never parse the display title — it carries a " [status]" tag).
    static func rerunHistory(delegate: AppDelegate, entry: HistoryEntry) {
        let alert = NSAlert()
        alert.messageText = "历史详情"
        alert.alertStyle = .informational
        alert.informativeText = historyInfoText(for: entry)
        alert.addButton(withTitle: "再次运行")
        alert.addButton(withTitle: "关闭")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard AlertPresenter.presentModal(alert) == .alertFirstButtonReturn else { return }
        rerunEntry(delegate: delegate, entry: entry)
    }

    /// launcher.py:480-484: `Task(h["label"], h["cmd"])` → append → start →
    /// _add_history. NOTE on order: launcher.py calls start() BEFORE
    /// _add_history because Python's dict identity persists; Swift's
    /// HistoryEntry is a struct snapshot, so the entry MUST be persisted
    /// and attached to `task.historyEntry` FIRST (todo-18 finding) — same
    /// order as PresetFlows.runPreset / DialogFlows.startFlow.
    /// The cmd is executed VERBATIM — old entries pointing at the deploy
    /// copy (/Users/wyn/Documents/script/...) run as-is; only the working
    /// directory / PATH are re-derived from the repo root.
    @discardableResult
    static func rerunEntry(delegate: AppDelegate, entry: HistoryEntry) -> Task {
        let task = Task(name: entry.label, cmd: entry.cmd)
        delegate.tasks.append(task)
        DialogFlows.addHistory(label: entry.label, cmd: entry.cmd, task: task)
        Swift.Task { @MainActor in
            _ = await TaskManager.start(task, store: StateStore())
        }
        return task
    }

    /// launcher.py:463-468: the alert's info text. Status falls back to
    /// 未知 when empty, log to "-" when absent, cmd joined with spaces.
    static func historyInfoText(for entry: HistoryEntry) -> String {
        return [
            "任务: \(entry.label)",
            "状态: \(entry.status.isEmpty ? "未知" : entry.status)",
            "日志: \(entry.log ?? "-")",
            "",
            "命令: \(entry.cmd.joined(separator: " "))",
        ].joined(separator: "\n")
    }

    // MARK: - 清除历史 (launcher.py:487-490)

    /// launcher.py:487-490 `_clear_history`: confirm first, then clear and
    /// save. The menu picks the change up on the next 5s tick (launcher.py
    /// does not rebuild here either).
    static func clearHistory() {
        let confirm = NSAlert()
        confirm.messageText = "清除历史"
        confirm.informativeText = "确认清除全部历史记录？"
        confirm.addButton(withTitle: "确认")
        confirm.addButton(withTitle: "取消")
        guard AlertPresenter.presentModal(confirm) == .alertFirstButtonReturn else { return }
        clearHistoryData()
    }

    /// launcher.py:489-490: `self.history.clear(); _save_data()`.
    static func clearHistoryData() {
        let store = StateStore()
        var state = store.load()
        state.history = []
        store.save(state)
    }
}

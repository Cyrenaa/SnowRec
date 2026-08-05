import AppKit

/// The three new-task dialog flows (launcher.py:493-589 parity) plus the
/// shared confirm-path pipeline reused by the `--flow-test` QA flag.
///
/// osascript → AppKit mapping (plan E4):
/// - `osa_form` `("select", ...)`   → NSPopUpButton inside the alert's accessory NSGridView
/// - `osa_form` `("text", ...)`     → NSTextField (same grid)
/// - `osa_form` `("checkbox", ...)` → NSButton checkbox (subtitle 历史字幕 / radio 转换为视频)
/// - `osa_confirm` → the alert's 确认/取消 buttons
///
/// Cancel semantics: osa_* return None on cancel and the flow returns with NO
/// side effects; empty (post-trim) fields also return without side effects
/// (launcher.py `if not x: return` — osascript strips the returned text).
@MainActor
enum DialogFlows {

    /// Flow types selectable by `--flow-test`.
    enum FlowKind: String {
        case subtitle
        case radio
        case tver
    }

    // MARK: - UI flows (launcher.py:493-589)

    /// launcher.py:534-561 `_new_subtitle`.
    static func newSubtitle(delegate: AppDelegate) {
        let content = makeTaskAlert(
            title: "下载字幕",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "19:00",
            secondLabel: "结束时间 (HH:MM):", secondDefault: "20:00",
            outputInitial: "sub_tbs",
            checkboxLabel: "历史字幕", checkboxDefault: false)
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let channel = content.popup.titleOfSelectedItem ?? ""
        let timeStart = trimmed(content.startField.stringValue)
        let timeEnd = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        guard !channel.isEmpty, !timeStart.isEmpty, !timeEnd.isEmpty, !output.isEmpty else {
            return  // empty input == cancel (launcher.py: `if not x: return`)
        }
        let history = content.checkbox?.state == .on
        startSubtitle(delegate: delegate, channel: channel,
                      timeStart: timeStart, timeEnd: timeEnd, output: output,
                      history: history)
    }

    /// launcher.py:564-589 `_new_radio`.
    static func newRadio(delegate: AppDelegate) {
        let content = makeTaskAlert(
            title: "录制广播",
            popupLabel: "电台:",
            options: CommandBuilder.radioStations,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "21:00",
            secondLabel: "录制时长 (分钟):", secondDefault: "30",
            outputInitial: "radio_tbs.m4a",
            checkboxLabel: "转换为视频", checkboxDefault: false)
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let station = content.popup.titleOfSelectedItem ?? ""
        let startAt = trimmed(content.startField.stringValue)
        let duration = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        guard !station.isEmpty, !startAt.isEmpty, !duration.isEmpty, !output.isEmpty else {
            return
        }

        let toVideo = content.checkbox?.state == .on

        startRadio(delegate: delegate, station: station,
                   startAt: startAt, duration: duration, output: output,
                   toVideo: toVideo)
    }

    /// Internal QA hook (`--alert-probe-test`): builds the REAL radio-flow
    /// alert — the exact same makeTaskAlert construction as newRadio — but
    /// WITHOUT running the modal, so the probe can verify on-screen
    /// presentation of a LauncherApp-owned window on the window server.
    static func radioAlert() -> TaskAlertContent {
        makeTaskAlert(
            title: "录制广播",
            popupLabel: "电台:",
            options: CommandBuilder.radioStations,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "21:00",
            secondLabel: "录制时长 (分钟):", secondDefault: "30",
            outputInitial: "radio_tbs.m4a",
            checkboxLabel: "转换为视频", checkboxDefault: false)
    }

    /// launcher.py:493-520 `_new_recording`.
    static func newTver(delegate: AppDelegate) {
        let content = makeTaskAlert(
            title: "预约 TVer 录制",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "21:00",
            secondLabel: "结束时间 (HH:MM):", secondDefault: "22:00",
            outputInitial: "tbs.mp4")
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let channel = content.popup.titleOfSelectedItem ?? ""
        let startAt = trimmed(content.startField.stringValue)
        let endTime = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        guard !channel.isEmpty, !startAt.isEmpty, !endTime.isEmpty, !output.isEmpty,
              CommandBuilder.channels[channel] != nil else {
            return  // empty/unknown input == cancel (launcher.py:648 page_url check)
        }
        startTver(delegate: delegate, channel: channel,
                  startAt: startAt, endTime: endTime, output: output)
    }

    // MARK: - Post-confirm pipeline (shared with --flow-test)

    /// launcher.py:551-561 confirm path: build command → create task → add
    /// history → start (non-blocking).
    @discardableResult
    static func startSubtitle(
        delegate: AppDelegate, channel: String,
        timeStart: String, timeEnd: String, output: String,
        history: Bool = false
    ) -> Task {
        let cmd = CommandBuilder.subtitleCommand(
            repoRoot: RepoRoot.resolveRepoRoot() ?? "",
            channel: channel, timeStart: timeStart, timeEnd: timeEnd, output: output,
            history: history)
        let name = "字幕 \(channel) \(timeStart)-\(timeEnd)"
        return startFlow(delegate: delegate, name: name, historyLabel: name, cmd: cmd)
    }

    /// launcher.py:579-589 confirm path.
    @discardableResult
    static func startRadio(
        delegate: AppDelegate, station: String,
        startAt: String, duration: String, output: String,
        toVideo: Bool = false
    ) -> Task {
        let cmd = CommandBuilder.radioCommand(
            repoRoot: RepoRoot.resolveRepoRoot() ?? "",
            station: station, startAt: startAt, duration: duration, output: output,
            toVideo: toVideo)
        let end = LabelHelpers.endTimeLabel(startAt: startAt, durationMin: duration)
        return startFlow(
            delegate: delegate,
            name: "广播 \(station) \(startAt)-\(end)",
            historyLabel: "广播 \(station) \(startAt)", cmd: cmd)
    }

    /// launcher.py:510-520 confirm path. The duration is DERIVED from the
    /// start/end times (launcher.py:646 `_duration_min`) — an invalid or
    /// non-positive result cancels the flow (launcher.py:650-651). Returns
    /// nil in that case so callers (the alert flow and --flow-test) can stop.
    @discardableResult
    static func startTver(
        delegate: AppDelegate, channel: String,
        startAt: String, endTime: String, output: String
    ) -> Task? {
        guard let duration = LabelHelpers.durationMin(startAt: startAt, endTime: endTime),
              duration > 0 else {
            return nil
        }
        guard AlertPresenter.confirmLongDuration(minutes: duration) else { return nil }
        let cmd = CommandBuilder.tverCommand(
            repoRoot: RepoRoot.resolveRepoRoot() ?? "",
            channel: channel, startAt: startAt, duration: String(duration), output: output)
        let name = "TVer \(channel) \(startAt)-\(endTime)"  // ENTERED endTime (launcher.py:660)
        return startFlow(
            delegate: delegate,
            name: name,
            historyLabel: "TVer \(channel) \(startAt)", cmd: cmd)
    }

    // MARK: - Shared pieces

    /// launcher.py:243-249 `_add_history`: insert `{label, cmd, status:"运行"}`
    /// at index 0, cap 20, persist via StateStore; attach the snapshot to the
    /// task so TaskManager.start can write pid/log/status back through
    /// StateStore (HistoryEntry is a struct copy — todo 12 finding).
    static func addHistory(label: String, cmd: [String], task: Task) {
        let store = StateStore()
        var state = store.load()
        let entry = HistoryEntry(label: label, cmd: cmd, status: "运行")
        task.historyEntry = entry
        state.history.insert(entry, at: 0)
        if state.history.count > 20 {
            state.history = Array(state.history.prefix(20))
        }
        store.save(state)
    }

    /// Reloads the persisted history entry matching the task (label+cmd
    /// equality — the struct analog of Python's shared-dict identity).
    static func currentEntry(_ task: Task, store: StateStore) -> HistoryEntry? {
        guard let ref = task.historyEntry else { return nil }
        let state = store.load()
        return state.history.first {
            $0.label == ref.label && $0.cmd == ref.cmd
        }
    }

    /// launcher.py:518-520 / 558-561 / 586-589: tasks.append → task.start →
    /// _add_history. In Swift the entry MUST be persisted BEFORE start so the
    /// spawn closure can write pid/log back. TaskManager.start is @MainActor
    /// and BLOCKS until the child exits (todo 13) — the GUI must never block
    /// on process exit, so the start runs on a detached Swift.Task. Bare
    /// `Task { }` would resolve to the LOCAL Task class (todo 12 shadowing),
    /// so `Swift.Task` is mandatory.
    @discardableResult
    private static func startFlow(
        delegate: AppDelegate, name: String, historyLabel: String, cmd: [String]
    ) -> Task {
        let task = Task(name: name, cmd: cmd)
        delegate.tasks.append(task)
        addHistory(label: historyLabel, cmd: cmd, task: task)
        Swift.Task { @MainActor in
            _ = await TaskManager.start(task, store: StateStore())
        }
        return task
    }

    // MARK: - Alert construction

    /// Builds one flow's NSAlert: messageText = flow title, accessory view =
    /// NSGridView stacking [popup, 开始时间, second field, 输出文件名], plus
    /// an optional checkbox row (radio 转换为视频). The output default is a
    /// STATIC per-flow string (launcher.py: the osa_form output field ships a
    /// fixed `f"sub_{...}"`-style default, no longer derived from the chosen
    /// channel/station).
    private static func makeTaskAlert(
        title: String,
        popupLabel: String,
        options: [String],
        defaultOption: String,
        startLabel: String, startDefault: String,
        secondLabel: String, secondDefault: String,
        outputInitial: String,
        checkboxLabel: String? = nil, checkboxDefault: Bool = false
    ) -> TaskAlertContent {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        let defaultIndex = popup.indexOfItem(withTitle: defaultOption)
        if defaultIndex >= 0 {
            popup.selectItem(at: defaultIndex)
        }

        let startField = NSTextField(string: startDefault)
        let secondField = NSTextField(string: secondDefault)
        let outputField = NSTextField(string: outputInitial)

        var rows: [[NSView]] = [
            [label(popupLabel), popup],
            [label(startLabel), startField],
            [label(secondLabel), secondField],
            [label("输出文件名:"), outputField],
        ]
        var checkbox: NSButton?
        if let checkboxLabel {
            let box = NSButton(checkboxWithTitle: checkboxLabel, target: nil, action: nil)
            box.state = checkboxDefault ? .on : .off
            checkbox = box
            rows.append([label(""), box])
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 200
        // NSAlert sizes its window from the accessory's FRAME (frame-based,
        // pre-autolayout contract) — an autolayout-only accessory can leave
        // the window at message+buttons size while the grid overflows it
        // (observed on a real screen: grid 326pt in a 234pt window = clipped
        // fields). Pin the frame to the grid's fitting size so the alert
        // window always fits the fields.
        let fitting = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        alert.accessoryView = grid

        return TaskAlertContent(
            alert: alert, popup: popup,
            startField: startField, secondField: secondField,
            outputField: outputField, checkbox: checkbox)
    }

    /// Grid cell label: right-aligned, non-editable.
    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Holds a flow alert's controls. `checkbox` is nil only for the tver
    /// flow (no checkbox row); the radio flow reads `checkbox?.state == .on`
    /// for 转换为视频, the subtitle flow for 历史字幕.
    final class TaskAlertContent {
        let alert: NSAlert
        let popup: NSPopUpButton
        let startField: NSTextField
        let secondField: NSTextField
        let outputField: NSTextField
        let checkbox: NSButton?

        init(
            alert: NSAlert, popup: NSPopUpButton,
            startField: NSTextField, secondField: NSTextField,
            outputField: NSTextField, checkbox: NSButton?
        ) {
            self.alert = alert
            self.popup = popup
            self.startField = startField
            self.secondField = secondField
            self.outputField = outputField
            self.checkbox = checkbox
        }
    }
}

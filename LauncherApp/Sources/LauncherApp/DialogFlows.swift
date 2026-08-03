import AppKit

/// The three new-task dialog flows (launcher.py:493-589 parity) plus the
/// shared confirm-path pipeline reused by the `--flow-test` QA flag.
///
/// osascript → AppKit mapping (plan E4):
/// - `osa_choose`  → NSPopUpButton inside the alert's accessory NSGridView
/// - `osa_dialog`  → NSTextField (same grid)
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
            outputFormat: { "sub_\($0.lowercased())" })
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let channel = content.popup.titleOfSelectedItem ?? ""
        let timeStart = trimmed(content.startField.stringValue)
        let timeEnd = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        guard !channel.isEmpty, !timeStart.isEmpty, !timeEnd.isEmpty, !output.isEmpty else {
            return  // empty input == cancel (launcher.py: `if not x: return`)
        }
        startSubtitle(delegate: delegate, channel: channel,
                      timeStart: timeStart, timeEnd: timeEnd, output: output)
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
            outputFormat: { "radio_\($0.lowercased()).m4a" })
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let station = content.popup.titleOfSelectedItem ?? ""
        let startAt = trimmed(content.startField.stringValue)
        let duration = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        guard !station.isEmpty, !startAt.isEmpty, !duration.isEmpty, !output.isEmpty else {
            return
        }

        // launcher.py: `to_video = osa_confirm("转换为视频", ...)` — second
        // 确认/取消 alert after the field dialog confirms.
        let toVideoAlert = NSAlert()
        toVideoAlert.messageText = "转换为视频"
        toVideoAlert.informativeText = "录制完成后是否转换为视频 (需同名图片)？"
        toVideoAlert.alertStyle = .informational
        toVideoAlert.addButton(withTitle: "确认")
        toVideoAlert.addButton(withTitle: "取消")
        toVideoAlert.buttons[1].keyEquivalent = "\u{1b}"
        let toVideo = AlertPresenter.presentModal(toVideoAlert) == .alertFirstButtonReturn

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
            outputFormat: { "radio_\($0.lowercased()).m4a" })
    }

    /// launcher.py:493-520 `_new_recording`.
    static func newTver(delegate: AppDelegate) {
        let content = makeTaskAlert(
            title: "预约 TVer 录制",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "21:00",
            secondLabel: "录制时长 (分钟):", secondDefault: "60",
            outputFormat: { "\($0.lowercased()).mp4" })
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let channel = content.popup.titleOfSelectedItem ?? ""
        let startAt = trimmed(content.startField.stringValue)
        let duration = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        guard !channel.isEmpty, !startAt.isEmpty, !duration.isEmpty, !output.isEmpty else {
            return
        }
        startTver(delegate: delegate, channel: channel,
                  startAt: startAt, duration: duration, output: output)
    }

    // MARK: - Post-confirm pipeline (shared with --flow-test)

    /// launcher.py:551-561 confirm path: build command → create task → add
    /// history → start (non-blocking).
    @discardableResult
    static func startSubtitle(
        delegate: AppDelegate, channel: String,
        timeStart: String, timeEnd: String, output: String
    ) -> Task {
        let cmd = CommandBuilder.subtitleCommand(
            repoRoot: RepoRoot.resolveRepoRoot() ?? "",
            channel: channel, timeStart: timeStart, timeEnd: timeEnd, output: output)
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

    /// launcher.py:510-520 confirm path.
    @discardableResult
    static func startTver(
        delegate: AppDelegate, channel: String,
        startAt: String, duration: String, output: String
    ) -> Task {
        let cmd = CommandBuilder.tverCommand(
            repoRoot: RepoRoot.resolveRepoRoot() ?? "",
            channel: channel, startAt: startAt, duration: duration, output: output)
        let end = LabelHelpers.endTimeLabel(startAt: startAt, durationMin: duration)
        return startFlow(
            delegate: delegate,
            name: "TVer \(channel) \(startAt)-\(end)",
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
    /// NSGridView stacking [popup, 开始时间, second field, 输出文件名]. The
    /// output field's default follows the popup selection (launcher.py derives
    /// the output default from the chosen channel/station) but only while the
    /// user hasn't typed their own value.
    private static func makeTaskAlert(
        title: String,
        popupLabel: String,
        options: [String],
        defaultOption: String,
        startLabel: String, startDefault: String,
        secondLabel: String, secondDefault: String,
        outputFormat: @escaping (String) -> String
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
        let outputField = NSTextField(string: outputFormat(defaultOption))

        let grid = NSGridView(views: [
            [label(popupLabel), popup],
            [label(startLabel), startField],
            [label(secondLabel), secondField],
            [label("输出文件名:"), outputField],
        ])
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

        let binder = PopupOutputBinder(
            format: outputFormat, popup: popup, outputField: outputField)
        return TaskAlertContent(
            alert: alert, popup: popup,
            startField: startField, secondField: secondField,
            outputField: outputField, binder: binder)
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

    /// Holds a flow alert's controls. `binder` is retained here for the whole
    /// modal session so the popup action keeps firing — target/action holds no
    /// strong reference to its target.
    final class TaskAlertContent {
        let alert: NSAlert
        let popup: NSPopUpButton
        let startField: NSTextField
        let secondField: NSTextField
        let outputField: NSTextField
        let binder: PopupOutputBinder

        init(
            alert: NSAlert, popup: NSPopUpButton,
            startField: NSTextField, secondField: NSTextField,
            outputField: NSTextField, binder: PopupOutputBinder
        ) {
            self.alert = alert
            self.popup = popup
            self.startField = startField
            self.secondField = secondField
            self.outputField = outputField
            self.binder = binder
        }
    }

    /// Bridges the NSPopUpButton action to the output-field default
    /// (launcher.py: the output default is `f"sub_{ch.lower()}"`-style of the
    /// SELECTED channel/station, picked in an earlier osascript step).
    final class PopupOutputBinder: NSObject {
        private let format: (String) -> String
        private weak var outputField: NSTextField?
        private var lastAuto: String

        init(
            format: @escaping (String) -> String,
            popup: NSPopUpButton, outputField: NSTextField
        ) {
            self.format = format
            self.outputField = outputField
            self.lastAuto = format(popup.titleOfSelectedItem ?? "")
            super.init()
            popup.target = self
            popup.action = #selector(popupChanged(_:))
        }

        // @objc methods are nonisolated by default; MainActor is declared
        // explicitly so the AppKit control access below compiles cleanly.
        @MainActor @objc private func popupChanged(_ sender: NSPopUpButton) {
            let next = format(sender.titleOfSelectedItem ?? "")
            guard let field = outputField else { return }
            // Refresh the auto-default only while the user hasn't typed their
            // own value (launcher.py computes the default per dialog, so a
            // user-edited value survives a channel change).
            if field.stringValue.isEmpty || field.stringValue == lastAuto {
                field.stringValue = next
            }
            lastAuto = next
        }
    }
}

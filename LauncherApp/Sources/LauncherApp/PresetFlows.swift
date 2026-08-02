import AppKit

/// Preset (收藏) management flows, mirroring launcher.py:309-454:
/// `savePreset` (新建收藏: type chooser + per-type field alerts),
/// `managePresets` (管理收藏: rename/delete with confirmation), and
/// `runPreset` (运行收藏: command build → Task → history → spawn).
///
/// Same osascript → AppKit mapping as DialogFlows (todo 18):
/// - `osa_choose`  → NSPopUpButton inside the alert's accessory NSGridView
/// - `osa_dialog`  → NSTextField (same grid)
/// - `osa_confirm` → the alert's 确认/取消 buttons
///
/// Cancel semantics: every osa_* None → return with NO side effects; empty
/// (post-trim) fields also return without side effects (launcher.py
/// `if not x: return`).
@MainActor
enum PresetFlows {

    // MARK: - 新建收藏 (launcher.py:309-380)

    /// launcher.py:309-312: type chooser (选择类型: 下载字幕/录制广播/
    /// 录制 TVer), then the type-specific field alert. Persists via
    /// StateStore (launcher.py:380 `_save_data()`).
    static func savePreset() {
        let alert = NSAlert()
        alert.messageText = "新建收藏"
        alert.informativeText = "选择类型:"

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["下载字幕", "录制广播", "录制 TVer"])
        popup.selectItem(at: 0)
        let grid = NSGridView(views: [[label("类型:"), popup]])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 200
        alert.accessoryView = grid

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let type = popup.titleOfSelectedItem else { return }

        switch type {
        case "下载字幕": saveSubtitlePreset()
        case "录制广播": saveRadioPreset()
        default: saveTverPreset()
        }
    }

    /// launcher.py:314-334: channel + 开始/结束时间 + output + name.
    /// Preset JSON keys are snake_case via Preset's CodingKeys.
    private static func saveSubtitlePreset() {
        let content = makePresetAlert(
            title: "新建收藏 — 字幕",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "19:00",
            secondLabel: "结束时间 (HH:MM):", secondDefault: "20:00",
            outputFormat: { "sub_\($0.lowercased())" },
            nameFormat: { ch, ts in "字幕 \(ch) \(ts)" })
        guard content.alert.runModal() == .alertFirstButtonReturn else { return }

        let channel = content.popup.titleOfSelectedItem ?? ""
        let timeStart = trimmed(content.startField.stringValue)
        let timeEnd = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        let name = trimmed(content.nameField.stringValue)
        guard !channel.isEmpty, !timeStart.isEmpty, !timeEnd.isEmpty,
              !output.isEmpty, !name.isEmpty else { return }
        appendPreset(Preset(
            name: name, action: .subtitle,
            channel: channel, station: nil,
            timeStart: timeStart, timeEnd: timeEnd,
            startAt: nil, duration: nil, output: output))
    }

    /// launcher.py:336-356: station + 开始时间 + 时长 + output + name.
    private static func saveRadioPreset() {
        let content = makePresetAlert(
            title: "新建收藏 — 广播",
            popupLabel: "电台:",
            options: CommandBuilder.radioStations,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "21:00",
            secondLabel: "录制时长 (分钟):", secondDefault: "30",
            outputFormat: { "radio_\($0.lowercased()).m4a" },
            nameFormat: { st, sa in "广播 \(st) \(sa)" })
        guard content.alert.runModal() == .alertFirstButtonReturn else { return }

        let station = content.popup.titleOfSelectedItem ?? ""
        let startAt = trimmed(content.startField.stringValue)
        let duration = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        let name = trimmed(content.nameField.stringValue)
        guard !station.isEmpty, !startAt.isEmpty, !duration.isEmpty,
              !output.isEmpty, !name.isEmpty else { return }
        appendPreset(Preset(
            name: name, action: .radio,
            channel: nil, station: station,
            timeStart: nil, timeEnd: nil,
            startAt: startAt, duration: duration, output: output))
    }

    /// launcher.py:358-378: channel + 开始时间 + 时长 + output + name.
    private static func saveTverPreset() {
        let content = makePresetAlert(
            title: "新建收藏 — TVer",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            defaultOption: "TBS",
            startLabel: "开始时间 (HH:MM):", startDefault: "21:00",
            secondLabel: "录制时长 (分钟):", secondDefault: "60",
            outputFormat: { "\($0.lowercased()).mp4" },
            nameFormat: { ch, sa in "\(ch) \(sa)" })
        guard content.alert.runModal() == .alertFirstButtonReturn else { return }

        let channel = content.popup.titleOfSelectedItem ?? ""
        let startAt = trimmed(content.startField.stringValue)
        let duration = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        let name = trimmed(content.nameField.stringValue)
        guard !channel.isEmpty, !startAt.isEmpty, !duration.isEmpty,
              !output.isEmpty, !name.isEmpty else { return }
        appendPreset(Preset(
            name: name, action: .tver,
            channel: channel, station: nil,
            timeStart: nil, timeEnd: nil,
            startAt: startAt, duration: duration, output: output))
    }

    /// launcher.py:380 `_save_data()`: append + persist. Shared by the GUI
    /// flows and the `--preset-test` QA flag.
    static func appendPreset(_ preset: Preset) {
        let store = StateStore()
        var state = store.load()
        state.presets.append(preset)
        store.save(state)
    }

    // MARK: - 管理收藏 (launcher.py:382-408)

    /// launcher.py:382-408: empty guard → choose preset → choose action
    /// (重命名/删除) → apply + save. Any cancel returns with no side
    /// effects.
    static func managePresets() {
        let store = StateStore()
        let state = store.load()
        guard !state.presets.isEmpty else {
            // launcher.py:383-385 `osa_dialog("管理收藏", "暂无收藏", "")`.
            let alert = NSAlert()
            alert.messageText = "管理收藏"
            alert.informativeText = "暂无收藏"
            alert.runModal()
            return
        }

        // launcher.py:387-390: choose the preset to manage.
        let chooseAlert = NSAlert()
        chooseAlert.messageText = "管理收藏"
        chooseAlert.informativeText = "选择要管理的收藏:"
        let choosePopup = NSPopUpButton()
        choosePopup.addItems(withTitles: state.presets.map(\.name))
        choosePopup.selectItem(at: 0)
        let chooseGrid = NSGridView(views: [[label("收藏:"), choosePopup]])
        chooseGrid.rowSpacing = 8
        chooseGrid.columnSpacing = 12
        chooseGrid.column(at: 1).xPlacement = .fill
        chooseGrid.column(at: 1).width = 200
        chooseAlert.accessoryView = chooseGrid
        guard chooseAlert.runModal() == .alertFirstButtonReturn else { return }
        guard let chosen = choosePopup.titleOfSelectedItem else { return }

        // launcher.py:392-394: choose the action.
        let actionAlert = NSAlert()
        actionAlert.messageText = "管理收藏"
        actionAlert.informativeText = "对「\(chosen)」执行:"
        let actionPopup = NSPopUpButton()
        actionPopup.addItems(withTitles: ["重命名", "删除"])
        actionPopup.selectItem(at: 0)
        let actionGrid = NSGridView(views: [[label("操作:"), actionPopup]])
        actionGrid.rowSpacing = 8
        actionGrid.columnSpacing = 12
        actionGrid.column(at: 1).xPlacement = .fill
        actionGrid.column(at: 1).width = 200
        actionAlert.accessoryView = actionGrid
        guard actionAlert.runModal() == .alertFirstButtonReturn else { return }
        guard let action = actionPopup.titleOfSelectedItem else { return }

        if action == "重命名" {
            // launcher.py:396-404: name edit (default = current name) →
            // update in place + save. Empty input returns without saving.
            let renameAlert = NSAlert()
            renameAlert.messageText = "管理收藏"
            renameAlert.informativeText = "新的收藏名称:"
            let nameField = NSTextField(string: chosen)
            renameAlert.accessoryView = nameField
            guard renameAlert.runModal() == .alertFirstButtonReturn else { return }
            let newName = trimmed(nameField.stringValue)
            guard !newName.isEmpty else { return }
            var updated = store.load()
            for i in updated.presets.indices where updated.presets[i].name == chosen {
                updated.presets[i].name = newName
                break
            }
            store.save(updated)
        } else if action == "删除" {
            // launcher.py:405-408: confirm → remove ALL with that name + save.
            let confirm = NSAlert()
            confirm.messageText = "管理收藏"
            confirm.informativeText = "确认删除收藏「\(chosen)」？"
            confirm.addButton(withTitle: "确认")
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            var updated = store.load()
            updated.presets.removeAll { $0.name == chosen }
            store.save(updated)
        }
    }

    // MARK: - 运行收藏 (launcher.py:410-454)

    /// launcher.py:410-454 `_run_preset`: build the command per action
    /// (CommandBuilder parity, duration String passthrough), create
    /// Task(name=preset.name), append to the delegate's tasks, add history,
    /// spawn via a Swift.Task wrapper (TaskManager.start blocks until child
    /// exit, so the menu click must not block). The history label is the
    /// PRESET NAME — launcher.py:453 `_add_history(p["name"], ...)`. The
    /// computed label variables at launcher.py:427/437/448 are dead code in
    /// the preset path (real-world proof: the real state file's "🩷mtmr"
    /// history entry). New-task flows (DialogFlows) DO use computed labels
    /// (launcher.py:517/520, 558/561, 586/589) — unchanged here.
    @discardableResult
    static func runPreset(delegate: AppDelegate, preset: Preset) -> Task {
        let root = RepoRoot.resolveRepoRoot() ?? ""
        let cmd: [String]
        switch preset.action {
        case .subtitle:
            cmd = CommandBuilder.subtitleCommand(
                repoRoot: root, channel: preset.channel ?? "",
                timeStart: preset.timeStart ?? "", timeEnd: preset.timeEnd ?? "",
                output: preset.output ?? "")
        case .radio:
            cmd = CommandBuilder.radioCommand(
                repoRoot: root, station: preset.station ?? "",
                startAt: preset.startAt ?? "", duration: preset.duration ?? "",
                output: preset.output ?? "")
        case .tver:
            cmd = CommandBuilder.tverCommand(
                repoRoot: root, channel: preset.channel ?? "",
                startAt: preset.startAt ?? "", duration: preset.duration ?? "",
                output: preset.output ?? "")
        }
        let task = Task(name: preset.name, cmd: cmd)
        delegate.tasks.append(task)
        DialogFlows.addHistory(label: preset.name, cmd: cmd, task: task)
        Swift.Task { @MainActor in
            _ = await TaskManager.start(task, store: StateStore())
        }
        return task
    }

    // MARK: - Alert construction

    /// Builds one preset-save alert: messageText = flow title, accessory =
    /// NSGridView stacking [popup, 开始时间, second field, 输出文件名,
    /// 收藏名称]. The output default follows the popup selection and the
    /// name default follows popup + start time (launcher.py computes each
    /// default in a later sequential dialog), both only while the user
    /// hasn't typed their own value.
    private static func makePresetAlert(
        title: String,
        popupLabel: String,
        options: [String],
        defaultOption: String,
        startLabel: String, startDefault: String,
        secondLabel: String, secondDefault: String,
        outputFormat: @escaping (String) -> String,
        nameFormat: @escaping (String, String) -> String
    ) -> PresetAlertContent {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational

        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        let defaultIndex = popup.indexOfItem(withTitle: defaultOption)
        if defaultIndex >= 0 {
            popup.selectItem(at: defaultIndex)
        }

        let startField = NSTextField(string: startDefault)
        let secondField = NSTextField(string: secondDefault)
        let outputField = NSTextField(string: outputFormat(defaultOption))
        let nameField = NSTextField(string: nameFormat(defaultOption, startDefault))

        let grid = NSGridView(views: [
            [label(popupLabel), popup],
            [label(startLabel), startField],
            [label(secondLabel), secondField],
            [label("输出文件名:"), outputField],
            [label("收藏名称:"), nameField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 200
        alert.accessoryView = grid

        let binder = PresetSaveBinder(
            outputFormat: outputFormat, nameFormat: nameFormat,
            popup: popup, startField: startField,
            outputField: outputField, nameField: nameField)
        return PresetAlertContent(
            alert: alert, popup: popup,
            startField: startField, secondField: secondField,
            outputField: outputField, nameField: nameField, binder: binder)
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

    /// Holds a preset-save alert's controls. `binder` is retained for the
    /// whole modal session so the popup action / text-field delegate keep
    /// firing — target/action holds no strong reference to its target.
    final class PresetAlertContent {
        let alert: NSAlert
        let popup: NSPopUpButton
        let startField: NSTextField
        let secondField: NSTextField
        let outputField: NSTextField
        let nameField: NSTextField
        let binder: PresetSaveBinder

        init(
            alert: NSAlert, popup: NSPopUpButton,
            startField: NSTextField, secondField: NSTextField,
            outputField: NSTextField, nameField: NSTextField,
            binder: PresetSaveBinder
        ) {
            self.alert = alert
            self.popup = popup
            self.startField = startField
            self.secondField = secondField
            self.outputField = outputField
            self.nameField = nameField
            self.binder = binder
        }
    }

    /// Bridges popup selection + start-time edits to the output/name field
    /// defaults. launcher.py computes each later-dialog default from the
    /// values entered so far, so in the single-alert form the defaults must
    /// follow the controls live — but only while the user hasn't typed a
    /// custom value.
    final class PresetSaveBinder: NSObject, NSTextFieldDelegate {
        private let outputFormat: (String) -> String
        private let nameFormat: (String, String) -> String
        private weak var popup: NSPopUpButton?
        private weak var startField: NSTextField?
        private weak var outputField: NSTextField?
        private weak var nameField: NSTextField?
        private var lastAutoOutput: String
        private var lastAutoName: String

        init(
            outputFormat: @escaping (String) -> String,
            nameFormat: @escaping (String, String) -> String,
            popup: NSPopUpButton,
            startField: NSTextField,
            outputField: NSTextField,
            nameField: NSTextField
        ) {
            self.outputFormat = outputFormat
            self.nameFormat = nameFormat
            self.popup = popup
            self.startField = startField
            self.outputField = outputField
            self.nameField = nameField
            let selected = popup.titleOfSelectedItem ?? ""
            self.lastAutoOutput = outputFormat(selected)
            self.lastAutoName = nameFormat(selected, startField.stringValue)
            super.init()
            popup.target = self
            popup.action = #selector(popupChanged(_:))
            startField.delegate = self
        }

        // @objc methods are nonisolated by default; MainActor is declared
        // explicitly so the AppKit control access below compiles cleanly.
        @MainActor @objc private func popupChanged(_ sender: NSPopUpButton) {
            let selected = sender.titleOfSelectedItem ?? ""
            refresh(
                output: outputFormat(selected),
                name: nameFormat(selected, startField?.stringValue ?? ""))
        }

        @MainActor func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let start = startField,
                  field === start,
                  let selected = popup?.titleOfSelectedItem else { return }
            refresh(output: lastAutoOutput, name: nameFormat(selected, field.stringValue))
        }

        /// Refreshes the auto-defaults only while the user hasn't typed
        /// their own value (launcher.py computes the default per dialog, so
        /// a user-edited value survives later changes).
        @MainActor private func refresh(output: String, name: String) {
            if let field = outputField,
               field.stringValue.isEmpty || field.stringValue == lastAutoOutput {
                field.stringValue = output
            }
            lastAutoOutput = output
            if let field = nameField,
               field.stringValue.isEmpty || field.stringValue == lastAutoName {
                field.stringValue = name
            }
            lastAutoName = name
        }
    }
}

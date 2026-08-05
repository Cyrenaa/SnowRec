import AppKit

/// Preset (收藏) management flows, mirroring launcher.py:309-454:
/// `presetFlow` (新建收藏/修改收藏: type chooser + per-type field alerts with
/// dv() prefilled defaults), `managePresets` (管理收藏: modify/delete with
/// confirmation), and `runPreset` (运行收藏: command build → Task → history →
/// spawn).
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

    // MARK: - 新建收藏 / 修改收藏 (launcher.py:309-385)

    /// launcher.py:309 `_save_preset`: the ➕ 新建收藏... menu entry — a new
    /// preset flow (`target = nil`).
    static func savePreset() {
        presetFlow(target: nil)
    }

    /// launcher.py:309-385 `_preset_flow(target)`: title = 新建收藏 (nil) /
    /// 修改收藏 (non-nil); type chooser (下载字幕/录制广播/录制 TVer) defaults
    /// to the target's action when editing; then the type-specific field
    /// alert. Every field default comes from `dv(field:fallback:)` — the
    /// target's stored value when editing, the launcher.py fallback for a
    /// new preset. Persists via StateStore (launcher.py:384 `_save_data()`).
    static func presetFlow(target: Preset?) {
        let title = target == nil ? "新建收藏" : "修改收藏"

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "选择类型:"
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["下载字幕", "录制广播", "录制 TVer"])
        // launcher.py asks the type chooser with dv()-prefilled defaults; the
        // Swift analog defaults the chooser to the target's action when
        // editing (a new preset defaults to the first option, 下载字幕).
        let defaultType: String
        switch target?.action {
        case .subtitle: defaultType = "下载字幕"
        case .radio: defaultType = "录制广播"
        case .tver: defaultType = "录制 TVer"
        case .none: defaultType = "下载字幕"
        }
        let defaultIndex = popup.indexOfItem(withTitle: defaultType)
        if defaultIndex >= 0 {
            popup.selectItem(at: defaultIndex)
        }
        let grid = NSGridView(views: [[label("类型:"), popup]])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 200
        let fitting = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        alert.accessoryView = grid

        guard AlertPresenter.presentModal(alert) == .alertFirstButtonReturn else { return }
        guard let type = popup.titleOfSelectedItem else { return }

        switch type {
        case "下载字幕": subtitlePresetFlow(title: title, target: target)
        case "录制广播": radioPresetFlow(target: target)
        default: tverPresetFlow(title: title, target: target)
        }
    }

    /// launcher.py:314-334: channel + 开始/结束时间 + output + name. All
    /// defaults via `dv(field:fallback:)`. Preset JSON keys are snake_case
    /// via Preset's CodingKeys.
    private static func subtitlePresetFlow(title: String, target: Preset?) {
        let channel = dv(target?.channel, fallback: "TBS")
        let timeStart = dv(target?.timeStart, fallback: "19:00")
        let timeEnd = dv(target?.timeEnd, fallback: "20:00")
        let content = makePresetAlert(
            title: "\(title) — 字幕",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            popupDefault: channel,
            startLabel: "开始时间 (HH:MM):", startDefault: timeStart,
            secondLabel: "结束时间 (HH:MM):", secondDefault: timeEnd,
            outputInitial: dv(target?.output, fallback: "sub_\(channel.lowercased())"),
            nameInitial: dv(target?.name, fallback: presetNameDefault(action: .subtitle, channel: channel, start: timeStart)),
            outputFormat: { "sub_\($0.lowercased())" },
            nameFormat: { ch, start in presetNameDefault(action: .subtitle, channel: ch, start: start) })
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let ch = content.popup.titleOfSelectedItem ?? ""
        let start = trimmed(content.startField.stringValue)
        let end = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        let name = trimmed(content.nameField.stringValue)
        guard !ch.isEmpty, !start.isEmpty, !end.isEmpty,
              !output.isEmpty, !name.isEmpty else { return }
        commitPreset(Preset(
            name: name, action: .subtitle,
            channel: ch, station: nil,
            timeStart: start, timeEnd: end,
            startAt: nil, duration: nil, output: output), target: target)
    }

    /// launcher.py:336-357: station + 开始时间 + 时长 + output + name, plus
    /// the 转换为视频 checkbox INSIDE the form (launcher.py's osa_form radio
    /// preset field order: ..., 输出文件名, 转换为视频 checkbox, 收藏名称) —
    /// replacing the separate confirm alert (launcher.py:352-354 previously
    /// asked `osa_confirm("录制完成后转换为视频？")` after the name dialog).
    /// Unlike the other dialogs, unchecking does NOT bail the flow: a false
    /// answer is stored as nil so `to_video` is omitted from JSON (default →
    /// key omitted); a true answer is stored as true.
    private static func radioPresetFlow(target: Preset?) {
        let content = radioPresetAlert(target: target)
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let st = content.popup.titleOfSelectedItem ?? ""
        let start = trimmed(content.startField.stringValue)
        let durationValue = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        let name = trimmed(content.nameField.stringValue)
        guard !st.isEmpty, !start.isEmpty, !durationValue.isEmpty,
              !output.isEmpty, !name.isEmpty else { return }

        let toVideo = content.checkbox?.state == .on
        commitPreset(Preset(
            name: name, action: .radio,
            channel: nil, station: st,
            timeStart: nil, timeEnd: nil,
            startAt: start, duration: durationValue, output: output,
            toVideo: toVideo ? true : nil), target: target)
    }

    /// QA hook (probe): builds the radio preset alert WITHOUT running a
    /// modal — the exact construction `radioPresetFlow` presents, with
    /// dv()-prefilled defaults. The 转换为视频 checkbox defaults OFF for a
    /// new preset and ON for an edit target with toVideo == true.
    static func radioPresetAlert(target: Preset? = nil) -> PresetAlertContent {
        let station = dv(target?.station, fallback: "TBS")
        let startAt = dv(target?.startAt, fallback: "21:00")
        let duration = dv(target?.duration, fallback: "30")
        return makePresetAlert(
            title: "\(target == nil ? "新建收藏" : "修改收藏") — 广播",
            popupLabel: "电台:",
            options: CommandBuilder.radioStations,
            popupDefault: station,
            startLabel: "开始时间 (HH:MM):", startDefault: startAt,
            secondLabel: "录制时长 (分钟):", secondDefault: duration,
            outputInitial: dv(target?.output, fallback: "radio_\(station.lowercased()).m4a"),
            nameInitial: dv(target?.name, fallback: presetNameDefault(action: .radio, channel: station, start: startAt)),
            outputFormat: { "radio_\($0.lowercased()).m4a" },
            nameFormat: { st, start in presetNameDefault(action: .radio, channel: st, start: start) },
            checkboxLabel: "转换为视频",
            checkboxDefault: target?.toVideo ?? false)
    }

    /// launcher.py:489-516: channel + 开始时间 + 结束时间 + output + name.
    /// All defaults via `dv(field:fallback:)`. The 结束时间 default is
    /// ALWAYS re-derived from the stored start + duration
    /// (`LabelHelpers.endTimeLabel`) — the target's stored `end_time` is no
    /// longer read as a default (dropped preference), so stale end_time on
    /// edits can never surface. On confirm the duration is DERIVED from
    /// start/end (launcher.py:506 `_duration_min`) and `end_time` is still
    /// SAVED alongside it (launcher.py:511-516) — a 0/negative/nil duration
    /// bails with no side effects (launcher.py:509-510).
    private static func tverPresetFlow(title: String, target: Preset?) {
        let channel = dv(target?.channel, fallback: "TBS")
        let startAt = dv(target?.startAt, fallback: "21:00")
        let duration = dv(target?.duration, fallback: "60")
        let endTime = LabelHelpers.endTimeLabel(startAt: startAt, durationMin: duration)
        let content = makePresetAlert(
            title: "\(title) — TVer",
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder,
            popupDefault: channel,
            startLabel: "开始时间 (HH:MM):", startDefault: startAt,
            secondLabel: "结束时间 (HH:MM):", secondDefault: endTime,
            outputInitial: dv(target?.output, fallback: "\(channel.lowercased()).mp4"),
            nameInitial: dv(target?.name, fallback: presetNameDefault(action: .tver, channel: channel, start: startAt)),
            outputFormat: { "\($0.lowercased()).mp4" },
            nameFormat: { ch, start in presetNameDefault(action: .tver, channel: ch, start: start) })
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }

        let ch = content.popup.titleOfSelectedItem ?? ""
        let start = trimmed(content.startField.stringValue)
        let end = trimmed(content.secondField.stringValue)
        let output = trimmed(content.outputField.stringValue)
        let name = trimmed(content.nameField.stringValue)
        guard !ch.isEmpty, !start.isEmpty, !end.isEmpty,
              !output.isEmpty, !name.isEmpty else { return }
        guard let durationMin = LabelHelpers.durationMin(startAt: start, endTime: end),
              durationMin > 0 else { return }
        commitPreset(Preset(
            name: name, action: .tver,
            channel: ch, station: nil,
            timeStart: nil, timeEnd: nil,
            startAt: start, duration: String(durationMin), output: output,
            endTime: end), target: target)
    }

    /// launcher.py:359-385: `idx = next((i for i,p in enumerate(self.presets)
    /// if p is target), None)` → overwrite at idx IN PLACE, else append; then
    /// `_save_data()`. Swift Preset is a struct (no `p is target` object
    /// identity), so the edit target is matched by NAME — managePresets also
    /// finds its target by name, and runPreset menu matching uses trimmed
    /// names (AppDelegate against freshly-loaded state).
    static func commitPreset(_ preset: Preset, target: Preset?) {
        let store = StateStore()
        var state = store.load()
        if let target,
           let idx = state.presets.firstIndex(where: { $0.name == target.name }) {
            state.presets[idx] = preset
        } else {
            state.presets.append(preset)
        }
        store.save(state)
    }

    // MARK: - 管理收藏 (launcher.py:382-408)

    /// launcher.py:382-408: empty guard → choose preset → choose action
    /// (修改/删除) → apply + save. Any cancel returns with no side
    /// effects.
    static func managePresets() {
        let store = StateStore()
        let state = store.load()
        guard !state.presets.isEmpty else {
            // launcher.py:383-385 `osa_dialog("管理收藏", "暂无收藏", "")`.
            let alert = NSAlert()
            alert.messageText = "管理收藏"
            alert.informativeText = "暂无收藏"
            AlertPresenter.presentModal(alert)
            return
        }

        // launcher.py:387-390: choose the preset to manage.
        let chooseAlert = NSAlert()
        chooseAlert.messageText = "管理收藏"
        chooseAlert.informativeText = "选择要管理的收藏:"
        chooseAlert.addButton(withTitle: "确认")
        chooseAlert.addButton(withTitle: "取消")
        chooseAlert.buttons[1].keyEquivalent = "\u{1b}"
        let choosePopup = NSPopUpButton()
        choosePopup.addItems(withTitles: state.presets.map(\.name))
        choosePopup.selectItem(at: 0)
        let chooseGrid = NSGridView(views: [[label("收藏:"), choosePopup]])
        chooseGrid.rowSpacing = 8
        chooseGrid.columnSpacing = 12
        chooseGrid.column(at: 1).xPlacement = .fill
        chooseGrid.column(at: 1).width = 200
        let chooseFitting = chooseGrid.fittingSize
        chooseGrid.frame = NSRect(x: 0, y: 0, width: chooseFitting.width, height: chooseFitting.height)
        chooseAlert.accessoryView = chooseGrid
        guard AlertPresenter.presentModal(chooseAlert) == .alertFirstButtonReturn else { return }
        guard let chosen = choosePopup.titleOfSelectedItem else { return }

        // launcher.py:392-394: choose the action (修改/删除).
        let actionAlert = NSAlert()
        actionAlert.messageText = "管理收藏"
        actionAlert.informativeText = "对「\(chosen)」执行:"
        actionAlert.addButton(withTitle: "确认")
        actionAlert.addButton(withTitle: "取消")
        actionAlert.buttons[1].keyEquivalent = "\u{1b}"
        let actionPopup = NSPopUpButton()
        actionPopup.addItems(withTitles: ["修改", "删除"])
        actionPopup.selectItem(at: 0)
        let actionGrid = NSGridView(views: [[label("操作:"), actionPopup]])
        actionGrid.rowSpacing = 8
        actionGrid.columnSpacing = 12
        actionGrid.column(at: 1).xPlacement = .fill
        actionGrid.column(at: 1).width = 200
        let actionFitting = actionGrid.fittingSize
        actionGrid.frame = NSRect(x: 0, y: 0, width: actionFitting.width, height: actionFitting.height)
        actionAlert.accessoryView = actionGrid
        guard AlertPresenter.presentModal(actionAlert) == .alertFirstButtonReturn else { return }
        guard let action = actionPopup.titleOfSelectedItem else { return }

        if action == "修改" {
            // launcher.py:396-399: find the preset by name → _preset_flow
            // (target) for the in-place overwrite flow.
            if let target = state.presets.first(where: { $0.name == chosen }) {
                presetFlow(target: target)
            }
        } else if action == "删除" {
            // launcher.py:405-408: confirm → remove ALL with that name + save.
            let confirm = NSAlert()
            confirm.messageText = "管理收藏"
            confirm.informativeText = "确认删除收藏「\(chosen)」？"
            confirm.addButton(withTitle: "确认")
            confirm.addButton(withTitle: "取消")
            guard AlertPresenter.presentModal(confirm) == .alertFirstButtonReturn else { return }
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
                output: preset.output ?? "",
                toVideo: preset.toVideo ?? false)
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

    /// launcher.py:313 `dv(field, fallback)`:
    /// `return target.get(field, fallback) if target else fallback`.
    private static func dv(_ value: String?, fallback: String) -> String {
        value ?? fallback
    }

    /// launcher.py:446/470/497 preset-name defaults: the 收藏名称 fallback
    /// for a NEW preset is "字幕 <ch> <start>" / "广播 <st> <start>" /
    /// "<ch> <start>" — the start time FOLLOWS the form's start field (the
    /// dv()'d value when the form opens, the live field value as the user
    /// edits it). The radio caller passes the station as `channel`.
    static func presetNameDefault(action: PresetAction, channel: String, start: String) -> String {
        switch action {
        case .subtitle: return "字幕 \(channel) \(start)"
        case .radio: return "广播 \(channel) \(start)"
        case .tver: return "\(channel) \(start)"
        }
    }

    /// Builds one preset-save alert: messageText = flow title, accessory =
    /// NSGridView stacking [popup, 开始时间, second field, 输出文件名,
    /// (optional 转换为视频 checkbox), 收藏名称]. The checkbox row (radio
    /// preset only) sits between 输出文件名 and 收藏名称, mirroring
    /// launcher.py's osa_form radio preset field order. Field defaults are
    /// dv()-prefilled from the edit target (or the launcher.py fallbacks for
    /// a new preset). The output default follows the popup selection and the
    /// name default follows popup + start time (launcher.py computes each
    /// default in a later sequential dialog), both only while the user
    /// hasn't typed their own value.
    private static func makePresetAlert(
        title: String,
        popupLabel: String,
        options: [String],
        popupDefault: String,
        startLabel: String, startDefault: String,
        secondLabel: String, secondDefault: String,
        outputInitial: String,
        nameInitial: String,
        outputFormat: @escaping (String) -> String,
        nameFormat: @escaping (String, String) -> String,
        checkboxLabel: String? = nil,
        checkboxDefault: Bool = false
    ) -> PresetAlertContent {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        let defaultIndex = popup.indexOfItem(withTitle: popupDefault)
        if defaultIndex >= 0 {
            popup.selectItem(at: defaultIndex)
        }

        let startField = NSTextField(string: startDefault)
        let secondField = NSTextField(string: secondDefault)
        let outputField = NSTextField(string: outputInitial)
        let nameField = NSTextField(string: nameInitial)

        let checkbox: NSButton?
        if let checkboxLabel {
            let button = NSButton(checkboxWithTitle: checkboxLabel, target: nil, action: nil)
            button.state = checkboxDefault ? .on : .off
            checkbox = button
        } else {
            checkbox = nil
        }

        var rows: [[NSView]] = [
            [label(popupLabel), popup],
            [label(startLabel), startField],
            [label(secondLabel), secondField],
            [label("输出文件名:"), outputField],
        ]
        if let checkbox {
            rows.append([label(""), checkbox])
        }
        rows.append([label("收藏名称:"), nameField])
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 200
        let fitting = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        alert.accessoryView = grid

        let binder = PresetSaveBinder(
            outputFormat: outputFormat, nameFormat: nameFormat,
            popup: popup, startField: startField,
            outputField: outputField, nameField: nameField)
        return PresetAlertContent(
            alert: alert, popup: popup,
            startField: startField, secondField: secondField,
            outputField: outputField, nameField: nameField,
            checkbox: checkbox, binder: binder)
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
    /// `checkbox` is the optional 转换为视频 row (radio preset only), nil
    /// for subtitle/tver forms.
    final class PresetAlertContent {
        let alert: NSAlert
        let popup: NSPopUpButton
        let startField: NSTextField
        let secondField: NSTextField
        let outputField: NSTextField
        let nameField: NSTextField
        let checkbox: NSButton?
        let binder: PresetSaveBinder

        init(
            alert: NSAlert, popup: NSPopUpButton,
            startField: NSTextField, secondField: NSTextField,
            outputField: NSTextField, nameField: NSTextField,
            checkbox: NSButton?,
            binder: PresetSaveBinder
        ) {
            self.alert = alert
            self.popup = popup
            self.startField = startField
            self.secondField = secondField
            self.outputField = outputField
            self.nameField = nameField
            self.checkbox = checkbox
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

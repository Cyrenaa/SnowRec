import AppKit

/// Preset (收藏) management flows, mirroring launcher.py:309-454:
/// `presetFlow` (新建收藏/修改收藏: type chooser + per-type field alerts with
/// dv() prefilled defaults), `editPreset`/`deletePreset` (收藏条目管理:
/// modify/delete directly on a preset row's manage submenu), and `runPreset`
/// (运行收藏: command build → Task → history → spawn).
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
    /// Single-dialog preset flow: the type chooser and the per-type field
    /// form are ONE alert — the field section swaps live as the type
    /// changes. Confirm reads the fields for the selected type and persists
    /// via StateStore (launcher.py:384 `_save_data()`).
    static func presetFlow(target: Preset?) {
        let title = target == nil ? "新建收藏" : "修改收藏"
        let content = makePresetFormAlert(title: title, target: target)
        guard AlertPresenter.presentModal(content.alert) == .alertFirstButtonReturn else { return }
        guard let type = content.typePopup.titleOfSelectedItem,
              let fields = content.fields[type] else { return }

        let popupValue = fields.popup.titleOfSelectedItem ?? ""
        let start = trimmed(fields.startField.stringValue)
        let second = trimmed(fields.secondField.stringValue)
        let output = trimmed(fields.outputField.stringValue)
        let name = trimmed(fields.nameField.stringValue)

        switch type {
        case "下载字幕":
            guard !popupValue.isEmpty, !start.isEmpty, !second.isEmpty,
                  !output.isEmpty, !name.isEmpty else { return }
            commitPreset(Preset(
                name: name, action: .subtitle,
                channel: popupValue, station: nil,
                timeStart: start, timeEnd: second,
                startAt: nil, duration: nil, output: output), target: target)
        case "录制广播":
            guard !popupValue.isEmpty, !start.isEmpty, !second.isEmpty,
                  !output.isEmpty, !name.isEmpty else { return }
            let toVideo = fields.checkbox?.state == .on
            commitPreset(Preset(
                name: name, action: .radio,
                channel: nil, station: popupValue,
                timeStart: nil, timeEnd: nil,
                startAt: start, duration: second, output: output,
                toVideo: toVideo ? true : nil), target: target)
        default: // 录制 TVer
            guard !popupValue.isEmpty, !start.isEmpty, !second.isEmpty,
                  !output.isEmpty, !name.isEmpty else { return }
            guard let durationMin = LabelHelpers.durationMin(startAt: start, endTime: second),
                  durationMin > 0 else { return }
            guard AlertPresenter.confirmLongDuration(minutes: durationMin) else { return }
            commitPreset(Preset(
                name: name, action: .tver,
                channel: popupValue, station: nil,
                timeStart: nil, timeEnd: nil,
                startAt: start, duration: String(durationMin), output: output,
                endTime: second), target: target)
        }
    }

    /// QA hook (probe): builds the radio preset alert WITHOUT running a
    /// modal (kept for --alert-probe-test; the live flow now uses the
    /// single-dialog makePresetFormAlert). The 转换为视频 checkbox defaults
    /// OFF for a new preset and ON for an edit target with toVideo == true.
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

    /// launcher.py:359-385: `idx = next((i for i,p in enumerate(self.presets)
    /// if p is target), None)` → overwrite at idx IN PLACE, else append; then
    /// `_save_data()`. Swift Preset is a struct (no `p is target` object
    /// identity), so the edit target is matched by NAME — editPreset and the
    /// runPreset menu matching use trimmed names (AppDelegate against
    /// freshly-loaded state).
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

    // MARK: - 收藏条目管理 (replaces launcher.py:382-408 choose-then-act)

    /// 修改收藏: opens the edit flow directly for the given preset
    /// (menu entry: the preset row's 修改收藏 submenu item).
    static func editPreset(_ preset: Preset) {
        presetFlow(target: preset)
    }

    /// 删除收藏: confirm, then remove ALL presets with the same name
    /// (launcher.py:405-408 parity).
    static func deletePreset(_ preset: Preset) {
        let store = StateStore()
        let confirm = NSAlert()
        confirm.messageText = "管理收藏"
        confirm.informativeText = "确认删除收藏「\(preset.name)」？"
        confirm.addButton(withTitle: "确认")
        confirm.addButton(withTitle: "取消")
        confirm.buttons[1].keyEquivalent = "\u{1b}"
        guard AlertPresenter.presentModal(confirm) == .alertFirstButtonReturn else { return }
        var updated = store.load()
        updated.presets.removeAll { $0.name == preset.name }
        store.save(updated)
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
            // Parity with launcher.py _run_preset + 6a4bd3c: non-numeric,
            // non-finite (nan/inf/-inf — Swift Double("inf") parses like
            // Python float("inf")), or non-positive duration -> silent skip
            // (the Python side falls back to None / skips <=0); >24h ->
            // confirm, cancel = skip. The returned Task is built but never
            // appended/spawned (skip marker).
            if let dur = preset.duration.flatMap(Double.init),
               dur.isFinite, dur > 0 {
                guard AlertPresenter.confirmLongDuration(minutes: dur) else {
                    return Task(name: preset.name, cmd: cmd)
                }
            } else {
                return Task(name: preset.name, cmd: cmd)
            }
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

    /// One type's field controls inside the dynamic preset form. `binder`
    /// is retained so the popup/start defaults keep updating output/name
    /// (target/action holds no strong reference).
    final class PresetTypeFields {
        let popup: NSPopUpButton
        let startField: NSTextField
        let secondField: NSTextField
        let outputField: NSTextField
        let nameField: NSTextField
        let checkbox: NSButton?
        let grid: NSView
        let binder: PresetSaveBinder

        init(
            popup: NSPopUpButton,
            startField: NSTextField, secondField: NSTextField,
            outputField: NSTextField, nameField: NSTextField,
            checkbox: NSButton?, grid: NSView, binder: PresetSaveBinder
        ) {
            self.popup = popup
            self.startField = startField
            self.secondField = secondField
            self.outputField = outputField
            self.nameField = nameField
            self.checkbox = checkbox
            self.grid = grid
            self.binder = binder
        }
    }

    /// Holds the dynamic preset form's alert + per-type fields + the
    /// controller (retained for the whole modal session).
    final class PresetFormContent {
        let alert: NSAlert
        let typePopup: NSPopUpButton
        let fields: [String: PresetTypeFields]
        let controller: PresetFormController

        init(
            alert: NSAlert, typePopup: NSPopUpButton,
            fields: [String: PresetTypeFields], controller: PresetFormController
        ) {
            self.alert = alert
            self.typePopup = typePopup
            self.fields = fields
            self.controller = controller
        }
    }

    /// Swaps the field section when the type popup changes and grows or
    /// shrinks the alert window by the height delta. NSAlert sizes its
    /// window from the accessory's frame at build time, so a live swap
    /// needs a manual window resize (the accessory is frame-based, no
    /// autolayout contract).
    @MainActor
    final class PresetFormController: NSObject {
        private let alert: NSAlert
        private let container: NSView
        private let typeRow: NSView
        private let fieldGap: CGFloat
        private let grids: [String: NSView]
        private var current: NSView

        init(
            alert: NSAlert, container: NSView, typeRow: NSView, fieldGap: CGFloat,
            grids: [String: NSView], initial: NSView
        ) {
            self.alert = alert
            self.container = container
            self.typeRow = typeRow
            self.fieldGap = fieldGap
            self.grids = grids
            self.current = initial
        }

        @objc func typeChanged(_ sender: NSPopUpButton) {
            guard let type = sender.titleOfSelectedItem,
                  let grid = grids[type], grid !== current else { return }
            let heightDelta = grid.frame.height - current.frame.height
            current.removeFromSuperview()
            var fieldFrame = grid.frame
            fieldFrame.origin = .zero
            grid.frame = fieldFrame
            container.addSubview(grid)
            // Re-append the type row so it stays on TOP of the z-order —
            // addSubview stacks later views above earlier ones, and any
            // frame overlap would otherwise swallow the popup's clicks.
            typeRow.removeFromSuperview()
            var typeRowFrame = typeRow.frame
            typeRowFrame.origin.y = grid.frame.height + fieldGap
            typeRow.frame = typeRowFrame
            container.addSubview(typeRow)
            current = grid

            var containerFrame = container.frame
            containerFrame.size.height += heightDelta
            container.frame = containerFrame

            guard heightDelta != 0 else {
                alert.layout()
                return
            }
            let window = alert.window
            var windowFrame = window.frame
            windowFrame.origin.y -= heightDelta
            windowFrame.size.height += heightDelta
            window.setFrame(windowFrame, display: true)
            // Relayout the alert content so the accessory keeps its place
            // within the resized window (buttons stay at the bottom).
            alert.layout()
        }
    }

    /// Builds the single-alert preset form: a type popup row on top, the
    /// selected type's field grid below (channel/station popup, start,
    /// second field, output, optional checkbox, name). All three type grids
    /// are prebuilt with dv()-prefilled defaults; PresetFormController
    /// swaps the field section live on type change.
    private static func makePresetFormAlert(title: String, target: Preset?) -> PresetFormContent {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.icon = DialogFlows.snowflakeIcon()
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let typePopup = NSPopUpButton()
        typePopup.addItems(withTitles: ["下载字幕", "录制广播", "录制 TVer"])
        let defaultType: String
        switch target?.action {
        case .subtitle: defaultType = "下载字幕"
        case .radio: defaultType = "录制广播"
        case .tver: defaultType = "录制 TVer"
        case .none: defaultType = "下载字幕"
        }
        let defaultIndex = typePopup.indexOfItem(withTitle: defaultType)
        if defaultIndex >= 0 { typePopup.selectItem(at: defaultIndex) }

        let typeRow = NSGridView(views: [[label("类型:"), typePopup]])
        typeRow.columnSpacing = 12
        typeRow.column(at: 1).xPlacement = .fill
        typeRow.column(at: 1).width = 200
        let typeRowHeight = typeRow.fittingSize.height

        // ── 下载字幕 fields ──
        let subChannel = dv(target?.channel, fallback: "TBS")
        let subStart = dv(target?.timeStart, fallback: "19:00")
        let subEnd = dv(target?.timeEnd, fallback: "20:00")
        let subFields = buildTypeFields(
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder, popupDefault: subChannel,
            startLabel: "开始时间 (HH:MM):", startDefault: subStart,
            secondLabel: "结束时间 (HH:MM):", secondDefault: subEnd,
            outputInitial: dv(target?.output, fallback: "sub_\(subChannel.lowercased())"),
            nameInitial: dv(target?.name, fallback: presetNameDefault(action: .subtitle, channel: subChannel, start: subStart)),
            outputFormat: { "sub_\($0.lowercased())" },
            nameFormat: { ch, start in presetNameDefault(action: .subtitle, channel: ch, start: start) })

        // ── 录制广播 fields ──
        let radioStation = dv(target?.station, fallback: "TBS")
        let radioStart = dv(target?.startAt, fallback: "21:00")
        let radioDuration = dv(target?.duration, fallback: "30")
        let radioFields = buildTypeFields(
            popupLabel: "电台:",
            options: CommandBuilder.radioStations, popupDefault: radioStation,
            startLabel: "开始时间 (HH:MM):", startDefault: radioStart,
            secondLabel: "录制时长 (分钟):", secondDefault: radioDuration,
            outputInitial: dv(target?.output, fallback: "radio_\(radioStation.lowercased()).m4a"),
            nameInitial: dv(target?.name, fallback: presetNameDefault(action: .radio, channel: radioStation, start: radioStart)),
            outputFormat: { "radio_\($0.lowercased()).m4a" },
            nameFormat: { st, start in presetNameDefault(action: .radio, channel: st, start: start) },
            checkboxLabel: "转换为视频", checkboxDefault: target?.toVideo ?? false)

        // ── 录制 TVer fields ──
        let tvChannel = dv(target?.channel, fallback: "TBS")
        let tvStart = dv(target?.startAt, fallback: "21:00")
        let tvDuration = dv(target?.duration, fallback: "60")
        let tvEnd = LabelHelpers.endTimeLabel(startAt: tvStart, durationMin: tvDuration)
        let tverFields = buildTypeFields(
            popupLabel: "频道:",
            options: CommandBuilder.channelOrder, popupDefault: tvChannel,
            startLabel: "开始时间 (HH:MM):", startDefault: tvStart,
            secondLabel: "结束时间 (HH:MM):", secondDefault: tvEnd,
            outputInitial: dv(target?.output, fallback: "\(tvChannel.lowercased()).mp4"),
            nameInitial: dv(target?.name, fallback: presetNameDefault(action: .tver, channel: tvChannel, start: tvStart)),
            outputFormat: { "\($0.lowercased()).mp4" },
            nameFormat: { ch, start in presetNameDefault(action: .tver, channel: ch, start: start) })

        let fields: [String: PresetTypeFields] = [
            "下载字幕": subFields, "录制广播": radioFields, "录制 TVer": tverFields,
        ]
        let initialFields = fields[defaultType] ?? subFields

        // Accessory = type row pinned to the TOP, field section below with
        // a gap; the window grows downward on type switch so the type row
        // never moves (non-flipped coords: y grows up).
        let fieldGap: CGFloat = 10
        let containerWidth = max(typeRow.fittingSize.width, initialFields.grid.frame.width)
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: containerWidth,
            height: typeRowHeight + fieldGap + initialFields.grid.frame.height))
        var initialFrame = initialFields.grid.frame
        initialFrame.origin = .zero
        initialFields.grid.frame = initialFrame
        container.addSubview(initialFields.grid)
        typeRow.frame = NSRect(x: 0, y: initialFrame.height + fieldGap,
                               width: containerWidth, height: typeRowHeight)
        container.addSubview(typeRow)
        alert.accessoryView = container

        let grids: [String: NSView] = [
            "下载字幕": subFields.grid, "录制广播": radioFields.grid, "录制 TVer": tverFields.grid,
        ]
        let controller = PresetFormController(
            alert: alert, container: container, typeRow: typeRow, fieldGap: fieldGap,
            grids: grids, initial: initialFields.grid)
        typePopup.target = controller
        typePopup.action = #selector(PresetFormController.typeChanged(_:))

        return PresetFormContent(
            alert: alert, typePopup: typePopup, fields: fields, controller: controller)
    }

    /// Builds one type's field grid (channel/station popup + start + second
    /// field + output + optional checkbox + 收藏名称) with its live default
    /// binder (popup/start changes re-derive output/name while untouched).
    private static func buildTypeFields(
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
    ) -> PresetTypeFields {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        let defaultIndex = popup.indexOfItem(withTitle: popupDefault)
        if defaultIndex >= 0 { popup.selectItem(at: defaultIndex) }

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
        if let checkbox { rows.append([label(""), checkbox]) }
        rows.append([label("收藏名称:"), nameField])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 200
        let fitting = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)

        let binder = PresetSaveBinder(
            outputFormat: outputFormat, nameFormat: nameFormat,
            popup: popup, startField: startField,
            outputField: outputField, nameField: nameField)

        return PresetTypeFields(
            popup: popup, startField: startField, secondField: secondField,
            outputField: outputField, nameField: nameField,
            checkbox: checkbox, grid: grid, binder: binder)
    }

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
        alert.icon = DialogFlows.snowflakeIcon()
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

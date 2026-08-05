import AppKit
import CoreGraphics
import Foundation

// --dump-state: print the persisted state as pretty JSON and exit WITHOUT
// launching the GUI (no NSApplication, no status item). Used for QA.
if CommandLine.arguments.contains("--dump-state") {
    let state = StateStore().load()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let text = (try? encoder.encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    print(text)
    exit(0)
}

// --dump-helpers: print the RAW outputs of every label/log-naming helper on
// the pinned test cases (NOT pre-asserted) so external QA can compare against
// launcher.py character-for-character. Exit 0, no GUI.
if CommandLine.arguments.contains("--dump-helpers") {
    // Fixed date 2026-08-01 22:51:57 (local, Asia/Tokyo) for logFileName.
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 1
    comps.hour = 22; comps.minute = 51; comps.second = 57
    let fixedDate = Calendar.current.date(from: comps) ?? Date()

    print("safeName1=\(LabelHelpers.safeName("TVer CX (富士) 22:53-22:58"))")
    print("safeName2=\(LabelHelpers.safeName("🩷mtmr"))")
    print("safeName3=\(LabelHelpers.safeName(String(repeating: "a", count: 45)))")
    print("logFileName=\(LabelHelpers.logFileName(name: "TVer CX (富士) 22:53-22:58", date: fixedDate))")
    print("endTime1=\(LabelHelpers.endTimeLabel(startAt: "21:00", durationMin: "30"))")
    print("endTime2=\(LabelHelpers.endTimeLabel(startAt: "23:50", durationMin: "5"))")
    print("endTime3=\(LabelHelpers.endTimeLabel(startAt: "23:58", durationMin: "5"))")
    print("endTime4=\(LabelHelpers.endTimeLabel(startAt: "xx", durationMin: "5"))")
    print("endTime5=\(LabelHelpers.endTimeLabel(startAt: "21:00", durationMin: "0.1"))")
    print("elapsed1=\(LabelHelpers.elapsedLabel(seconds: 3661))")
    print("elapsed2=\(LabelHelpers.elapsedLabel(seconds: 0))")
    exit(0)
}

// --dump-builders: build the preset command arrays (subtitle/radio/tver) on
// FIXED inputs and print them as JSON on labeled lines, so external QA can
// compare element-by-element against arrays derived from launcher.py:418-447.
// Runs BEFORE the GUI; exits 0. Dev-mode contract (D13): requires
// SNOWREC_ROOT — the debug binary's bundle lives under `.build/` where the
// 3-level walk cannot resolve the repo root, so an unset env var is an error
// (exit non-zero, no GUI).
if CommandLine.arguments.contains("--dump-builders") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--dump-builders requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func json(_ cmd: [String]) -> String {
        (try? encoder.encode(cmd)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    let subtitleCmd = CommandBuilder.subtitleCommand(
        repoRoot: root, channel: "CX (富士)",
        timeStart: "19:00", timeEnd: "20:00", output: "sub_cx (富士)")
    print("subtitle=\(json(subtitleCmd))")
    let radioCmd = CommandBuilder.radioCommand(
        repoRoot: root, station: "TBS",
        startAt: "21:00", duration: "30", output: "radio_tbs.m4a")
    print("radio=\(json(radioCmd))")
    let radioToVideoCmd = CommandBuilder.radioCommand(
        repoRoot: root, station: "TBS",
        startAt: "21:00", duration: "30", output: "radio_tbs.m4a", toVideo: true)
    print("radioToVideo=\(json(radioToVideoCmd))")
    let radio60Cmd = CommandBuilder.radioCommand(
        repoRoot: root, station: "TBS",
        startAt: "21:00", duration: "60", output: "radio_tbs.m4a")
    print("radio60=\(json(radio60Cmd))")
    let tverCmd = CommandBuilder.tverCommand(
        repoRoot: root, channel: "TBS",
        startAt: "21:00", duration: "30", output: "tbs.mp4")
    print("tver=\(json(tverCmd))")
    let unknownCmd = CommandBuilder.subtitleCommand(
        repoRoot: root, channel: "NOPE",
        timeStart: "19:00", timeEnd: "20:00", output: "x.srt")
    print("unknownChannel=\(json(unknownCmd))")
    exit(0)
}

// --dump-restart: print the restart decision from
// RestartSupport.restartDecision() as labeled lines — mode "bundle" when
// Bundle.main.bundlePath ends with ".app", else "reexec" — and exit 0
// without launching the GUI. QA of the T7+T8 restart decision: the
// packaged binary reports bundle, the debug binary reports reexec.
if CommandLine.arguments.contains("--dump-restart") {
    let decision = RestartSupport.restartDecision()
    print("restartMode=\(decision.mode)")
    print("restartPath=\(decision.path)")
    exit(0)
}

// --dump-notifications: print the CURRENT notification authorizationStatus
// (authorized / denied / notDetermined / provisional) on a labeled line,
// then every DELIVERED notification as `delivered=["id","title","body"]`
// (getDeliveredNotifications is only callable inside the app process —
// dual-review note 1); exit 0 without launching the GUI. External QA asserts
// on the labels (plan M6: macOS caches authorization per bundle id — the
// PACKAGED binary carries com.snowrec.launcher; the debug binary would
// report a separate identity).
if CommandLine.arguments.contains("--dump-notifications") {
    await Notifications.dumpStatus()
    await Notifications.dumpDelivered()
    exit(0)
}

// --spawn-test: run the REAL TaskManager spawn path on a fixed python
// payload (sleep 3s + print 'spawned-ok'), wait for completion, then print
// JSON {"pid":..., "log":..., "exitCode":...} and exit 0. No GUI.
// Requires SNOWREC_ROOT (dev-mode contract, same as --dump-builders);
// HOME is honored through LogCleanup.logDirectory / StateStore, so QA
// sandboxes work. The state file gets a "spawn-test" history entry with
// pid + log path written by TaskManager (launcher.py:141-160 parity).
struct SpawnTestResult: Codable {
    let pid: Int
    let log: String?
    let exitCode: Int32
}
if CommandLine.arguments.contains("--spawn-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--spawn-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let store = StateStore()
    let name = "spawn-test"
    let cmd = [
        "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
        "-c", "import time;time.sleep(3);print('spawned-ok')",
    ]
    let task = Task(name: name, cmd: cmd)
    var state = store.load()
    let entry = HistoryEntry(label: name, cmd: cmd, status: "运行中", pid: nil, log: nil)
    state.history.insert(entry, at: 0)  // launcher.py:246 _add_history parity
    task.historyEntry = entry
    store.save(state)

    let result = await TaskManager.start(task, store: store)

    let out = SpawnTestResult(pid: result.pid, log: result.logPath, exitCode: result.exitCode)
    let data = (try? JSONEncoder().encode(out)) ?? Data("{}".utf8)
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

// --termination-test: spawn a long-running payload (sleep 60), let it run
// 2 seconds, then stop it through TaskManager.stop (SIGTERM -> 5s -> SIGKILL
// to the process group) and print {"pid":..., "stopped":true}. QA then
// asserts pgrep is empty and the sandbox state entry is 失败.
struct TerminationTestResult: Codable {
    let pid: Int
    let stopped: Bool
    let status: String
}
if CommandLine.arguments.contains("--termination-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--termination-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let store = StateStore()
    let name = "termination-test"
    let cmd = [
        "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
        "-c", "import time;time.sleep(60)",
    ]
    let task = Task(name: name, cmd: cmd)
    var state = store.load()
    let entry = HistoryEntry(label: name, cmd: cmd, status: "运行中", pid: nil, log: nil)
    state.history.insert(entry, at: 0)
    task.historyEntry = entry
    store.save(state)

    // TaskManager.start blocks until the child exits, so run it concurrently
    // (Swift.Task — the bare `Task { }` spelling resolves to the local Task
    // class) while the top level waits 2s and then stops it. Both closures
    // are MainActor-isolated, so access to `task` is serialized.
    let started = Swift.Task { @MainActor in
        await TaskManager.start(task, store: store)
    }
    try? await Swift.Task.sleep(for: .seconds(2))
    let stopped = await TaskManager.stop(task, store: store)
    _ = await started.value

    let out = TerminationTestResult(
        pid: task.historyEntry?.pid ?? -1, stopped: stopped, status: task.status)
    let data = (try? JSONEncoder().encode(out)) ?? Data("{}".utf8)
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

// --termination-completed-test: spawn a payload that finishes naturally
// (sleep 1, rc=0 -> 成功), then call stop AFTER completion. Must not crash
// and must leave the status as 成功 (launcher.py: terminate-on-None no-op).
if CommandLine.arguments.contains("--termination-completed-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--termination-completed-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let store = StateStore()
    let name = "termination-completed-test"
    let cmd = [
        "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
        "-c", "import time;time.sleep(1)",
    ]
    let task = Task(name: name, cmd: cmd)
    var state = store.load()
    let entry = HistoryEntry(label: name, cmd: cmd, status: "运行中", pid: nil, log: nil)
    state.history.insert(entry, at: 0)
    task.historyEntry = entry
    store.save(state)

    let result = await TaskManager.start(task, store: store)  // natural completion
    let stopped = await TaskManager.stop(task, store: store)  // no-op, no crash

    let out = TerminationTestResult(
        pid: result.pid, stopped: stopped, status: task.status)
    let data = (try? JSONEncoder().encode(out)) ?? Data("{}".utf8)
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

// --flow-test <radio|tver|subtitle> [--cancel]: run the FULL post-confirm
// flow of one dialog with SCRIPTED inputs (no NSAlert), wait for the spawn
// to register pid+log, hold briefly so QA can pgrep the waiting child, then
// stop it in-process via TaskManager.stop and print JSON evidence; exit 0.
// `--cancel` simulates dismissing the alert: nothing is written, nothing is
// spawned. Requires SNOWREC_ROOT (dev-mode contract) and honors HOME for the
// sandbox state/log paths.
struct FlowTestResult: Codable {
    let flow: String
    let entry: HistoryEntry?
    let stopped: Bool
    let status: String
    let name: String
}

/// "HH:MM" now + `seconds` (for the radio scripted start, Metis S2: now+2min
/// keeps the child in 等待启动 instead of rolling 21:00 to the next day).
func nowHHMM(after seconds: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date().addingTimeInterval(seconds))
}

/// Polls the persisted entry until the spawn closure recorded a pid
/// (launcher.py:141-145 parity), or nil on timeout.
@MainActor
func waitForPid(_ task: Task, store: StateStore, timeout: TimeInterval) async -> HistoryEntry? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let entry = DialogFlows.currentEntry(task, store: store), entry.pid != nil {
            return entry
        }
        try? await Swift.Task.sleep(for: .milliseconds(200))
    }
    return DialogFlows.currentEntry(task, store: store)
}

if CommandLine.arguments.contains("--flow-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--flow-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: "--flow-test"),
          flagIndex + 1 < args.count,
          !args[flagIndex + 1].hasPrefix("--") else {
        FileHandle.standardError.write(
            Data("--flow-test usage: --flow-test <radio|tver|subtitle> [--cancel]\n".utf8))
        exit(1)
    }
    let flowName = args[flagIndex + 1]
    let cancel = args.contains("--cancel")
    let delegate = AppDelegate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func json(_ value: FlowTestResult) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    if cancel {
        // Scripted cancel: like dismissing the NSAlert (nil inputs) — no
        // history entry, no spawn, no log file.
        print(json(FlowTestResult(flow: flowName, entry: nil, stopped: false, status: "cancelled", name: "-")))
        exit(0)
    }

    let task: Task?
    switch flowName {
    case "radio":
        task = DialogFlows.startRadio(
            delegate: delegate, station: "TBS",
            startAt: nowHHMM(after: 120), duration: "0.1", output: "radio_tbs.m4a")
    case "tver":
        task = DialogFlows.startTver(
            delegate: delegate, channel: "TBS",
            startAt: "21:00", endTime: "22:00", output: "tbs.mp4")
    case "subtitle":
        task = DialogFlows.startSubtitle(
            delegate: delegate, channel: "CX (富士)",
            timeStart: "19:00", timeEnd: "20:00", output: "sub_cx (富士)")
    default:
        FileHandle.standardError.write(
            Data("--flow-test: unknown flow '\(flowName)'\n".utf8))
        exit(1)
    }

    // startTver returns nil when the derived duration is invalid (nil/<=0,
    // launcher.py:650-651 cancel parity) — a scripted tver flow with a bad
    // start/end pair must fail loudly, not crash on the nil task.
    guard let task else {
        FileHandle.standardError.write(
            Data("--flow-test: startTver returned nil (invalid duration)\n".utf8))
        exit(1)
    }

    // Wait for the spawn closure to write pid+log into the persisted entry.
    // The child keeps running (等待启动 for radio/tver, active download for
    // subtitle) — QA pgrep's it during the hold window below.
    _ = await waitForPid(task, store: StateStore(), timeout: 5)

    // Hold window: QA observes the waiting child from another shell before
    // the in-process stop terminates it (todo 14 chain → 失败, no output
    // file since the recording never starts).
    try? await Swift.Task.sleep(for: .seconds(5))

    let stopped = await TaskManager.stop(task, store: StateStore())
    let entry = DialogFlows.currentEntry(task, store: StateStore())
    print(json(FlowTestResult(flow: flowName, entry: entry, stopped: stopped, status: task.status, name: task.name)))
    exit(0)
}

// --preset-test <new|rename|modify|delete|run>: scripted preset-management
// QA with NO dialogs (pattern of --flow-test). Operates on the persisted
// state:
//   new    — append the scripted tver preset (TBS / 21:00 / "60" / tbs.mp4 /
//            name "TBS 21:00") and print presets JSON
//   rename — rename the LAST preset to "NEW NAME" (missing → no-op, exit 0)
//   modify — ensure the scripted preset exists (create it when missing),
//            overwrite its fields in place (duration "45", output "tbs2.mp4"
//            — QA of edit-style persistence; toVideo stays nil since the
//            scripted preset is tver) and, if a radio preset named
//            "RADIO TV" exists, set toVideo=true (QA of to_video
//            round-trip); print presets JSON
//   delete — remove the LAST preset (missing → no-op, exit 0)
//   run    — ensure the scripted preset exists, spawn it through the real
//            runPreset pipeline (tver wrapper waits with --start-at 21:00),
//            hold 3s, stop via TaskManager.stop, print history entry +
//            presets JSON.
// `run` requires SNOWREC_ROOT (dev-mode contract, like --flow-test); the
// other modes only touch the state file and honor HOME for sandboxing.
struct PresetTestResult: Codable {
    let mode: String
    let presets: [Preset]
    let entry: HistoryEntry?
    let stopped: Bool
    let status: String
}

/// The scripted tver preset created by `--preset-test new`/`run`
/// (spec: TBS, 21:00, "60", tbs.mp4, name "TBS 21:00").
func scriptedTverPreset() -> Preset {
    Preset(name: "TBS 21:00", action: .tver, channel: "TBS",
           station: nil, timeStart: nil, timeEnd: nil,
           startAt: "21:00", duration: "60", output: "tbs.mp4")
}

if CommandLine.arguments.contains("--preset-test") {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: "--preset-test"),
          flagIndex + 1 < args.count,
          !args[flagIndex + 1].hasPrefix("--") else {
        FileHandle.standardError.write(
            Data("--preset-test usage: --preset-test <new|rename|modify|delete|run>\n".utf8))
        exit(1)
    }
    let mode = args[flagIndex + 1]
    let store = StateStore()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func json(_ value: PresetTestResult) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    func finish(_ result: PresetTestResult) -> Never {
        print(json(result))
        exit(0)
    }

    switch mode {
    case "new":
        var state = store.load()
        state.presets.append(scriptedTverPreset())
        store.save(state)
        finish(PresetTestResult(
            mode: "new", presets: store.load().presets,
            entry: nil, stopped: false, status: "-"))
    case "rename":
        var state = store.load()
        if let last = state.presets.indices.last {
            state.presets[last].name = "NEW NAME"
            store.save(state)
        }
        finish(PresetTestResult(
            mode: "rename", presets: store.load().presets,
            entry: nil, stopped: false, status: "-"))
    case "delete":
        var state = store.load()
        if let last = state.presets.indices.last {
            state.presets.remove(at: last)
            store.save(state)
        }
        finish(PresetTestResult(
            mode: "delete", presets: store.load().presets,
            entry: nil, stopped: false, status: "-"))
    case "modify":
        // In-place overwrite of the preset named "TBS 21:00" (QA of
        // edit-style persistence without the PresetFlows dialog). Ensures
        // the scripted tver preset exists when missing, then overwrites
        // duration/output. The scripted preset is tver, so toVideo stays
        // nil; if QA seeded a radio preset named "RADIO TV", toVideo is
        // flipped to true to exercise to_video persistence.
        var state = store.load()
        if let idx = state.presets.firstIndex(where: { $0.name == "TBS 21:00" }) {
            state.presets[idx].duration = "45"
            state.presets[idx].output = "tbs2.mp4"
        } else {
            state.presets.append(scriptedTverPreset())
            if let idx = state.presets.firstIndex(where: { $0.name == "TBS 21:00" }) {
                state.presets[idx].duration = "45"
                state.presets[idx].output = "tbs2.mp4"
            }
        }
        if let radioIdx = state.presets.firstIndex(where: { $0.name == "RADIO TV" }) {
            state.presets[radioIdx].toVideo = true
        }
        store.save(state)
        finish(PresetTestResult(
            mode: "modify", presets: store.load().presets,
            entry: nil, stopped: false, status: "-"))
    case "run":
        guard ProcessInfo.processInfo.environment["SNOWREC_ROOT"] != nil else {
            FileHandle.standardError.write(
                Data("--preset-test run requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
            exit(1)
        }
        // "create + run it": ensure the scripted preset exists (no duplicate
        // when a prior `new` already created it), then run the real pipeline.
        var state = store.load()
        if !state.presets.contains(where: { $0.name == "TBS 21:00" }) {
            state.presets.append(scriptedTverPreset())
            store.save(state)
        }
        guard let preset = store.load().presets.first(where: { $0.name == "TBS 21:00" }) else {
            FileHandle.standardError.write(
                Data("--preset-test run: preset not found after ensure\n".utf8))
            exit(1)
        }
        let delegate = AppDelegate()
        let task = PresetFlows.runPreset(delegate: delegate, preset: preset)
        _ = await waitForPid(task, store: StateStore(), timeout: 5)
        // Hold window: QA pgrep's the waiting tver_wrapper child here.
        try? await Swift.Task.sleep(for: .seconds(3))
        let stopped = await TaskManager.stop(task, store: StateStore())
        let entry = DialogFlows.currentEntry(task, store: StateStore())
        finish(PresetTestResult(
            mode: "run", presets: store.load().presets,
            entry: entry, stopped: stopped, status: task.status))
    default:
        FileHandle.standardError.write(
            Data("--preset-test: unknown mode '\(mode)'\n".utf8))
        exit(1)
    }
}

// --history-test <info|rerun|clear|stop-running>: scripted QA for the
// task-info / history-detail / clear-history flows (todo 20) with NO
// dialogs (pattern of --preset-test / --flow-test):
//   info         — print the task-info alert CONTENT lines for a fake
//                  running task (raw, unasserted — QA compares against
//                  launcher.py:608-613) plus a never-started variant (已运行: -)
//   rerun        — fresh sandbox: spawn a sleep-3 task via the real
//                  TaskManager path, wait for 成功; then rerun history[0]
//                  through the REAL rerunEntry pipeline and wait for the
//                  new head entry to reach 成功; print source + new head +
//                  oldPid (new entry must carry a NEW pid)
//   clear        — clear the history (post-确认 pipeline) and print the
//                  empty list
//   stop-running — spawn a sleep-60 task, run the REAL taskInfo stop path
//                  (HistoryFlows.stopTaskAndCleanup, no alert), print
//                  pid/stopped/status + remaining task count
// `rerun`/`stop-running` require SNOWREC_ROOT (they spawn, like
// --flow-test); `info`/`clear` only touch formatting/state and honor HOME.
struct HistoryTestResult: Codable {
    let mode: String
    let source: HistoryEntry?
    let head: HistoryEntry?
    let oldPid: Int?
    let history: [HistoryEntry]
    let pid: Int?
    let stopped: Bool
    let status: String
    let activeRemaining: Int
}

if CommandLine.arguments.contains("--history-test") {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: "--history-test"),
          flagIndex + 1 < args.count,
          !args[flagIndex + 1].hasPrefix("--") else {
        FileHandle.standardError.write(
            Data("--history-test usage: --history-test <info|rerun|clear|stop-running>\n".utf8))
        exit(1)
    }
    let mode = args[flagIndex + 1]
    let store = StateStore()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func json(_ value: HistoryTestResult) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    func finish(_ result: HistoryTestResult) -> Never {
        print(json(result))
        exit(0)
    }

    switch mode {
    case "info":
        // launcher.py:608-613 content lines: startedAt -3661s →
        // "1小时1分1秒" (elapsedLabel parity), logPath shown verbatim.
        let running = Task(
            name: "info-test",
            cmd: ["caffeinate", "/usr/bin/python3", "-c", "print('x')"])
        running.startedAt = Date().addingTimeInterval(-3661)
        running.logPath = "/tmp/snowrec-qa-home/.script_logs_dev/info-test.log"
        print("--- running task (elapsed 1小时1分1秒) ---")
        print(HistoryFlows.infoText(for: running))
        // launcher.py:606: no startedAt → "已运行: -"
        let neverStarted = Task(name: "info-test-2", cmd: ["caffeinate", "x"])
        print("--- never-started task (已运行: -) ---")
        print(HistoryFlows.infoText(for: neverStarted))
        exit(0)
    case "clear":
        HistoryFlows.clearHistoryData()
        finish(HistoryTestResult(
            mode: "clear", source: nil, head: nil, oldPid: nil,
            history: store.load().history, pid: nil, stopped: false,
            status: "-", activeRemaining: 0))
    case "rerun":
        guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
              !root.isEmpty else {
            FileHandle.standardError.write(
                Data("--history-test rerun requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
            exit(1)
        }
        // Fresh sandbox (empty history): script the first run — a sleep-3
        // task through the REAL TaskManager path, waiting for 成功. With
        // existing history (e.g. a seeded deploy-path entry for QA
        // failure), history[0] IS the rerun source and nothing is spawned.
        if store.load().history.isEmpty {
            let name = "history-test"
            let cmd = [
                "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
                "-c", "import time;time.sleep(3)",
            ]
            let task = Task(name: name, cmd: cmd)
            var state = store.load()
            let entry = HistoryEntry(label: name, cmd: cmd, status: "运行", pid: nil, log: nil)
            state.history.insert(entry, at: 0)
            task.historyEntry = entry
            store.save(state)
            let result = await TaskManager.start(task, store: store)
            if result.status != "成功" {
                FileHandle.standardError.write(
                    Data("--history-test rerun: first run failed (\(result.status))\n".utf8))
                exit(1)
            }
        }
        guard let source = store.load().history.first else {
            FileHandle.standardError.write(
                Data("--history-test rerun: no source entry\n".utf8))
            exit(1)
        }
        let oldPid = source.pid
        let delegate = AppDelegate()
        let rerunTask = HistoryFlows.rerunEntry(delegate: delegate, entry: source)
        // Wait for the rerun's head entry to reach 成功 — the spawn closure
        // writes pid, then the final status (launcher.py:141-160 parity).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let head = store.load().history.first, head.status == "成功" {
                finish(HistoryTestResult(
                    mode: "rerun", source: source, head: head, oldPid: oldPid,
                    history: store.load().history, pid: nil, stopped: false,
                    status: head.status, activeRemaining: 0))
            }
            try? await Swift.Task.sleep(for: .milliseconds(200))
        }
        // Timeout: the rerun's child is still running (long-running source
        // cmd, e.g. sleep-60) and rerunEntry spawns it on a detached
        // Swift.Task — stop it before exiting so the test never leaks a
        // process. (The first-run path above awaits TaskManager.start
        // directly, which BLOCKS until the child exits, so no leak is
        // possible on that early-exit path.)
        _ = await TaskManager.stop(rerunTask, store: store)
        FileHandle.standardError.write(
            Data("--history-test rerun: timed out waiting for 成功\n".utf8))
        exit(1)
    case "stop-running":
        guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
              !root.isEmpty else {
            FileHandle.standardError.write(
                Data("--history-test stop-running requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
            exit(1)
        }
        let name = "history-stop-test"
        let cmd = [
            "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
            "-c", "import time;time.sleep(60)",
        ]
        let task = Task(name: name, cmd: cmd)
        var state = store.load()
        let entry = HistoryEntry(label: name, cmd: cmd, status: "运行", pid: nil, log: nil)
        state.history.insert(entry, at: 0)
        task.historyEntry = entry
        store.save(state)
        let delegate = AppDelegate()
        delegate.tasks = [task]
        let spawned = Swift.Task { @MainActor in
            await TaskManager.start(task, store: store)
        }
        _ = await waitForPid(task, store: store, timeout: 5)
        // Hold window: QA pgrep's the sleeping child here.
        try? await Swift.Task.sleep(for: .seconds(2))
        let stopped = await HistoryFlows.stopTaskAndCleanup(delegate: delegate, task: task)
        _ = await spawned.value
        finish(HistoryTestResult(
            mode: "stop-running", source: nil, head: nil, oldPid: nil,
            history: store.load().history, pid: task.historyEntry?.pid,
            stopped: stopped, status: task.status,
            activeRemaining: delegate.tasks.count))
    default:
        FileHandle.standardError.write(
            Data("--history-test: unknown mode '\(mode)'\n".utf8))
        exit(1)
    }
}

// --killall-test: spawn TWO sleep-60 tasks through the REAL TaskManager
// spawn path, wait for both pids, then call AppDelegate.killAll() — the
// exact ⏹ 停止全部 pipeline (launcher.py:632-637) — and print
// {"stopped":[true,true],"activeRemaining":0}. QA then asserts both
// sleep-60 processes are dead (pgrep empty) and both sandbox state entries
// are 失败. Requires SNOWREC_ROOT (dev-mode contract, like --flow-test).
struct KillAllTestResult: Codable {
    let stopped: [Bool]
    let activeRemaining: Int
}

if CommandLine.arguments.contains("--killall-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--killall-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let store = StateStore()
    let delegate = AppDelegate()
    let cmd = [
        "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
        "-c", "import time;time.sleep(60)",
    ]
    // Two identical sleep-60 tasks through the real pipeline. Each start is
    // awaited on a detached Swift.Task — start blocks until the child exits,
    // which only happens via the killAll teardown below.
    for i in 0..<2 {
        let name = "killall-test-\(i)"
        let task = Task(name: name, cmd: cmd)
        var state = store.load()
        let entry = HistoryEntry(label: name, cmd: cmd, status: "运行中", pid: nil, log: nil)
        state.history.insert(entry, at: 0)
        task.historyEntry = entry
        store.save(state)
        delegate.tasks.append(task)
        _ = Swift.Task { @MainActor in
            await TaskManager.start(task, store: store)
        }
    }
    // Wait for both spawn closures to register pids (QA pgrep window).
    for task in delegate.tasks {
        _ = await waitForPid(task, store: store, timeout: 5)
    }
    try? await Swift.Task.sleep(for: .seconds(2))
    let stopped = await delegate.killAll()
    let out = KillAllTestResult(stopped: stopped, activeRemaining: delegate.tasks.count)
    let data = (try? JSONEncoder().encode(out)) ?? Data("{}".utf8)
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

// --quit-test: simulate the 退出 quit path. A normal app exit
// (NSApp.terminate / rumps.quit_application, launcher.py:303) does NOT kill
// child processes — so this flag spawns one sleep-60 task, waits for its
// pid, prints evidence, and exits(0) WITHOUT stopping it. The child is left
// orphaned, exactly like a real quit; QA verifies it survives (pgrep), then
// relaunches the app so OrphanRecovery (todo 10) kills the leftover process
// group and marks the entry 失败 — the full orphan-recovery cycle.
struct QuitTestResult: Codable {
    let pid: Int
    let childSurvives: Bool
}

if CommandLine.arguments.contains("--quit-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--quit-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let store = StateStore()
    let name = "quit-test"
    let cmd = [
        "caffeinate", CommandBuilder.pythonPath(repoRoot: root),
        "-c", "import time;time.sleep(60)",
    ]
    let task = Task(name: name, cmd: cmd)
    var state = store.load()
    let entry = HistoryEntry(label: name, cmd: cmd, status: "运行中", pid: nil, log: nil)
    state.history.insert(entry, at: 0)
    task.historyEntry = entry
    store.save(state)
    _ = Swift.Task { @MainActor in
        await TaskManager.start(task, store: store)
    }
    _ = await waitForPid(task, store: store, timeout: 5)
    // The quit: exit WITHOUT stopping the child (NSApp.terminate semantics).
    let out = QuitTestResult(pid: task.historyEntry?.pid ?? -1, childSurvives: true)
    let data = (try? JSONEncoder().encode(out)) ?? Data("{}".utf8)
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

// --dump-menu: build the menu tree from the persisted state (optionally with
// --fake-task "<name>" injected tasks, status 运行中, for QA of the active
// branch) and print it as an indented tree; exit 0, no GUI. The tree is the
// primary evidence that the menu matches launcher.py:255-306, since
// screenshots are blocked (no TCC).
if CommandLine.arguments.contains("--dump-menu") {
    let args = CommandLine.arguments
    var fakeTasks: [Task] = []
    if let i = args.firstIndex(of: "--fake-task"), i + 1 < args.count {
        fakeTasks.append(Task(name: args[i + 1], cmd: ["fake"]))
    }
    let menu = MenuBuilder.buildMenu(tasks: fakeTasks, state: StateStore().load())
    print(MenuBuilder.dumpTree(menu))
    exit(0)
}

// --menu-refresh-test: exercise the REAL 5s refresh timer end-to-end with
// no GUI (no NSApplication, no status item). Phase A injects a 运行中 task
// into the app's task list and pumps the main run loop ~6s so the timer
// fires once; the dump must contain the task item. Phase B flips the status
// to 成功, pumps another ~6s; the task item AND the "── 任务 ──" header must
// be gone (launcher.py:257 active filter) — proving the periodic rebuild,
// not a one-shot. Prints both dumps labeled, exit 0.
//
// Top-level code is an async context (SE-0343), where RunLoop.run(until:)
// is `noasync` — so the test lives in a plain @MainActor sync function.
@MainActor
func runMenuRefreshTest() {
    let delegate = AppDelegate()
    delegate.startRefreshTimer()

    // Phase A: task appears after the first 5s tick.
    let task = Task(name: "test", cmd: ["fake"])
    delegate.tasks = [task]  // Task init status = 运行中
    RunLoop.main.run(until: Date().addingTimeInterval(6))
    let dumpA = MenuBuilder.dumpTree(delegate.currentMenu ?? NSMenu())
    print("--- Phase A (after 5s tick, task 运行中) ---")
    print(dumpA)

    // Phase B: task completes -> filtered out on the next tick.
    task.status = "成功"
    RunLoop.main.run(until: Date().addingTimeInterval(6))
    let dumpB = MenuBuilder.dumpTree(delegate.currentMenu ?? NSMenu())
    print("--- Phase B (after next 5s tick, task 成功) ---")
    print(dumpB)
}
if CommandLine.arguments.contains("--menu-refresh-test") {
    runMenuRefreshTest()
    exit(0)
}

// --alert-probe-test: present the REAL radio-flow alert on a REAL screen and
// capture binary window-server evidence. The NSAlert accessory layouts were
// only ever verified through scripted --flow-test paths (which bypass
// NSAlert entirely), and an accessory app's un-activated runModal can put
// the alert behind the frontmost app (invisible / non-interactive). The
// probe launches the FULL app (applicationDidFinishLaunching sets the
// .accessory policy — mandatory for a correct NSApp.activate), presents
// DialogFlows.radioAlert() through the FIXED AlertPresenter.presentModal
// path, and while the modal session is on screen a background Swift.Task
// captures CGWindowListCopyWindowInfo windows owned by "LauncherApp"
// (owner + bounds are visible WITHOUT screen-recording TCC — only window
// NAMES are masked, todo 22 precedent), prints probeBefore/probeDuring,
// then dismisses via NSApp.abortModal() so runModal returns and the probe
// prints + exits. Asserts during >= 1 window with width >= 200 and height
// >= 100 (a sane alert); exit 0 on pass, 1 on failure. Requires
// SNOWREC_ROOT (dev-mode contract); honor HOME so QA sandboxes work.
struct AlertWindowSample {
    let layer: Int
    let x: Double, y: Double, w: Double, h: Double
    var line: String {
        "layer=\(layer) bounds=[\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))]"
    }
}

func captureLauncherWindows() -> [AlertWindowSample] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    var windows: [AlertWindowSample] = []
    for info in list {
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              owner == "LauncherApp" else { continue }
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        windows.append(AlertWindowSample(
            layer: info[kCGWindowLayer as String] as? Int ?? -1,
            x: bounds["X"] as? Double ?? 0,
            y: bounds["Y"] as? Double ?? 0,
            w: bounds["Width"] as? Double ?? 0,
            h: bounds["Height"] as? Double ?? 0))
    }
    return windows
}

/// Thread-safe verdict box — written by the detached capture task, read by
/// the main thread after presentModal returns (happens-after via the
/// abortModal wake).
final class ProbeVerdict: @unchecked Sendable {
    private let lock = NSLock()
    private var _passed = false
    func set(_ value: Bool) { lock.lock(); _passed = value; lock.unlock() }
    var passed: Bool { lock.lock(); defer { lock.unlock() }; return _passed }
}

/// Runs the probe from applicationDidFinishLaunching (the earliest point
/// where the .accessory activation policy is set). Exits the process.
///
/// The capture + dismissal run on a DETACHED task, not a MainActor task:
/// while runModal's modal event wait is blocking the main thread (mach-port
/// wait), the GCD main queue is NOT drained, so a `Swift.Task { @MainActor }`
/// continuation never resumes (observed: probe hung 60s). The detached task
/// runs on the global executor, and `NSApp.abortModal()` wakes the modal
/// event wait from any thread (it signals the modal session, not the main
/// queue) — routed through the ObjC runtime because the AppKit overlay marks
/// abortModal as MainActor-isolated. A watchdog hard-exits if the wake ever
/// fails so QA can never hang.
@MainActor
func runAlertProbe() -> Never {
    let before = captureLauncherWindows()
    print("probeBefore=\(before.count)")
    for window in before { print("probeBeforeWindow=\(window.line)") }

    let content = DialogFlows.radioAlert()
    content.alert.layout()
    let windowSize = content.alert.window.frame.size
    print("probeScreen=frame=\(NSScreen.main?.frame ?? .zero) scale=\(NSScreen.main?.backingScaleFactor ?? 0)")
    print("probeLayout=window=\(Int(windowSize.width))x\(Int(windowSize.height))")
    if let grid = content.alert.accessoryView {
        print("probeLayout=grid=\(Int(grid.frame.width))x\(Int(grid.frame.height))")
        print("probeLayout=gridFitting=\(Int(grid.fittingSize.width))x\(Int(grid.fittingSize.height))")
    }
    let buttons = content.alert.buttons
    print("probeButtons=\(buttons.map(\.title))")
    if let checkbox = content.checkbox {
        print("probeCheckbox=\(checkbox.title):\(checkbox.state == .on ? "on" : "off")")
    }
    let presetNew = PresetFlows.radioPresetAlert()
    print("probePresetCheckboxNew=\(presetNew.checkbox?.title ?? "-"):\(presetNew.checkbox?.state == .on ? "on" : "off")")
    var editPreset = Preset(
        name: "RADIO TV", action: .radio, channel: nil, station: "TBS",
        timeStart: nil, timeEnd: nil, startAt: "21:00", duration: "30",
        output: "radio_tbs.m4a", toVideo: nil)
    editPreset.toVideo = true
    let presetEdit = PresetFlows.radioPresetAlert(target: editPreset)
    print("probePresetCheckboxEdit=\(presetEdit.checkbox?.title ?? "-"):\(presetEdit.checkbox?.state == .on ? "on" : "off")")
    if let view = content.alert.window.contentView,
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/probe-alert.png"))
            print("probeLayout=pngWritten=/tmp/probe-alert.png")
        }
    }
    let verdict = ProbeVerdict()
    let app = NSApplication.shared
    let buttonTitles = buttons.map(\.title)
    // Snapshot the checkbox verdicts BEFORE the detached @Sendable task
    // (NSButton is not Sendable — d1805b0 buttons trap).
    let checkboxOk = content.checkbox?.title == "转换为视频" && content.checkbox?.state == .off
    let presetNewOk = presetNew.checkbox?.state == .off
    let presetEditOk = presetEdit.checkbox?.state == .on
    Swift.Task.detached {
        try? await Swift.Task.sleep(for: .seconds(3))
        let during = captureLauncherWindows()
        print("probeDuring=\(during.count)")
        for window in during { print("probeDuringWindow=\(window.line)") }
        let windowOk = during.contains { $0.w >= 200 && $0.h >= 100 }
        let buttonsOk = buttonTitles.count >= 2 && buttonTitles[0] == "确认"
        verdict.set(windowOk && buttonsOk && checkboxOk && presetNewOk && presetEditOk)
        _ = app.perform(NSSelectorFromString("abortModal"))
        try? await Swift.Task.sleep(for: .seconds(10))
        print("probeTimeout=abortModal did not wake the modal loop")
        exit(1)
    }
    _ = AlertPresenter.presentModal(content.alert)
    print(verdict.passed ? "probeAssert=pass" : "probeAssert=fail")
    print("probeDone=ok")
    exit(verdict.passed ? 0 : 1)
}

if CommandLine.arguments.contains("--alert-probe-test") {
    guard let root = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
          !root.isEmpty else {
        FileHandle.standardError.write(
            Data("--alert-probe-test requires SNOWREC_ROOT env var (dev-mode contract)\n".utf8))
        exit(1)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    NotificationCenter.default.addObserver(
        forName: NSApplication.didFinishLaunchingNotification,
        object: nil, queue: .main
    ) { _ in
        Swift.Task { @MainActor in
            runAlertProbe()
        }
    }
    app.run()
}

// Programmatic entry point: no storyboard, no windows.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

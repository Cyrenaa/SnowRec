import AppKit
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

// --dump-builders: build the three preset command arrays on FIXED inputs and
// print them as JSON on labeled lines, so external QA can compare
// element-by-element against arrays derived from launcher.py:418-447.
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

// --dump-notifications: print the CURRENT notification authorizationStatus
// (authorized / denied / notDetermined / provisional) on a labeled line and
// exit 0 without launching the GUI. External QA asserts on the label (plan
// M6: macOS caches authorization per bundle id — the PACKAGED binary carries
// com.snowrec.launcher; the debug binary would report a separate identity).
if CommandLine.arguments.contains("--dump-notifications") {
    await Notifications.dumpStatus()
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
        print(json(FlowTestResult(flow: flowName, entry: nil, stopped: false, status: "cancelled")))
        exit(0)
    }

    let task: Task
    switch flowName {
    case "radio":
        task = DialogFlows.startRadio(
            delegate: delegate, station: "TBS",
            startAt: nowHHMM(after: 120), duration: "0.1", output: "radio_tbs.m4a")
    case "tver":
        task = DialogFlows.startTver(
            delegate: delegate, channel: "TBS",
            startAt: "21:00", duration: "30", output: "tbs.mp4")
    case "subtitle":
        task = DialogFlows.startSubtitle(
            delegate: delegate, channel: "CX (富士)",
            timeStart: "19:00", timeEnd: "20:00", output: "sub_cx (富士)")
    default:
        FileHandle.standardError.write(
            Data("--flow-test: unknown flow '\(flowName)'\n".utf8))
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
    print(json(FlowTestResult(flow: flowName, entry: entry, stopped: stopped, status: task.status)))
    exit(0)
}

// --preset-test <new|rename|delete|run>: scripted preset-management QA with
// NO dialogs (pattern of --flow-test). Operates on the persisted state:
//   new    — append the scripted tver preset (TBS / 21:00 / "60" / tbs.mp4 /
//            name "TBS 21:00") and print presets JSON
//   rename — rename the LAST preset to "NEW NAME" (missing → no-op, exit 0)
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
            Data("--preset-test usage: --preset-test <new|rename|delete|run>\n".utf8))
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

// Programmatic entry point: no storyboard, no windows.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

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

// Programmatic entry point: no storyboard, no windows.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

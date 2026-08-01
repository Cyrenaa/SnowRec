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

// Programmatic entry point: no storyboard, no windows.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

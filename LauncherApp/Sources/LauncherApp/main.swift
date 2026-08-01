import AppKit

// Programmatic entry point: no storyboard, no windows.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

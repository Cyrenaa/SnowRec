import AppKit

/// Centralizes modal alert presentation for the accessory (LSUIElement)
/// menu-bar app.
///
/// The legacy launcher.py presented every dialog via `osascript display
/// dialog` — a SEPARATE system process whose windows are always frontmost
/// and interactive regardless of the rumps app's activation state. The Swift
/// rewrite presents NSAlert windows inside THIS process, which is an
/// accessory app (no Dock icon: `NSApp.setActivationPolicy(.accessory)` in
/// AppDelegate, `LSUIElement=true` in the packaged Info.plist) that the
/// system NEVER activates on its own. A bare `NSAlert.runModal()` can
/// therefore order the alert behind the frontmost app where it is invisible
/// and non-interactive (no key window — text fields cannot take input).
///
/// Fix: activate the app immediately before every modal session. All alert
/// presentations must go through `presentModal` — never call `runModal()`
/// directly.
@MainActor
enum AlertPresenter {

    /// Activates the app (bringing it to the foreground regardless of other
    /// apps) then runs the modal session. Returns the alert's button
    /// response.
    @discardableResult
    static func presentModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

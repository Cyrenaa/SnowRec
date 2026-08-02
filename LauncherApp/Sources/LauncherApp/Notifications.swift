import Foundation
import UserNotifications

/// Foreground banner presentation (plan L6): the delegate answers
/// `willPresent` with `[.banner, .sound]` so notifications show as banners
/// even while the app is in the foreground. `UNUserNotificationCenter.delegate`
/// is a weak (assign) property, so `Notifications` holds the strong reference.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Notification permission handling (todo 22).
///
/// - `setup()`: installs the foreground-banner delegate once at app launch
///   (idempotent).
/// - `requestAuthorizationIfNeeded()`: asks for `[.alert, .sound]` at most
///   ONCE per process run (flag guard), from the task-creation path — the
///   first task creation triggers the system prompt. Failure/denial is
///   swallowed silently: the app must never crash on permission state.
/// - `dumpStatus()`: prints the current `authorizationStatus` on a labeled
///   line for external QA (`--dump-notifications`).
///
/// All state is MainActor-isolated: callers are `TaskManager.start`
/// (@MainActor), `AppDelegate.applicationDidFinishLaunching` (@MainActor),
/// and the MainActor top-level code in main.swift.
@MainActor
enum Notifications {

    /// Strong reference to the installed delegate (center.delegate is weak).
    private static var delegate: NotificationDelegate?

    /// Exactly-once-per-process-run guard for `requestAuthorization`.
    private static var hasRequested = false

    /// Idempotent: installs the delegate on the first call.
    static func setup() {
        guard delegate == nil else { return }
        let d = NotificationDelegate()
        UNUserNotificationCenter.current().delegate = d
        delegate = d
    }

    /// Requests notification authorization at most once per process run.
    /// Any error (or the user's denial) is swallowed — plan L6: the app
    /// must never crash; todo 23 (delivery) is responsible for checking
    /// the status before posting.
    static func requestAuthorizationIfNeeded() async {
        guard !hasRequested else { return }
        hasRequested = true
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Prints `authorizationStatus=<...>` (authorized / denied /
    /// notDetermined / provisional) for external QA assertions.
    static func dumpStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let label: String
        switch settings.authorizationStatus {
        case .authorized: label = "authorized"
        case .denied: label = "denied"
        case .notDetermined: label = "notDetermined"
        case .provisional: label = "provisional"
        case .ephemeral: label = "ephemeral"
        @unknown default: label = "unknown"
        }
        print("authorizationStatus=\(label)")
    }
}

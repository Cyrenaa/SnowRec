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

    /// Posts the terminal-state banner for a finished task (todo 23).
    ///
    /// Called from `TaskManager.start` after the final status (成功/失败) has
    /// been written. Plan L6 contract:
    /// - title carries the task name with a 完成/失败 prefix;
    /// - body carries the status phrase + the log path (DEVNULL-degraded
    ///   tasks have no log — body is the phrase alone);
    /// - `authorizationStatus` is checked BEFORE `add` — anything but
    ///   `.authorized` is SILENT (plan acceptance: denied → no banner, no
    ///   error, no crash);
    /// - trigger nil = immediate delivery; identifier UUID per post (unique
    ///   per task completion);
    /// - `add` errors are swallowed.
    static func postCompletion(task: Task) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let success = task.status == "成功"
        let content = UNMutableNotificationContent()
        content.title = "\(success ? "完成" : "失败"): \(task.name)"
        if let logPath = task.logPath {
            content.body = "\(success ? "录制完成" : "录制失败")\n\(logPath)"
        } else {
            content.body = success ? "录制完成" : "录制失败"
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        _ = try? await center.add(request)
    }

    /// Prints every DELIVERED notification as
    /// `delivered=["<identifier>","<title>","<body>"]` (JSON-escaped, one
    /// line each — newlines in the body can never break the QA assertion
    /// line). `getDeliveredNotifications` is only callable inside the app
    /// process; `--dump-notifications` runs in it (dual-review note 1).
    /// Empty delivered queue → no lines.
    static func dumpDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let encoder = JSONEncoder()
        for notification in delivered {
            let parts = [
                notification.request.identifier,
                notification.request.content.title,
                notification.request.content.body,
            ]
            let text = (try? encoder.encode(parts))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            print("delivered=\(text)")
        }
    }
}

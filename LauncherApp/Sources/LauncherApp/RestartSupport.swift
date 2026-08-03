import AppKit
import Darwin

/// Relaunches the app — the Swift analog of launcher.py:310-320
/// `_restart_app` (Popen start_new_session + rumps.quit_application).
///
/// Two relaunch modes, decided by how the current process runs:
/// - "bundle": packaged as an .app — `NSWorkspace.shared.open` on the
///   bundle path (the macOS-native way to launch an app bundle).
/// - "reexec": bare debug binary — re-exec `CommandLine.arguments[0]` in
///   a NEW session (fork + setsid + execv, the exact Unix semantics of
///   Python's start_new_session=True), so the child survives this
///   process's termination and keeps the inherited environment
///   (SNOWREC_ROOT etc.).
///
/// Deliberately uses plain Foundation/Darwin (NOT swift-subprocess): the
/// relaunch is fire-and-forget — no stdout/stderr plumbing, no teardown —
/// so the subprocess library is unnecessary weight here.
@MainActor
enum RestartSupport {

    /// How the app is running + the path to relaunch.
    struct Decision {
        let mode: String
        let path: String
    }

    /// "bundle" when packaged (Bundle.main.bundlePath ends with ".app");
    /// otherwise "reexec" (CommandLine.arguments[0]).
    static func restartDecision() -> Decision {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return Decision(mode: "bundle", path: bundlePath)
        }
        return Decision(mode: "reexec", path: CommandLine.arguments[0])
    }

    /// Starts the relaunched copy, then terminates the current process.
    /// Never returns.
    static func performRestart() -> Never {
        let decision = restartDecision()
        switch decision.mode {
        case "bundle":
            // NSWorkspace launches the .app as a new process; the current
            // one terminates right after (quit_application parity).
            NSWorkspace.shared.open(URL(fileURLWithPath: decision.path))
        default:
            reexec(decision.path)
        }
        NSApp.terminate(nil)
        exit(0)
    }

    /// Popen(start_new_session=True) semantics on Darwin. Foundation's
    /// `Process` has NO session API on macOS (startNewSession exists only
    /// in the Linux Foundation) and fork() is unavailable in the Swift
    /// overlay, so this uses posix_spawn with POSIX_SPAWN_SETSID — the
    /// sanctioned equivalent that makes the child a NEW session leader
    /// (new process group, no controlling terminal). envp is built from
    /// `ProcessInfo.processInfo.environment` (SNOWREC_ROOT survives) —
    /// a NULL envp on macOS posix_spawn yields an EMPTY environment,
    /// NOT inheritance (verified empirically). The relaunch is
    /// fire-and-forget: no waitpid — the child is reparented to launchd
    /// when this process terminates. On spawn failure the parent simply
    /// terminates (the user can relaunch manually).
    private static func reexec(_ path: String) {
        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return }
        defer { posix_spawnattr_destroy(&attr) }

        let args = CommandLine.arguments.map { strdup($0) }
        let envVars: [String] = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
        let env: [UnsafeMutablePointer<CChar>?] = envVars.map { strdup($0) }
        defer {
            args.forEach { free($0) }
            env.forEach { free($0) }
        }
        var argv = args + [nil]
        var envp = env + [nil]

        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        posix_spawn(&pid, path, nil, &attr, &argv, &envp)
    }
}

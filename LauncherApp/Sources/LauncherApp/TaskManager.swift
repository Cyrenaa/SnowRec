import Foundation
import Subprocess
// System (swift-system) is a transitive dep of swift-subprocess; its types
// (FilePath / FileDescriptor) are used for log redirection and need an
// explicit import — the `public import System` inside swift-subprocess does
// not cross the package product boundary.
import System

/// Spawns and tracks a task's child process with log redirection,
/// mirroring launcher.py:116-163 `Task.start()`.
///
/// swift-subprocess 0.5 facts this file relies on (verified from the
/// checked-out source at LauncherApp/.build/checkouts/swift-subprocess/):
/// - `PlatformOptions().createSession` defaults to FALSE; it MUST be set to
///   true to mirror launcher.py:139 `start_new_session=True`, so pid == pgid
///   (todo 14's process-group teardown depends on this).
/// - The closure-based `run(configuration, input:output:error:body:)` blocks
///   until the subprocess terminates ("The subprocess must terminate before
///   this method returns", API.swift:228) — that IS the wait step.
/// - File redirection uses `.fileDescriptor(fd, closeAfterSpawningProcess:)`
///   (IO/Output.swift:202), NOT a pipe, so the 64 KiB pipe caveat does not
///   apply — nothing needs continuous draining.
/// - Passing the SAME fd for both stdout and stderr is safe: spawn's
///   `safelyCloseMultiple` dedups parent-side closes by descriptor value
///   (Configuration.swift:254-258), so the second wrapper only gets
///   `markAsClosed` instead of a double close.
/// - `.discarded` redirects to `/dev/null` (IO/Output.swift:42-63) — the
///   DEVNULL equivalent for the degraded path.
///
/// History persistence: `HistoryEntry` is a struct snapshot (todo 12
/// finding), so pid/log/status writes must go through StateStore explicitly.
/// The caller appends the entry to the persisted state BEFORE calling
/// `start` (launcher.py `_add_history`); `start` locates the entry by
/// (label, cmd) equality and mutates it — the struct-copy analog of
/// Python's shared-dict identity (launcher.py:141-160).
///
/// NOTE: `start` is @MainActor and BLOCKING (awaits process exit). GUI
/// callers (todos 16/18) must wrap it in `Swift.Task` — the bare `Task { }`
/// spelling resolves to the local Task class (name shadowing, see
/// Task.swift).
enum TaskManager {

    /// Outcome of a finished spawn, consumed by `--spawn-test` QA.
    struct SpawnResult: Sendable {
        let pid: Int
        let logPath: String?
        let exitCode: Int32
        let status: String
    }

    /// Lock-protected bridge between `start`'s spawn closure and `stop`
    /// (todo 14). The closure registers a teardown action that captures the
    /// concrete `Execution`; `stop` invokes it from outside the closure.
    /// swift-subprocess documents the Execution as valid only within the
    /// closure, but `teardown(using:)` is entirely pid-based (kill(pid,0)
    /// probe + SIGTERM/SIGKILL to -pid + a DispatchSource on the pid,
    /// Teardown.swift:268-277 / Subprocess+Unix.swift:103-111) — no stream
    /// access — so invoking it while the process is still running is safe.
    /// The handle is cleared by `start` (MainActor) right after the spawn
    /// returns, so `stop` can never reach a reaped pid.
    final class TerminationHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () async -> Void)?

        func register(_ action: @escaping @Sendable () async -> Void) {
            lock.lock()
            self.action = action
            lock.unlock()
        }

        /// Runs the registered teardown (SIGTERM to the process group →
        /// 5s grace → implicit SIGKILL). Returns false when nothing was
        /// registered yet (spawn is in its first microseconds).
        func runTeardown() async -> Bool {
            guard let action = takeAction() else { return false }
            await action()
            return true
        }

        /// NSLock is not usable from async contexts, so the critical section
        /// lives in this synchronous helper.
        private func takeAction() -> (@Sendable () async -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return action
        }
    }

    /// launcher.py:116-163 `Task.start()`: create the log file (or degrade
    /// to DEVNULL), spawn with the Homebrew-prepended PATH in the repo
    /// root, record pid+log, wait for exit, record the final status. Never
    /// throws — every failure path ends with status 失败 (launcher.py:149-150).
    @MainActor
    static func start(_ task: Task, store: StateStore) async -> SpawnResult {
        // Todo 22: the first task creation in this process requests
        // notification permission (system prompt); the flag guard makes
        // every later call a no-op, and denial is swallowed.
        await Notifications.requestAuthorizationIfNeeded()

        let startedAt = Date()
        task.startedAt = startedAt

        // launcher.py:119-125: mkdir -p LOG_DIR and open `{ts}_{safe}.log`.
        // ANY failure (e.g. LOG_DIR is a FILE) degrades to DEVNULL output,
        // the task still spawns, and the app never crashes.
        let logDir = LogCleanup.logDirectory
        var logPath: String? = nil
        var logFD: FileDescriptor? = nil
        do {
            try FileManager.default.createDirectory(
                at: logDir, withIntermediateDirectories: true)
            let fileName = LabelHelpers.logFileName(name: task.name, date: startedAt)
            logPath = logDir.appendingPathComponent(fileName).path
            logFD = try FileDescriptor.open(
                FilePath(logPath!), .writeOnly,
                options: [.create, .truncate], permissions: .ownerReadWrite)
            task.logPath = logPath
        } catch {
            // launcher.py:124-125: log_file = None -> subprocess.DEVNULL
            task.logPath = nil
        }

        // D13 runtime validation: the working directory must be the repo
        // root; when it cannot be resolved, print an error and exit(1).
        guard let repoRoot = RepoRoot.resolveRepoRoot() else {
            FileHandle.standardError.write(
                Data("[ERR] 无法解析仓库根目录（SNOWREC_ROOT 未设置）\n".utf8))
            exit(1)
        }

        // launcher.py:130-132: GUI apps inherit launchd's minimal PATH,
        // missing Homebrew bins (ffmpeg etc.), so prepend them.
        let homebrewBins = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        let path = homebrewBins + ":"
            + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

        var platformOptions = PlatformOptions()
        platformOptions.createSession = true  // pid == pgid (launcher.py:139)

        let config = Configuration(
            executable: .name(task.cmd.first ?? "caffeinate"),
            arguments: Arguments(Array(task.cmd.dropFirst())),
            environment: .inherit.updating(["PATH": path]),
            workingDirectory: FilePath(repoRoot),
            platformOptions: platformOptions
        )

        // Spawn + wait: the closure-based run blocks until the child exits.
        // The handle bridges the closure's Execution to `stop` (todo 14);
        // it is cleared right after run returns, so a stopped-by-handle pid
        // is never teardown'd after being reaped.
        let handle = TerminationHandle()
        task.terminationHandle = handle

        let termination: TerminationStatus
        do {
            if let logFD {
                termination = try await runSpawn(
                    config,
                    output: .fileDescriptor(logFD, closeAfterSpawningProcess: true),
                    error: .fileDescriptor(logFD, closeAfterSpawningProcess: true),
                    task: task, store: store, logPath: logPath, handle: handle)
            } else {
                termination = try await runSpawn(
                    config,
                    output: .discarded,
                    error: .discarded,
                    task: task, store: store, logPath: logPath, handle: handle)
            }
        } catch {
            // launcher.py:149-150: exception -> status 失败
            task.terminationHandle = nil
            task.status = "失败"
            writeState(task: task, store: store, status: "失败")
            if task.historyEntry != nil {
                await Notifications.postCompletion(task: task)
            }
            return SpawnResult(pid: -1, logPath: logPath, exitCode: -1, status: "失败")
        }
        task.terminationHandle = nil

        // launcher.py:146-148: rc == 0 -> 成功, anything else -> 失败
        let status = termination.isSuccess ? "成功" : "失败"
        task.status = status
        writeState(task: task, store: store, status: status)
        if task.historyEntry != nil {
            await Notifications.postCompletion(task: task)
        }
        return SpawnResult(
            pid: task.historyEntry?.pid ?? -1,
            logPath: logPath,
            exitCode: exitCode(from: termination),
            status: status)
    }

    /// Spawns `config` and waits for exit. The body closure runs right after
    /// spawn (before exit), records pid+log into history (launcher.py:141-145),
    /// and registers the teardown action for `stop`.
    @MainActor
    private static func runSpawn<O: OutputProtocol & ErrorOutputProtocol>(
        _ config: Configuration,
        output: O,
        error: O,
        task: Task,
        store: StateStore,
        logPath: String?,
        handle: TerminationHandle
    ) async throws -> TerminationStatus {
        let outcome = try await run(
            config,
            input: .none,
            output: output,
            error: error
        ) { execution in
            let pid = Int(execution.processIdentifier.value)
            task.historyEntry?.pid = pid
            if let logPath {
                task.historyEntry?.log = logPath
            }
            writeState(task: task, store: store, pid: pid, logPath: logPath)
            // todo 14: SIGTERM to the process group → 5s grace → implicit
            // SIGKILL to the group. createSession = true (set in `start`)
            // guarantees pid == pgid, so the launcher itself is never hit.
            handle.register { @Sendable in
                await execution.teardown(using: [
                    .gracefulShutDown(
                        toProcessGroup: true,
                        allowedDurationToNextStep: .seconds(5)),
                ])
            }
            return pid
        }
        return outcome.terminationStatus
    }

    /// Terminates a running task: SIGTERM to the process group, 5s grace,
    /// then implicit SIGKILL (launcher.py:165-172 `Task.kill()` parity —
    /// launcher.py sends SIGTERM to the process only; the group-wide
    /// teardown is strictly stronger, per plan D3). Status and the history
    /// entry flip to 失败 unconditionally (launcher.py:169-172), except when
    /// the task already finished naturally: the handle is nil then, so this
    /// is a no-op and the recorded status (成功) is left untouched.
    /// Never throws — a teardown on an already-dead process errors are
    /// swallowed inside teardown itself (kill(pid,0) probe, Teardown.swift:205).
    @MainActor
    static func stop(_ task: Task, store: StateStore) async -> Bool {
        guard let handle = task.terminationHandle else {
            return false  // no running process (launcher.py:166 no-op)
        }
        let stopped = await handle.runTeardown()
        task.terminationHandle = nil
        task.status = "失败"
        writeState(task: task, store: store, status: "失败")
        return stopped
    }

    /// Persists the given fields into the task's history entry (launcher.py
    /// 141-145 / 158-160 `_save_data` parity). Updates both the in-memory
    /// snapshot and the matching entry in the persisted state.
    ///
    /// Entry identity = the LOG PATH — the Swift analog of Python's
    /// shared-dict identity: it is unique per spawn (timestamp + safeName
    /// in the filename, launcher.py:121-122). Matching label+cmd alone
    /// would hit SIBLING entries when history holds two entries with the
    /// same label+cmd (a rerun creates exactly that), overwriting the
    /// older one's pid/log/status. Rules (no schema change):
    /// - pid/log write (logPath passed): the fresh entry still has
    ///   log == nil until THIS call writes it, so match the head-most
    ///   nil-log entry (insert order = the just-added entry); entries
    ///   carrying an older log are never touched.
    /// - status write (logPath nil): the entry now carries the task's own
    ///   log — match log == task.logPath (unique per spawn).
    /// - DEVNULL fallback (logPath and task.logPath both nil): log == nil,
    ///   head-most only — the same identity-like rule.
    private static func writeState(
        task: Task, store: StateStore,
        pid: Int? = nil, logPath: String? = nil, status: String? = nil
    ) {
        guard let entry = task.historyEntry else { return }
        if let pid { task.historyEntry?.pid = pid }
        if let logPath { task.historyEntry?.log = logPath }
        if let status { task.historyEntry?.status = status }
        // logPath != nil → pre-spawn entry (log not written yet);
        // logPath == nil → post-spawn entry identified by the task's log.
        let matchLog: String? = logPath != nil ? nil : task.logPath
        var state = store.load()
        var changed = false
        for i in state.history.indices
        where state.history[i].label == entry.label
            && state.history[i].cmd == entry.cmd
            && state.history[i].log == matchLog {
            if let pid { state.history[i].pid = pid; changed = true }
            if let logPath { state.history[i].log = logPath; changed = true }
            if let status { state.history[i].status = status; changed = true }
            // nil-log entries are not unique per se (DEVNULL fallback /
            // pre-spawn state): write only the head-most one.
            if matchLog == nil { break }
        }
        if changed { store.save(state) }
    }

    /// Python subprocess returncode semantics: exit codes are returned
    /// as-is, signal terminations as the NEGATED signal number.
    private static func exitCode(from status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): return code
        case .signaled(let signal): return -signal
        }
    }
}

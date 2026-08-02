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

    /// launcher.py:116-163 `Task.start()`: create the log file (or degrade
    /// to DEVNULL), spawn with the Homebrew-prepended PATH in the repo
    /// root, record pid+log, wait for exit, record the final status. Never
    /// throws — every failure path ends with status 失败 (launcher.py:149-150).
    @MainActor
    static func start(_ task: Task, store: StateStore) async -> SpawnResult {
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
        let termination: TerminationStatus
        do {
            if let logFD {
                termination = try await runSpawn(
                    config,
                    output: .fileDescriptor(logFD, closeAfterSpawningProcess: true),
                    error: .fileDescriptor(logFD, closeAfterSpawningProcess: true),
                    task: task, store: store, logPath: logPath)
            } else {
                termination = try await runSpawn(
                    config,
                    output: .discarded,
                    error: .discarded,
                    task: task, store: store, logPath: logPath)
            }
        } catch {
            // launcher.py:149-150: exception -> status 失败
            task.status = "失败"
            writeState(task: task, store: store, status: "失败")
            return SpawnResult(pid: -1, logPath: logPath, exitCode: -1, status: "失败")
        }

        // launcher.py:146-148: rc == 0 -> 成功, anything else -> 失败
        let status = termination.isSuccess ? "成功" : "失败"
        task.status = status
        writeState(task: task, store: store, status: status)
        return SpawnResult(
            pid: task.historyEntry?.pid ?? -1,
            logPath: logPath,
            exitCode: exitCode(from: termination),
            status: status)
    }

    /// Spawns `config` and waits for exit. The body closure runs right after
    /// spawn (before exit) and records pid+log into history — launcher.py:141-145.
    @MainActor
    private static func runSpawn<O: OutputProtocol & ErrorOutputProtocol>(
        _ config: Configuration,
        output: O,
        error: O,
        task: Task,
        store: StateStore,
        logPath: String?
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
            return pid
        }
        return outcome.terminationStatus
    }

    /// Persists the given fields into the task's history entry (launcher.py
    /// 141-145 / 158-160 `_save_data` parity). Updates both the in-memory
    /// snapshot and the matching entry in the persisted state.
    private static func writeState(
        task: Task, store: StateStore,
        pid: Int? = nil, logPath: String? = nil, status: String? = nil
    ) {
        guard let entry = task.historyEntry else { return }
        if let pid { task.historyEntry?.pid = pid }
        if let logPath { task.historyEntry?.log = logPath }
        if let status { task.historyEntry?.status = status }
        var state = store.load()
        var changed = false
        for i in state.history.indices
        where state.history[i].label == entry.label && state.history[i].cmd == entry.cmd {
            if let pid { state.history[i].pid = pid; changed = true }
            if let logPath { state.history[i].log = logPath; changed = true }
            if let status { state.history[i].status = status; changed = true }
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

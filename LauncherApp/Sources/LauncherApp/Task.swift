import Foundation

/// One running/scheduled task, mirroring launcher.py:105-176 `Task`.
///
/// NOTE: this class shadows Swift Concurrency's `Task` within this module
/// (the launcher.py name is kept verbatim). Do not use `Task { }` concurrency
/// syntax in this file or any file that imports it.
///
/// `historyEntry` is a snapshot copy of the matching entry in the persisted
/// state; todo 13 (spawn/process execution) is responsible for writing
/// updated pid/log/status back through StateStore, since a struct copy does
/// not propagate mutations on its own.
final class Task {
    /// User-visible task name (launcher.py:107).
    let name: String
    /// Full command line, always starting with "caffeinate" (launcher.py:108).
    let cmd: [String]
    /// Running state: initial "运行中", later "成功" / "失败" (launcher.py:110).
    var status: String
    /// When the task started (launcher.py:113, set by `start()` in T13).
    var startedAt: Date?
    /// Log file path under `~/.script_logs/` (launcher.py:114).
    var logPath: String?
    /// Snapshot of the persisted history entry (launcher.py:112).
    var historyEntry: HistoryEntry?
    /// Runtime handle for stopping the spawned process (todo 14); nil while
    /// no process is running (before spawn or after exit). Never persisted.
    var terminationHandle: TaskManager.TerminationHandle?

    init(name: String, cmd: [String]) {
        self.name = name
        self.cmd = cmd
        self.status = "运行中"
        self.startedAt = nil
        self.logPath = nil
        self.historyEntry = nil
    }

    /// launcher.py:174-176 `menu_title` property:
    /// `f"  {self.name}  [{self.status}]"` — two leading spaces, status in
    /// brackets.
    var menuTitle: String {
        "  \(name)  [\(status)]"
    }
}

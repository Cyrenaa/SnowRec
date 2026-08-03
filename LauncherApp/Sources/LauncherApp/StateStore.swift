import Foundation

/// Dev-isolated storage locations. The dev launcher must NEVER share state
/// or log files with the legacy rumps launcher (which uses
/// `~/.script_launcher.json` / `~/.script_logs`), so every file lives under
/// a `_dev`-suffixed name.
enum StoragePaths {
    /// JSON state file name (dev build).
    static let stateFileName = ".script_launcher_dev.json"
    /// Backup of the state file; written only after a successful parse.
    static let stateBackupFileName = ".script_launcher_dev.json.bak"
    /// Log directory name (dev build).
    static let logDirectoryName = ".script_logs_dev"
}

/// Loads and saves the state file with the same semantics as launcher.py:
/// tolerant loading (any failure yields an empty state, never a crash),
/// a `.bak` copy only after the loaded file parsed successfully, atomic
/// writes, and a 20-entry history cap on save. The dev launcher uses its
/// OWN state file (`.script_launcher_dev.json`, see `StoragePaths`) so it
/// never reads or overwrites the legacy launcher's `~/.script_launcher.json`.
final class StateStore: Sendable {

    /// Home directory with Path.home() semantics: the HOME environment
    /// variable wins (QA sandboxes rely on this), falling back to the user
    /// database. `FileManager.homeDirectoryForCurrentUser` alone does NOT
    /// honor HOME on macOS, so it cannot be used directly.
    private var homeDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Path of the JSON state file (dev-isolated from launcher.py).
    var fileURL: URL {
        homeDirectory.appendingPathComponent(StoragePaths.stateFileName)
    }

    /// Backup path; written only when the loaded file parsed successfully
    /// (launcher.py:192-200 parity).
    var backupURL: URL {
        homeDirectory.appendingPathComponent(StoragePaths.stateBackupFileName)
    }

    /// Loads the state file. Missing file, corrupt JSON, or decode errors
    /// all return an empty state and never throw.
    func load() -> StateFile {
        guard let data = try? Data(contentsOf: fileURL) else {
            return StateFile()
        }
        guard let state = try? JSONDecoder().decode(StateFile.self, from: data) else {
            return StateFile()
        }
        // Parse succeeded, so mirror launcher.py by copying the ORIGINAL
        // file bytes to the backup before applying the loaded data.
        try? data.write(to: backupURL, options: .atomic)
        return state
    }

    /// Saves the state atomically. History is truncated to 20 entries
    /// (launcher.py MAX_HISTORY / _add_history parity).
    func save(_ state: StateFile) {
        var state = state
        if state.history.count > 20 {
            state.history = Array(state.history.prefix(20))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

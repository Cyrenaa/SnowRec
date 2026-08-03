import Foundation

/// Startup log pruning, mirroring launcher.py `_cleanup_old_logs`
/// (lines 46-59) exactly: `.log` files in `~/.script_logs_dev` older than
/// 7 days are deleted on launch. Any failure is swallowed silently --
/// cleanup must never crash the app.
enum LogCleanup {

    /// Age cutoff: 7 days, matching launcher.py MAX_LOG_AGE_DAYS.
    static let maxLogAgeDays: TimeInterval = 7

    /// Home directory with Path.home() semantics: the HOME environment
    /// variable wins (QA sandboxes rely on this), falling back to the
    /// user database. `FileManager.homeDirectoryForCurrentUser` alone
    /// does NOT honor HOME on macOS (todo 9 finding), so it cannot be
    /// used directly.
    private static var homeDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Log directory path (`~/.script_logs_dev`, dev-isolated from the
    /// legacy launcher's `~/.script_logs`).
    static var logDirectory: URL {
        homeDirectory.appendingPathComponent(StoragePaths.logDirectoryName)
    }

    /// Deletes every `*.log` file whose modification time is older than
    /// 7 days. If the directory does not exist, returns immediately.
    /// Per-file OSErrors and any outer exception are swallowed
    /// (launcher.py 46-59 parity).
    static func pruneOldLogs(logDir: URL? = nil) {
        let dir = logDir ?? logDirectory
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let cutoff = Date().timeIntervalSince1970 - maxLogAgeDays * 86400
            let files = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension == "log" {
                do {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                    guard let mtime = values.contentModificationDate else { continue }
                    if mtime.timeIntervalSince1970 < cutoff {
                        try FileManager.default.removeItem(at: file)
                        print("[CLEAN] 删除旧日志 \(file.lastPathComponent)")
                    }
                } catch {
                    // Swallow per-file OSErrors (launcher.py except OSError: pass)
                }
            }
        } catch {
            // Swallow all outer exceptions (launcher.py except Exception: pass)
        }
    }
}

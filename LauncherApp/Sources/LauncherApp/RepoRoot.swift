import Foundation

/// Resolves the repository root directory (D13 contract).
///
/// Resolution order:
/// 1. `SNOWREC_ROOT` environment variable — dev/QA mode. `swift run` and
///    debug binaries MUST set it: their bundle lives under `.build/`, which
///    the 3-level walk would mis-resolve. Dump-mode QA enforces this.
/// 2. `SnowRecRepoRoot` Info.plist key — packaged app; the absolute repo
///    root path is injected by `scripts/package.sh` at package time.
/// 3. `Bundle.main.bundleURL` walked UP 3 levels — packaged layout
///    `LauncherApp/dist/LauncherApp.app`:
///    `deletingLastPathComponent()` x1 → `.../LauncherApp/dist`
///    x2 → `.../LauncherApp`   x3 → repo root (`script-dev/`),
///    because `LauncherApp/` sits directly under the repo root.
enum RepoRoot {

    /// Resolves the repo root, or nil when it cannot be determined (the
    /// caller decides whether to alert or exit).
    static func resolveRepoRoot() -> String? {
        if let env = ProcessInfo.processInfo.environment["SNOWREC_ROOT"],
           !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "SnowRecRepoRoot") as? String,
           !plist.isEmpty {
            return plist
        }
        return walkUp(from: Bundle.main.bundleURL, levels: 3).path
    }

    /// Path-traversal helper: drops `levels` trailing path components.
    private static func walkUp(from url: URL, levels: Int) -> URL {
        var current = url
        for _ in 0..<levels {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}

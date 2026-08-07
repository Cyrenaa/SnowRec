import Foundation

/// Stores the DeepSeek API key in a HOME-scoped file (~/.script_launcher_dev.key,
/// 0600, dev-suffix isolated like the state file). Shell env DEEPSEEK_API_KEY
/// takes precedence over this file at injection time; srt_translate.py's
/// --api-key flag wins over both.
enum KeyStore {
    static let fileName = ".script_launcher_dev.key"

    /// Home directory with Path.home() semantics (parity with
    /// StateStore.homeDirectory): the HOME environment variable wins (QA
    /// sandboxes rely on this), falling back to the user database.
    private static func homeDir() -> URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func path() -> URL {
        homeDir().appendingPathComponent(fileName)
    }

    /// nil when missing/empty; trims whitespace and newlines.
    static func load() -> String? {
        guard let data = FileManager.default.contents(atPath: path().path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Empty/whitespace input clears the file. Always chmod 0600.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
            return
        }
        let url = path()
        // createFile does not make intermediate directories — QA sandboxes
        // (HOME=/tmp/...) need the parent to exist.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data((trimmed + "\n").utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: path())
    }
}

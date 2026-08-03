import Foundation

/// Label and log-naming helpers with byte-for-byte parity to launcher.py.
///
/// These exist because the Swift rewrite must produce IDENTICAL strings to the
/// Python launcher for log file names, menu labels, and the task info dialog —
/// the dev launcher writes to its own `~/.script_logs_dev/` directory,
/// isolated from the legacy launcher's `~/.script_logs/`.
enum LabelHelpers {
    // MARK: safeName

    /// Parity with launcher.py:120 `re.sub(r"[^\w\u4e00-\u9fff-]+", "_", name)[:40]`.
    ///
    /// Python's `\w` is UNICODE-aware (letters + digits + underscore across all
    /// scripts, incl. CJK). NSRegularExpression's `\w` is ASCII-only, so the
    /// pattern must spell out the Unicode classes explicitly: letter (L),
    /// number (N), underscore, the CJK range, and a literal hyphen. Consecutive
    /// illegal characters collapse into a SINGLE "_" (the `+` quantifier), then
    /// the replaced string is truncated to 40 characters (Python applies `[:40]`
    /// AFTER substitution, not per-run).
    static func safeName(_ name: String) -> String {
        let pattern = "[^\\p{L}\\p{N}_\\u4e00-\\u9fff-]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return String(name.prefix(40))
        }
        let range = NSRange(name.startIndex..., in: name)
        let replaced = regex.stringByReplacingMatches(
            in: name,
            range: range,
            withTemplate: "_"
        )
        return String(replaced.prefix(40))
    }

    // MARK: logFileName

    /// Parity with launcher.py:121-122: `ts = started_at.strftime("%Y%m%d_%H%M%S")`
    /// then `f"{ts}_{safe_name}.log"`. Uses the en_US_POSIX locale and the
    /// CURRENT timezone (Python strftime formats in local time; the real
    /// `~/.script_logs_dev/` names were produced under `Asia/Tokyo`).
    static func logFileName(name: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ts = formatter.string(from: date)
        return "\(ts)_\(safeName(name)).log"
    }

    // MARK: endTimeLabel

    /// Parity with launcher.py:522-531 `_end_time`.
    ///
    /// Parses "HH:MM" into Int hour/minute parts, builds `today at HH:MM`
    /// (`datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)`),
    /// adds `float(durationMin)` minutes (which naturally rolls over midnight),
    /// and formats "%H:%M" zero-padded. Any parse error → "?".
    ///
    /// Notes on Python int()/float() parity:
    /// - int() accepts surrounding whitespace and a leading "+" — replicated
    ///   here so " 21 " / "+21" behave like Python (rejected otherwise).
    /// - float() accepts "0.1" (→ 6 seconds, dropped by %H:%M → "21:00") and
    ///   "1e3"; Swift Double() agrees on both. float() also accepts "inf"/"nan"
    ///   and "_" separators — intentionally not replicated (never hit in QA).
    /// - Python datetime.replace(hour=24) raises ValueError → "?"; the range
    ///   guard here mirrors that.
    static func endTimeLabel(startAt: String, durationMin: String) -> String {
        let parts = startAt.split(separator: ":")
        guard parts.count >= 2,
              let h = parsePythonInt(String(parts[0])),
              let m = parsePythonInt(String(parts[1])),
              (0...23).contains(h), (0...59).contains(m),
              let minutes = Double(durationMin.trimmingCharacters(in: .whitespaces))
        else {
            return "?"
        }

        // today at h:m — parity with datetime.now().replace(hour, minute, ...)
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = h
        comps.minute = m
        comps.second = 0
        guard let base = Calendar.current.date(from: comps) else { return "?" }

        let end = base.addingTimeInterval(minutes * 60)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: end)
    }

    /// Mimics Python `int(str)`: trims whitespace and tolerates a leading "+".
    private static func parsePythonInt(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") { t.removeFirst() }
        return Int(t)
    }

    // MARK: elapsedLabel

    /// Parity with launcher.py:603-604:
    /// `f"{elapsed // 3600}小时{(elapsed % 3600) // 60}分{elapsed % 60}秒"`.
    /// NO spaces, Chinese units.
    static func elapsedLabel(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return "\(h)小时\(m)分\(s)秒"
    }
}

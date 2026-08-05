import Foundation

/// Builds the exact `caffeinate` command arrays launcher.py constructs for
/// the three action types (launcher.py:418-448). Pure functions: the repo
/// root is passed in (caller resolves it via `RepoRoot.resolveRepoRoot()`),
/// which keeps every builder testable without process state.
enum CommandBuilder {

    /// launcher.py:61-67 `CHANNELS` — TVer live page URLs per channel name.
    static let channels: [String: String] = [
        "TBS": "https://tver.jp/live/tbs",
        "CX (富士)": "https://tver.jp/live/cx",
        "TX (东京)": "https://tver.jp/live/tx",
        "NTV (日テレ)": "https://tver.jp/live/ntv",
        "EX (朝日)": "https://tver.jp/live/ex",
    ]

    /// CHANNELS key order (launcher.py:61-67 — Python dicts preserve
    /// insertion order, Swift Dictionary does not; kept explicitly so the
    /// dialog popups list channels in the same order as launcher.py).
    static let channelOrder: [String] = [
        "TBS", "CX (富士)", "TX (东京)", "NTV (日テレ)", "EX (朝日)",
    ]

    /// launcher.py:69 `RADIO_STATIONS`.
    static let radioStations: [String] = [
        "TBS", "QRR", "FMT", "BAYFM78", "LFR", "JORF", "INT",
    ]

    /// launcher.py:27 `PYTHON = str(SCRIPT_DIR / ".venv" / "bin" / "python3")`.
    static func pythonPath(repoRoot: String) -> String {
        "\(repoRoot)/.venv/bin/python3"
    }

    // MARK: subtitle (launcher.py:418-426)

    /// `page_url = CHANNELS.get(p["channel"], "")` — unknown channels yield an
    /// EMPTY string element (launcher.py:419). `history` appends `"--history"`
    /// AFTER the `--output` pair (launcher.py:719-720 parity:
    /// `if history: cmd.append("--history")`).
    static func subtitleCommand(
        repoRoot: String,
        channel: String,
        timeStart: String,
        timeEnd: String,
        output: String,
        history: Bool = false
    ) -> [String] {
        let pageURL = channels[channel] ?? ""
        var cmd = [
            "caffeinate", pythonPath(repoRoot: repoRoot), "\(repoRoot)/download_vtt.py",
            "--tver-page", pageURL,
            "--time-start", timeStart,
            "--time-end", timeEnd,
            "--output", output,
        ]
        if history {
            cmd.append("--history")
        }
        return cmd
    }

    // MARK: radio (launcher.py:430-436)

    /// `duration` is passed through as-is (a plain String — never converted
    /// to a Float and re-formatted, so "30" stays "30", never "30.0").
    /// `toVideo` appends `"--to-video"` after the `-o <output>` pair
    /// (launcher.py parity: `if p.get("to_video"): cmd.append("--to-video")`).
    static func radioCommand(
        repoRoot: String,
        station: String,
        startAt: String,
        duration: String,
        output: String,
        toVideo: Bool = false
    ) -> [String] {
        var cmd = [
            "caffeinate", pythonPath(repoRoot: repoRoot), "\(repoRoot)/radiko_recorder.py",
            station,
            "--start-at", startAt,
            "-d", duration,
            "-o", output,
        ]
        if toVideo {
            cmd.append("--to-video")
        }
        return cmd
    }

    // MARK: tver (launcher.py:441-447)

    /// `page_url = CHANNELS.get(p["channel"], "")`; duration passed through
    /// as-is (same String passthrough as radio).
    static func tverCommand(
        repoRoot: String,
        channel: String,
        startAt: String,
        duration: String,
        output: String
    ) -> [String] {
        let pageURL = channels[channel] ?? ""
        return [
            "caffeinate", pythonPath(repoRoot: repoRoot), "\(repoRoot)/tver_wrapper.py",
            "--tver-page", pageURL,
            "--start-at", startAt,
            "-d", duration,
            "-o", output,
        ]
    }
}

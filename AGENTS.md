# AGENTS.md

Japanese TV/radio recording and subtitle extraction toolset (macOS). 6 standalone Python CLI scripts flat in the repo root — no package structure, no tests, no CI. Runtime: `.venv` (Python 3.14 + requests/m3u8/pycryptodome/playwright/rumps/pyobjc), external deps ffmpeg, Playwright chromium, caffeinate.

## STRUCTURE

```
script/
├── tver_wrapper.py        # TVer scheduled recording orchestration (scheduling layer)
├── tver_fetch_url.py      # Playwright scrape of TVer m3u8 stream URLs (low-level)
├── live_recorder_sub.py   # HLS recorder: TS video + VTT subtitles + SCTE35 ad skip (low-level)
├── download_vtt.py        # VTT subtitle download/merge/convert to SRT (6 modes)
├── radiko_recorder.py     # radiko radio recording (standalone, no internal deps)
├── launcher.py            # macOS menu-bar GUI (rumps), schedules the scripts above
├── README.md              # the only authoritative doc: all CLI args and usage
├── .venv/                 # virtualenv (do not touch)
└── .omo/                  # opencode session state (do not touch)
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| New TVer recording flow | `tver_wrapper.py` (orchestration) + `live_recorder_sub.py` (recording) |
| Subtitle timeline/window math | `download_vtt.py`: `parse_local_time_window`, `get_time_range_ms`, `shift_time_line` |
| Ad-skip logic | `live_recorder_sub.py`: `AdTracker` (SCTE35 daterange parsing) |
| radiko auth | `radiko_recorder.py`: `RadikoAuth` (auth1/auth2) |
| Age popup / cookie handling | `tver_fetch_url.py`: `capture_manifest` (async, ~line 268) |
| GUI scheduling / persistence | `launcher.py`: `LauncherApp` (rumps.App) |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `main_live_window` | function | download_vtt.py:954 | Phase 1 history trace-back + Phase 2 polling in parallel |
| `State` | class | download_vtt.py:227 | Cross-thread output state (Lock-protected) |
| `AdTracker` | class | live_recorder_sub.py:225 | SCTE35 ad-interval tracking |
| `VideoRecorder` | class | live_recorder_sub.py:353 | TS segment download + decrypt + ffmpeg merge |
| `SubtitleDownloader` | class | live_recorder_sub.py:559 | VTT segment download + time correction + SRT |
| `RadikoAuth` | class | radiko_recorder.py:49 | auth1/auth2 authentication + encrypted headers |
| `RadikoRecorder` | class | radiko_recorder.py:134 | AAC segment download + merge |
| `LauncherApp` | class | launcher.py:179 | rumps.App menu-bar scheduling |
| `Task` | class | launcher.py:105 | Subprocess management (caffeinate-wrapped) |

Call chain: `launcher → {tver_wrapper, download_vtt, radiko_recorder}`; `tver_wrapper → tver_fetch_url → live_recorder_sub`; `download_vtt → tver_fetch_url`. Scripts talk via `subprocess.run([sys.executable, ...])` + `--json` stdout protocol.

## CONVENTIONS

- **Scripts copy code instead of sharing modules**: `timestamp()`, `clean_text()`, `--start-at` next-day rollover logic are duplicated across files. Make changes in place; do NOT extract a shared library.
- **Logging**: each file has its own `timestamp()` returning `HH:MM:SS`; log prefix `[{ts}] <Chinese message>`; status tags `[OK] [SKIP] [ERR] [WARN] [ABORT] [DONE] [MERGE] [CLEAN]`. Errors go to `sys.stderr`.
- **Time**: all `--start-at`/`--time-start`/`--time-end` args are **system local time**, `HH:MM` or `HH:MM:SS`, past times auto-roll to next day. System timezone must be `Asia/Tokyo`.
- **CLI**: argparse with Chinese help; `-d` unit is minutes (float); video concurrency default 8, radiko default 4; default output `output_YYYYmmdd_HHMMSS.mp4`.
- **Temp files**: created in cwd with `.` prefix (`.vtt_files/`, `.radiko_*/`, `.live_*/`); kept only with `--keep`/`--save-segments`, otherwise rmtree'd in finally.
- **Retry**: downloads fixed 3 tries `for attempt in range(3)` + sleep(1); consecutive-failure threshold via module constant (e.g. `MAX_CONSECUTIVE_FAILURES=20` in download_vtt.py:292).
- **Concurrency**: `ThreadPoolExecutor` + `as_completed`, `shutdown(wait=True, cancel_futures=True)` in finally; stop flag via mutable closure `running = [True]` + SIGINT/SIGTERM handler.
- **Types**: Python 3.10+ union types `str | None`, most functions unannotated.
- **Network**: module-level `HEADERS` per file (Chrome UA); AES-128 via pycryptodome.

## ANTI-PATTERNS (THIS PROJECT)

- **Never run with system python3**: must use `.venv/bin/python` (system python3 lacks deps; README "Python path" note).
- **Never pass Japanese time directly**: args always take system local time; set `Asia/Tokyo` first (README "Time zone" note).
- **Never call low-level scripts directly**: `live_recorder_sub.py`, `tver_fetch_url.py` are invoked by upper layers (README "Normally not called directly" notes).
- **Never overwrite backups with corrupted content**: write `.json.bak` only after JSON parses successfully (launcher.py:189 area).
- **No test infrastructure**: do not invent test/lint/build/CI commands; existing `test_` prefixes are local variable names, not tests.

## UNIQUE STYLES

- Module docstrings embed copy-pasteable `.venv/bin/python xxx.py ...` usage examples.
- User-visible output and comments are all Chinese (English only in a few docstrings).
- `# ====` Chinese section banner comments separate code blocks.
- All launcher subprocess commands wrapped in `caffeinate` to prevent sleep.

## COMMANDS

```bash
# Setup (README doesn't list rumps/pyobjc, needed by launcher)
python3 -m venv .venv
.venv/bin/pip install requests m3u8 pycryptodome playwright rumps pyobjc-framework-Cocoa
.venv/bin/playwright install chromium   # plus system ffmpeg

# Run
caffeinate -s .venv/bin/python tver_wrapper.py --tver-page https://tver.jp/live/tbs --start-at 18:00 -d 115 -o out.mp4
.venv/bin/python download_vtt.py --tver-page https://tver.jp/live/tbs --time-start 20:00 --time-end 21:00
.venv/bin/python radiko_recorder.py TBS -d 30 -o radio.m4a
.venv/bin/python launcher.py            # menu-bar GUI daemon

# No test / lint / build / CI commands
```

## NOTES

- Git repo (remote: `github.com:Cyrenaa/SnowRec.git`); no requirements.txt, deps only recorded in README.
- `launcher.py` hardcodes `PYTHON = SCRIPT_DIR/.venv/bin/python3` (launcher.py:27), macOS-only (osascript/AppKit), not cross-platform.
- Long recordings must be wrapped in `caffeinate -s` to prevent Mac sleep.
- launcher persists `~/.script_launcher.json` (with `.bak` backup), logs to `~/.script_logs` (7-day cleanup, 20-entry history cap).
- Missing ffmpeg must degrade gracefully (catch `FileNotFoundError`, warn, continue) — never hard-fail.

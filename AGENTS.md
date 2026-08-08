# AGENTS.md

Japanese TV/radio recording and subtitle extraction toolset (macOS). 7 standalone Python CLI scripts flat in the repo root, plus a native Swift menu-bar launcher — no package structure, no tests, no CI. Runtime: `.venv` (Python 3.14 + requests/m3u8/pycryptodome/playwright/yt-dlp), external deps ffmpeg, Playwright chromium, caffeinate, Xcode CLT (for `swift build`).

## STRUCTURE

```
script/
├── tver_wrapper.py        # TVer scheduled recording orchestration (scheduling layer)
├── tver_fetch_url.py      # Playwright scrape of TVer m3u8 stream URLs (low-level)
├── live_recorder_sub.py   # HLS recorder: TS video + VTT subtitles + SCTE35 ad skip; --subtitle-url explicit subtitle stream (low-level)
├── download_vtt.py        # VTT subtitle download/merge/convert to SRT (6 modes)
├── radiko_recorder.py     # radiko radio recording; --to-video + --image-dir convert to MP4 (standalone, no internal deps)
├── srt_translate.py       # Japanese SRT → Chinese via DeepSeek API; needs DEEPSEEK_API_KEY (standalone)
├── youtube_recorder.py    # YouTube live recording via yt-dlp engine (standalone)
├── LauncherApp/           # native macOS menu-bar GUI (Swift/AppKit), schedules the scripts above
│   ├── Package.swift      # SwiftPM manifest (swift-subprocess 0.5, macOS 13+)
│   ├── Sources/LauncherApp/  # 19 .swift files (AppDelegate, TaskManager, MenuBuilder, AlertPresenter, RestartSupport, KeyStore, ...)
│   │   └── KeyStore.swift    # DeepSeek API key file I/O (~/.script_launcher_dev.key, 0600, HOME-scoped)
│   └── scripts/package.sh # assembles dist/SnowRec.app (ad-hoc signed)
├── pyproject.toml         # uv project metadata (no build-system); deps locked in uv.lock
├── README.md              # the only authoritative doc: all CLI args and usage
├── .venv/                 # uv-created virtualenv (do not touch)
└── .omo/                  # opencode session state (do not touch)
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| New TVer recording flow | `tver_wrapper.py` (orchestration) + `live_recorder_sub.py` (recording) |
| Subtitle timeline/window math | `download_vtt.py`: `parse_local_time_window`, `get_time_range_ms`, `shift_time_line`, `resolve_window_dates` |
| Subtitle merge / VTT time-line math | `download_vtt.py`: `merge_text`, `merge_time_lines`, `time_line_dur_ms` (also `live_recorder_sub.py`: `merge_text`) |
| Parallel past-window ID scan | `download_vtt.py`: no-playlist `phase2_forward` scan, 16-worker `ThreadPoolExecutor` (~line 1351) |
| Ad-skip logic | `live_recorder_sub.py`: `AdTracker` (SCTE35 daterange parsing) |
| radiko auth | `radiko_recorder.py`: `RadikoAuth` (auth1/auth2) |
| SRT translation | `srt_translate.py`: `parse_srt_lines` / `split_into_blocks` / `build_prompt` / `call_deepseek` / `translate_all` / `assemble_srt` |
| YouTube live recording | `youtube_recorder.py` (yt-dlp engine, standalone) |
| 翻译字幕 menu task wiring | LauncherApp: `CommandBuilder.translateCommand` (spawns `srt_translate.py`, output `<name>中.srt` next to input) + `DialogFlows.newTranslate`/`startTranslate` (NSOpenPanel SRT picker) + `MenuBuilder`/`AppDelegate` `newTranslateAction` (menu-only, not a preset type) |
| Age popup / cookie handling | `tver_fetch_url.py`: `capture_manifest` (async, ~line 268) |
| GUI scheduling / persistence | `LauncherApp/Sources/LauncherApp/AppDelegate.swift` (lifecycle + 5s rebuild) + `TaskManager.swift` (spawn/stop) + `StateStore.swift` (JSON state) |
| DeepSeek key config | `LauncherApp/Sources/LauncherApp/KeyStore.swift`: load/save/clear `~/.script_launcher_dev.key` (0600); `TaskManager.swift`: inject into spawned task env only when the app env lacks it |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `main_live_window` | function | download_vtt.py:954 | Phase 1 history trace-back + Phase 2 polling in parallel |
| `resolve_window_dates` | function | download_vtt.py:250 | Past-window rollover to tomorrow unless `--history` |
| `time_line_dur_ms` | function | download_vtt.py:82 | VTT time-line duration in ms |
| `merge_time_lines` | function | download_vtt.py:93 | Merge two VTT cue time lines |
| `merge_text` | function | download_vtt.py:110 / live_recorder_sub.py:169 | Merge VTT cue text (dedup) |
| `State` | class | download_vtt.py:227 | Cross-thread output state (Lock-protected) |
| `AdTracker` | class | live_recorder_sub.py:225 | SCTE35 ad-interval tracking |
| `VideoRecorder` | class | live_recorder_sub.py:353 | TS segment download + decrypt + ffmpeg merge |
| `SubtitleDownloader` | class | live_recorder_sub.py:559 | VTT segment download + time correction + SRT |
| `RadikoAuth` | class | radiko_recorder.py:49 | auth1/auth2 authentication + encrypted headers |
| `RadikoRecorder` | class | radiko_recorder.py:134 | AAC segment download + merge |
| `parse_srt_lines` | function | srt_translate.py:57 | Split SRT into (kind, content, terminator) records, byte-identical reassembly |
| `split_into_blocks` | function | srt_translate.py:86 | Split text lines into consecutive blocks of block_size |
| `build_prompt` | function | srt_translate.py:91 | Build the (system, user) prompt pair for a translation block |
| `call_deepseek` | function | srt_translate.py:116 | DeepSeek chat-completions POST; retries 429/5xx, AuthError on 401 |
| `translate_all` | function | srt_translate.py:250 | ThreadPoolExecutor block translation, ordered by text ordinal, stop flag |
| `assemble_srt` | function | srt_translate.py:295 | Reassemble SRT with translated text substituted in place |
| `translateCommand` | function | LauncherApp/Sources/LauncherApp/CommandBuilder.swift:118 | `caffeinate` + `.venv/bin/python srt_translate.py <input>`; output `<name>中.srt` next to the input |
| `youTubeCommand` | function | LauncherApp/Sources/LauncherApp/CommandBuilder.swift:127 | `caffeinate` + `.venv/bin/python youtube_recorder.py <url>`; optional `--start-at`/`-d` appended only when non-empty |
| `newYouTube` | function | LauncherApp/Sources/LauncherApp/DialogFlows.swift:188 | 其他功能 → YouTube 直播录制 URL dialog (empty URL = cancel) then `startYouTube` |
| `startYouTube` | function | LauncherApp/Sources/LauncherApp/DialogFlows.swift:207 | Spawns `youtube_recorder.py` via `youTubeCommand`; task name `YouTube <url-truncated-50>` |
| `makeUrlAlert` | function | LauncherApp/Sources/LauncherApp/DialogFlows.swift:405 | URL-text-field alert grid (no popup row; dummy NSPopUpButton for TaskAlertContent) |
| `newYouTubeAction` | function | LauncherApp/Sources/LauncherApp/AppDelegate.swift:262 | `@objc` action wiring 其他功能 → YouTube 直播录制 → `DialogFlows.newYouTube` |
| `AppDelegate` | class | LauncherApp/Sources/LauncherApp/AppDelegate.swift | NSStatusItem app lifecycle + 5s menu rebuild |
| `TaskManager` | enum | LauncherApp/Sources/LauncherApp/TaskManager.swift | Task spawn + log redirection + termination chain (swift-subprocess) |
| `MenuBuilder` | enum | LauncherApp/Sources/LauncherApp/MenuBuilder.swift | Status-menu tree (parity with the legacy rumps GUI) |
| `StateStore` | class | LauncherApp/Sources/LauncherApp/StateStore.swift | Atomic JSON persistence (`~/.script_launcher_dev.json` + `.bak`) |
| `OrphanRecovery` | enum | LauncherApp/Sources/LauncherApp/OrphanRecovery.swift | Kill orphan process groups + normalize history on launch |
| `Notifications` | enum | LauncherApp/Sources/LauncherApp/Notifications.swift | Completion/failure banners + permission handling |
| `CommandBuilder` | enum | LauncherApp/Sources/LauncherApp/CommandBuilder.swift | `caffeinate` command arrays (byte-identical to the legacy Python commands) |
| `LabelHelpers` | enum | LauncherApp/Sources/LauncherApp/Helpers.swift | safeName / logFileName / endTime / elapsed labels |
| `DialogFlows` | enum | LauncherApp/Sources/LauncherApp/DialogFlows.swift | New-task dialogs (subtitle / radio / TVer) |
| `PresetFlows` | enum | LauncherApp/Sources/LauncherApp/PresetFlows.swift | Preset create / rename / delete / run |
| `HistoryFlows` | enum | LauncherApp/Sources/LauncherApp/HistoryFlows.swift | Task-info + history detail / rerun / clear |
| `RestartSupport` | enum | LauncherApp/Sources/LauncherApp/RestartSupport.swift | App relaunch: bundle-mode `NSWorkspace.open` / reexec via `posix_spawn` + `POSIX_SPAWN_SETSID` |
| `AlertPresenter` | enum | LauncherApp/Sources/LauncherApp/AlertPresenter.swift | Centralized `NSAlert` modal presentation (activates app first; never bare `runModal`) |
| `KeyStore` | class | LauncherApp/Sources/LauncherApp/KeyStore.swift | Load/save/clear DeepSeek key in `~/.script_launcher_dev.key` (0600, HOME-scoped) |

Call chain: `LauncherApp → {tver_wrapper, download_vtt, radiko_recorder}`; `tver_wrapper → tver_fetch_url → live_recorder_sub`; `download_vtt → tver_fetch_url`. Scripts talk via `subprocess.run([sys.executable, ...])` + `--json` stdout protocol.

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
- **Never overwrite backups with corrupted content**: write `.json.bak` only after JSON parses successfully (StateStore.load).
- **No test infrastructure**: do not invent test/lint/build/CI commands; existing `test_` prefixes are local variable names, not tests.

## UNIQUE STYLES

- Module docstrings embed copy-pasteable `.venv/bin/python xxx.py ...` usage examples.
- User-visible output and comments are all Chinese (English only in a few docstrings).
- `# ====` Chinese section banner comments separate code blocks.
- All LauncherApp subprocess commands wrapped in `caffeinate` to prevent sleep.

## COMMANDS

```bash
# Setup (all 5 deps come from pyproject.toml; Swift build needs Xcode CLT)
brew install uv          # install uv if missing
uv python install 3.14   # install Python 3.14 if missing
uv sync
.venv/bin/playwright install chromium   # plus system ffmpeg

# Run
caffeinate -s .venv/bin/python tver_wrapper.py --tver-page https://tver.jp/live/tbs --start-at 18:00 -d 115 -o out.mp4
.venv/bin/python download_vtt.py --tver-page https://tver.jp/live/tbs --time-start 20:00 --time-end 21:00
.venv/bin/python radiko_recorder.py TBS -d 30 -o radio.m4a
.venv/bin/python youtube_recorder.py https://www.youtube.com/@NASA/live -d 30 -o youtube.mp4
DEEPSEEK_API_KEY=sk-... .venv/bin/python srt_translate.py input.srt   # requires an API key (env or --api-key)
cd LauncherApp && swift build           # build the menu-bar GUI
cd LauncherApp && ./scripts/package.sh  # package into dist/SnowRec.app (ad-hoc signed); must be re-run after any Swift change to update the shipped dist
open LauncherApp/dist/SnowRec.app   # run the menu-bar GUI daemon

# No test / lint / build / CI commands
```

## NOTES

- Git repo (remote: `github.com:Cyrenaa/SnowRec.git`); no requirements.txt, deps only recorded in README.
- `LauncherApp` resolves the repo root via `SNOWREC_ROOT` env → `SnowRecRepoRoot` Info.plist → bundle-path walk (`RepoRoot.swift`), then calls `<repoRoot>/.venv/bin/python3` directly (the uv-created venv). macOS-only (AppKit/NSStatusItem), not cross-platform; `swift run`/debug binaries require `SNOWREC_ROOT`.
- Long recordings must be wrapped in `caffeinate -s` to prevent Mac sleep.
- LauncherApp persists `~/.script_launcher_dev.json` (with `.bak` backup), logs to `~/.script_logs_dev` (7-day cleanup, 20-entry history cap). The `_dev` suffix isolates the dev launcher from the legacy launcher's `~/.script_launcher.json` / `~/.script_logs` (see `StoragePaths` in StateStore.swift).
- Missing ffmpeg must degrade gracefully (catch `FileNotFoundError`, warn, continue) — never hard-fail.
- LauncherApp 翻译字幕 menu task needs `DEEPSEEK_API_KEY`. TaskManager spawns children inheriting the parent environment, and injects the key from the config file (`~/.script_launcher_dev.key`, 0600, HOME-scoped, `_dev`-isolated) ONLY when the app's own environment lacks it, so a shell/launchctl `DEEPSEEK_API_KEY` always wins over the config file. Set the key once via the 设置 DeepSeek API Key... menu item (or write the file manually), or `export` it in the shell profile / `launchctl setenv DEEPSEEK_API_KEY <key>` for Finder/launchd launches. Inside `srt_translate.py` precedence is `--api-key` > env `DEEPSEEK_API_KEY` > error. The key is never committed or printed; the `--dump-key-status` QA flag reports only `keySource=env|config|none`. A 翻译字幕 task with no key still fails with `[ERR]`.

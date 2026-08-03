# SnowRec

A collection of CLI tools for recording Japanese TV and radio broadcasts, with subtitle extraction. Supports TVer live recording, HLS subtitle download/merge, and radiko radio recording.

## Prerequisites

```bash
brew install uv          # install uv if missing
uv python install 3.14   # install Python 3.14 if missing
uv sync                  # creates .venv and installs all deps from pyproject.toml
.venv/bin/playwright install chromium   # browser binaries for tver_fetch_url
```

All commands must be run with `.venv/bin/python`. On macOS, prefix long recordings with `caffeinate -s` to prevent sleep.

## Script Overview

```
tver_wrapper.py  ──→  tver_fetch_url.py  +  live_recorder_sub.py
download_vtt.py  ──→  tver_fetch_url.py (--tver-page mode only)
                       ffmpeg (VTT→SRT)
radiko_recorder.py    (standalone, no internal dependencies)
LauncherApp/     ──→  tver_wrapper.py / download_vtt.py / radiko_recorder.py
                      (macOS menu-bar GUI, section 6)
```

---

## 1. tver_wrapper.py — Scheduled TVer Recording

Schedules a recording, automatically resolves the TVer stream URL, and records video + subtitles. The subtitle URL resolved from the master manifest is passed to `live_recorder_sub.py` automatically via `--subtitle-url`; no manual step needed.

| Argument | Type | Description |
|----------|------|-------------|
| `--tver-page` | str (required) | TVer live page, e.g. `https://tver.jp/live/tbs` |
| `--start-at` | HH:MM | Scheduled start time (local time); defaults to immediate start |
| `-d, --duration` | float | Recording duration (minutes); stops automatically |
| `-o, --output` | str | Output video; defaults to `output_<timestamp>.mp4` |
| `-s, --subtitle` | str | Output subtitle; defaults to same name as video with `.srt` |
| `-c, --concurrency` | int (default 8) | Number of concurrent downloads |
| `-p, --poll-interval` | float (default 2.0) | Poll interval in seconds |
| `--fetch-timeout` | int (default 60) | Stream URL fetch timeout in seconds |

```bash
# Schedule TBS recording at 18:00 for 115 minutes
caffeinate -s .venv/bin/python tver_wrapper.py \
  --tver-page https://tver.jp/live/tbs \
  --start-at 18:00 -d 115 -o tbs.mp4

# Record 30 minutes immediately
.venv/bin/python tver_wrapper.py \
  --tver-page https://tver.jp/live/tbs \
  -d 30 -o tbs.mp4
```

---

## 2. download_vtt.py — Subtitle Download & Merge

Downloads VTT segments from the HLS subtitle stream and merges them, outputting VTT/SRT. Supports 6 modes.

| Argument | Type | Description |
|----------|------|-------------|
| `--tver-page` | str | TVer live page; resolves subtitle anchors automatically |
| `--start-url` | str | Starting VTT segment URL |
| `--end-url` | str | Ending VTT segment URL |
| `--url` | str | Reference URL (with `--before/--after` or `--time-start/--time-end`) |
| `--duration` | float | Duration (minutes) |
| `--before` | float | N minutes before the reference point |
| `--after` | float | N minutes after the reference point |
| `--time-start` | str | Start time `HH:MM` (**system local time**) |
| `--time-end` | str | End time `HH:MM` |
| `--output` | str | Output file; defaults to `merged_shifted.vtt` |
| `--no-srt` | flag | Skip SRT conversion |
| `--keep` | flag | Keep the temporary `vtt_files/` directory |
| `--fetch-timeout` | int (default 60) | Stream URL fetch timeout in seconds |

### The 6 Modes

```bash
# ① TVer auto-resolve (works for past / ongoing / upcoming windows)
.venv/bin/python download_vtt.py \
  --tver-page https://tver.jp/live/tbs \
  --time-start 20:00 --time-end 21:00

# ② Known ID range
.venv/bin/python download_vtt.py \
  --start-url "https://...manifest_1_100.vtt" \
  --end-url "https://...manifest_1_200.vtt"

# ③ Forward N minutes from the start point
.venv/bin/python download_vtt.py \
  --start-url "https://...manifest_1_100.vtt" --duration 30

# ④ Backward N minutes from the end point
.venv/bin/python download_vtt.py \
  --end-url "https://...manifest_1_200.vtt" --duration 30

# ⑤ Around a reference point
.venv/bin/python download_vtt.py \
  --url "https://...manifest_1_150.vtt" --before 10 --after 20

# ⑥ Known URL + time window
.venv/bin/python download_vtt.py \
  --url "https://...manifest_1_100.vtt" \
  --time-start 20:00 --time-end 21:00
```

Mode ① internal logic:
- Window **not started**: sleeps until 30 seconds before the start
- Window **in progress**: Phase 1 (trace back history) + Phase 2 (poll playlist for new segments) in parallel
- Window **finished**: falls back to a full forward scan

---

## 3. live_recorder_sub.py — Live Stream Recording

Low-level recorder. Downloads HLS TS video segments and VTT subtitle segments, auto-detects and skips SCTE35 ad breaks, and merges video to MP4 and subtitles to SRT.

| Argument | Type | Description |
|----------|------|-------------|
| `url` | str (positional) | m3u8 playlist URL |
| `-o, --output` | str | Video output; defaults to `output_<timestamp>.mp4` |
| `-s, --subtitle` | str | Subtitle output; defaults to same name with `.srt` |
| `--subtitle-url` | str | Subtitle m3u8 playlist URL (default: auto-detect) |
| `-c, --concurrency` | int (default 8) | Number of concurrent downloads |
| `-p, --poll-interval` | float (default 2.0) | Poll interval in seconds |
| `-d, --duration` | float | Recording duration (minutes) |
| `--no-best` | flag | Do not auto-select the highest quality |
| `--start-at` | HH:MM | Scheduled start time (local time) |

```bash
.venv/bin/python live_recorder_sub.py \
  "https://ssai-variants.streaks.jp/.../0.m3u8?...token..." \
  -d 30 -o my_video.mp4
```

Normally not called directly; `tver_wrapper.py` resolves the stream URL and passes it in.

---

## 4. radiko_recorder.py — Radio Recording

Records Japanese radiko radio stations. Authenticates via the native radiko API (auth1/auth2) and downloads/merges AAC audio segments.

| Argument | Type | Description |
|----------|------|-------------|
| `station` | str (positional) | Station ID, e.g. `TBS`, `QRR`, `FMT`, `BAYFM78` |
| `-o, --output` | str (required) | Output file; `.m4a` recommended |
| `-d, --duration` | float (required) | Recording duration (minutes) |
| `-c, --concurrency` | int (default 4) | Number of concurrent downloads |
| `--start-at` | HH:MM | Scheduled start time (local time) |
| `--to-video` | flag | After merging, combine with a same-name image (`../radio/pic/<name>.jpg`) into an MP4 video (requires ffmpeg) |
| `--image-dir` | str | Same-name image directory (default: `../radio/pic`, relative to cwd) |
| `--save-segments` | flag | Keep temporary segment files |

```bash
.venv/bin/python radiko_recorder.py TBS -d 30 -o radio.m4a

# Record a 21:00 broadcast and convert to MP4 with the same-name image
.venv/bin/python radiko_recorder.py TBS --start-at 21:00 -d 60 -o radio.m4a --to-video
```

`--to-video` behavior:
- Looks for a same-name image `<image_dir>/<output-stem>.jpg|jpeg|png` (default `<cwd>/../radio/pic/`), e.g. `../name.m4a` → `../radio/pic/name.jpg`
- Produces `<output-stem>.mp4` next to the audio file; the `.m4a` is kept
- Encoding: `libx264 ultrafast + stillimage + crf 28`, input/output both 5 fps (static image; ~10 s for a 30-min broadcast on Apple Silicon)
- Skips gracefully when ffmpeg or the image is missing (the recording itself is unaffected)

---

## 5. tver_fetch_url.py — Stream URL Fetching

Opens a TVer live page in a headless Playwright browser, handles the age-verification popup and cookie banner automatically, and captures the HLS master manifest URL.

| Argument | Type | Description |
|----------|------|-------------|
| `tver_url` | str (positional) | TVer live page URL |
| `--timeout` | int (default 60) | Maximum wait in seconds |
| `--json` | flag | Output JSON (with `video_url` and `subtitle_url`) |

```bash
.venv/bin/python tver_fetch_url.py https://tver.jp/live/tbs --timeout 60 --json
```

Normally not called directly; invoked automatically by `tver_wrapper.py` and `download_vtt.py`.

---

## 6. LauncherApp — Menu-Bar Launcher (Swift)

A native macOS menu-bar app (Swift/AppKit: NSStatusItem + NSMenu) that schedules recordings through the scripts above: new subtitle / radio / TVer tasks, presets (收藏), history rerun, stop-all, orphan-process recovery, and completion / failure system notifications. It replaces the old rumps-based Python GUI.

**Requirements**: Xcode Command Line Tools (for `swift build`; install with `xcode-select --install`), plus the Python side from Prerequisites (`uv sync` + `.venv/bin/playwright install chromium`).

```bash
# Build (from the repo root)
cd LauncherApp && swift build

# Package into an ad-hoc signed .app (release build → dist/LauncherApp.app)
cd LauncherApp && ./scripts/package.sh

# Run
open LauncherApp/dist/LauncherApp.app
```

The app appears as a ⛄️ status item in the menu bar (no Dock icon). State persists to `~/.script_launcher_dev.json` (with `.bak` backup); logs go to `~/.script_logs_dev` (7-day cleanup, 20-entry history cap). These dev-suffixed files are isolated from the legacy rumps launcher's `~/.script_launcher.json` / `~/.script_logs`, so the two can run side by side.

**Menu features**:

| Item | Description |
|------|-------------|
| `📝 下载字幕` / `📻 录制广播` / `📺 录制 TVer` | Start a task from a single form dialog: channel/station is a drop-down, parameters are input boxes, and the radio-to-MP4 option is a 转换为视频 checkbox (equivalent to `--to-video`, needs a same-name image). Presets first ask for the type, then show the same form |
| `⭐ 收藏` | Presets: 新建收藏 / 管理收藏, plus clickable preset entries to run them. 修改 re-runs the full creation flow with the current values pre-filled, then overwrites the preset in place |
| `🕐 最近` | Recent tasks with status; re-run a task or view its command/log |
| `⏹ 停止全部` | Terminate all running tasks (shown only while tasks are active) |
| `🔄 重启` | Restart the app; warns first when tasks are running (a relaunch kills leftover tasks via orphan recovery) |
| `退出` | Quit |

> **Deploy copy**: the deploy copy at `/Users/wyn/Documents/script/` (a separate git repo) is NOT auto-synced. After this repo switches its launcher to the Swift app, sync the deploy copy yourself.

---

## Typical Workflows

**Schedule a TVer program recording**
```bash
caffeinate -s .venv/bin/python tver_wrapper.py \
  --tver-page https://tver.jp/live/tbs \
  --start-at 21:00 -d 60 -o tbs.mp4
```

**Extract subtitles of an aired program**
```bash
.venv/bin/python download_vtt.py \
  --tver-page https://tver.jp/live/tbs \
  --time-start 20:00 --time-end 21:00
```

**Record a radiko broadcast**
```bash
.venv/bin/python radiko_recorder.py TBS -d 30 -o radio.m4a
```

## Notes

- **Time zone**: all `--time-start`/`--time-end`/`--start-at` arguments use system local time. Set the system time zone to `Asia/Tokyo` (UTC+9) to input Japanese time directly.
- **ffmpeg**: VTT→SRT conversion, segment merging, and `--to-video` conversion depend on ffmpeg; install it beforehand.
- **Python path**: always use `.venv/bin/python`; the system python3 lacks the required dependencies.

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
srt_translate.py      (standalone, DeepSeek API)
youtube_recorder.py   (standalone, yt-dlp)
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
| `--history` | flag | 窗口已过时直接回看下载历史字幕（默认顺延到明天同一时段） |
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
- Window **already past**: rolls forward to the same time tomorrow by default; pass `--history` to scan the past window directly

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

Normally not called directly; invoked automatically by `tver_wrapper.py` and `download_vtt.py`. If the Playwright Chromium browser binary is missing (e.g. after a playwright upgrade bumped the required build), it auto-runs `playwright install chromium` and retries once — no manual step needed.

---

## 6. LauncherApp — Menu-Bar Launcher (Swift)

A native macOS menu-bar app (Swift/AppKit: NSStatusItem + NSMenu) that schedules recordings through the scripts above: new subtitle / radio / TVer tasks, presets (收藏), history rerun, stop-all, orphan-process recovery, and completion / failure system notifications. It replaces the old rumps-based Python GUI.

**Requirements**: Xcode Command Line Tools (for `swift build`; install with `xcode-select --install`), plus the Python side from Prerequisites (`uv sync` + `.venv/bin/playwright install chromium`).

```bash
# Build (from the repo root)
cd LauncherApp && swift build

# Package into an ad-hoc signed .app (release build → dist/SnowRec.app)
cd LauncherApp && ./scripts/package.sh

# Run
open LauncherApp/dist/SnowRec.app
```

The app appears as a ❄️ status item in the menu bar (no Dock icon). State persists to `~/.script_launcher_dev.json` (with `.bak` backup); logs go to `~/.script_logs_dev` (7-day cleanup, 20-entry history cap). These dev-suffixed files are isolated from the legacy rumps launcher's `~/.script_launcher.json` / `~/.script_logs`, so the two can run side by side.

**Menu features**:

| Item | Description |
|------|-------------|
| `📝 下载字幕` / `📻 录制广播` / `📺 录制 TVer` | Start a task from a single form dialog: channel/station is a drop-down, parameters are input boxes, and the radio-to-MP4 option is a 转换为视频 checkbox (equivalent to `--to-video`, needs a same-name image). The subtitle form also has a 历史字幕 checkbox (equivalent to `--history`, for scanning an already-past window). The TVer form takes 开始时间 and 结束时间, computing the recording duration from the two. Presets first ask for the type, then show the same form |
| `翻译字幕` | Pick an already timeline-adjusted SRT file (NSOpenPanel); runs `srt_translate.py`, output `<name>中.srt` next to the input; needs the DeepSeek key (see below); menu task only, not a preset |
| `其他功能` | Submenu: 录制 YouTube 直播 (URL + 可选开始时间/时长/输出文件名); future features slot in as more sub-items |
| `⭐ 收藏` | Presets: 新建收藏 / 管理收藏, plus clickable preset entries to run them. 修改 re-runs the full creation flow with the current values pre-filled, then overwrites the preset in place |
| `🕐 最近` | Recent tasks with status; re-run a task or view its command/log |
| `⏹ 停止全部` | Terminate all running tasks (shown only while tasks are active) |
| `🔄 重启` | Restart the app; warns first when tasks are running (a relaunch kills leftover tasks via orphan recovery) |
| `退出` | Quit |

TVer presets store the 结束时间 value as `end_time` alongside the computed duration, so re-running a preset restores the same recording window. Editing a TVer preset re-derives the 结束时间 default from the stored start + duration (a custom stored `end_time` is no longer auto-shown, though it is still saved on confirm).

**DeepSeek key for translation**: the 翻译字幕 menu task runs `srt_translate.py`, which needs a DeepSeek API key. Set it once with the `设置 DeepSeek API Key...` menu item (or write `~/.script_launcher_dev.key` manually, 0600 permissions); the file is HOME-scoped and `_dev`-suffixed, so it is isolated from the legacy launcher. The key then works for Finder, launchd, and terminal launches alike. TaskManager spawns child scripts inheriting the parent environment, and injects the key from the config file only when the app's own environment lacks it, so a shell-profile `export DEEPSEEK_API_KEY="sk-..."` or `launchctl setenv DEEPSEEK_API_KEY sk-...` takes precedence over the config file. Inside `srt_translate.py`, `--api-key` wins over the env var. The key is never committed or printed; the `--dump-key-status` QA flag reports only `keySource=env|config|none`. A 翻译字幕 task with no key fails with `[ERR]`.

> **Deploy copy**: the deploy copy at `/Users/wyn/Documents/script/` (a separate git repo) is NOT auto-synced. After this repo switches its launcher to the Swift app, sync the deploy copy yourself.

---

## 7. srt_translate.py — SRT Subtitle Translation to Chinese (DeepSeek API)

Translates a Japanese SRT subtitle file into Chinese via the DeepSeek chat-completions API. Only subtitle text lines are translated; sequence numbers, timestamps, and blank lines are reassembled byte-identically (original line endings preserved). The output defaults to the input path with "中" inserted before the extension, so `260804.srt` becomes `260804中.srt` in the same directory.

| Argument | Type | Description |
|----------|------|-------------|
| `input` | str (positional) | Input SRT file path |
| `-o, --output` | str | Output file path; defaults to input name with "中" before the extension |
| `--model` | str (default `deepseek-v4-flash`) | DeepSeek model name |
| `--block-size` | int (default 100) | Text lines sent per translation batch |
| `-c, --concurrency` | int (default 4) | Number of concurrent translation batches |
| `--temperature` | float (default 0.2) | Sampling temperature |
| `--api-key` | str | DeepSeek API key; overrides the `DEEPSEEK_API_KEY` env var |
| `--base-url` | str (default `https://api.deepseek.com`) | DeepSeek API base URL |
| `--max-retries` | int (default 3) | Max retries per request on failure |

This is the first script that requires an API key. Provide it via the `DEEPSEEK_API_KEY` environment variable or the `--api-key` flag. The key is a secret and must never be committed (see `.gitignore`).

```bash
# Set the key first (alternatively pass --api-key)
export DEEPSEEK_API_KEY="sk-your-key"

# Translate; output lands in the same dir as 260804中.srt
.venv/bin/python srt_translate.py 260804.srt

# Faster: 8 concurrent batches of 50 lines each
.venv/bin/python srt_translate.py 260804.srt -c 8 --block-size 50
```

Exit code is 0 on success, even when some blocks fall back to the original text (each fallback logs `[WARN]`). Exit code is 1 on fatal errors: missing API key, missing input file, `-o` equal to the input, or undecodable input bytes.

---

## 8. youtube_recorder.py — YouTube 直播录制

Standalone script that records a YouTube LIVE stream via the yt-dlp engine. Supports scheduled start (`--start-at`), timed auto-stop (`-d`), DVR playback from the live start (`--live-from-start` on by default), and a cookies fallback.

| Argument | Type | Description |
|----------|------|-------------|
| `url` | str (positional) | YouTube 直播地址 (watch?v= / /live / @channel/live) |
| `-o, --output` | str | 输出视频路径 (默认: output_时间戳.mp4) |
| `-d, --duration` | float | 录制时长 (分)，到时自动停止 (缺省: 录到直播结束) |
| `--start-at` | HH:MM | 延迟到指定时间开始录制 (今日当地时间) |
| `--no-live-from-start` | flag | 不从直播开头回看, 从当前时间开始录制 (默认: 直播开头回看) |
| `--cookies` | str | 浏览器导出的 cookies 文件路径 (PO Token/地区兜底) |
| `--wait-for-video` | float | 等待预约直播开播的秒数 (超时则失败) |

```bash
# Record immediately for 60 minutes
.venv/bin/python youtube_recorder.py <URL> -d 60 -o out.mp4

# Schedule a 21:00 recording for 60 minutes
caffeinate -s .venv/bin/python youtube_recorder.py <URL> --start-at 21:00 -d 60 -o out.mp4

# Use browser-exported cookies as a fallback
.venv/bin/python youtube_recorder.py <URL> -d 60 --cookies cookies.txt -o out.mp4
```

Notes:
- **时区**: `--start-at` uses system local time (Asia/Tokyo), past times roll to tomorrow — same convention as the other scripts.
- **caffeinate**: prefix long recordings with `caffeinate -s` to prevent Mac sleep.
- **live-from-start**: DVR 回看默认开启 (`--no-live-from-start` 关闭)，受 YouTube DVR 限制，最长约 120 小时。
- **PO Token**: HLS 直播无需 PO Token；遇 403/无格式时用 `--cookies`（tv client 免 token）；完整 YouTube 支持需 deno + yt-dlp-ejs（按需）。
- **ffmpeg**: 用于多流合并，缺失时告警并继续录制（降级）。

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

**Translate a subtitle file into Chinese**
```bash
export DEEPSEEK_API_KEY="sk-your-key"
.venv/bin/python srt_translate.py tbs.srt
```

## Notes

- **Time zone**: all `--time-start`/`--time-end`/`--start-at` arguments use system local time. Set the system time zone to `Asia/Tokyo` (UTC+9) to input Japanese time directly.
- **ffmpeg**: VTT→SRT conversion, segment merging, and `--to-video` conversion depend on ffmpeg; install it beforehand.
- **Python path**: always use `.venv/bin/python`; the system python3 lacks the required dependencies.

# SnowRec

A collection of CLI tools for recording Japanese TV and radio broadcasts, with subtitle extraction. Supports TVer live recording, HLS subtitle download/merge, and radiko radio recording.

## Prerequisites

```bash
python3 -m venv .venv
.venv/bin/pip install requests m3u8 pycryptodome playwright
.venv/bin/playwright install chromium
```

All commands must be run with `.venv/bin/python`. On macOS, prefix long recordings with `caffeinate -s` to prevent sleep.

## Script Overview

```
tver_wrapper.py  ──→  tver_fetch_url.py  +  live_recorder_sub.py
download_vtt.py  ──→  tver_fetch_url.py (--tver-page mode only)
                       ffmpeg (VTT→SRT)
radiko_recorder.py    (standalone, no internal dependencies)
```

---

## 1. tver_wrapper.py — Scheduled TVer Recording

Schedules a recording, automatically resolves the TVer stream URL, and records video + subtitles.

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
| `--save-segments` | flag | Keep temporary segment files |

```bash
.venv/bin/python radiko_recorder.py TBS -d 30 -o radio.m4a

# Schedule a 21:00 recording
.venv/bin/python radiko_recorder.py TBS --start-at 21:00 -d 60 -o radio.m4a
```

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
- **ffmpeg**: VTT→SRT conversion and segment merging depend on ffmpeg; install it beforehand.
- **Python path**: always use `.venv/bin/python`; the system python3 lacks the required dependencies.

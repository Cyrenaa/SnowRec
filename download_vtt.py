#!/usr/bin/env python3
import urllib.request
import urllib.error
import re
import time
import subprocess
import argparse
import json
import sys
import threading
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import urljoin

# ============================================================
# 配置
# ============================================================

SUCCESS_DELAY = 0.1
USER_AGENT = "Mozilla/5.0"

# ============================================================
# 路径
# ============================================================

OUTPUT_DIR = Path("vtt_files")
OUTPUT_FILE = Path("merged_shifted.vtt")

# ============================================================
# 工具函数
# ============================================================


def clean_text(text: str) -> str:
    text = re.sub(r"<rt>.*?</rt>", "", text)
    text = re.sub(r"</?ruby>", "", text)
    text = re.sub(r"</?c[^>]*>", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&nbsp;", " ")
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()


def clean_time(line: str) -> str:
    return re.sub(
        r"^(\d+:\d+:\d+\.\d+\s+-->\s+\d+:\d+:\d+\.\d+).*$",
        r"\1",
        line,
    )


def time_to_ms(t: str) -> int:
    h, m, s = t.split(":")
    sec, ms = s.split(".")
    return int(h) * 3600000 + int(m) * 60000 + int(sec) * 1000 + int(ms)


def ms_to_time(ms: int) -> str:
    if ms < 0:
        ms = 0
    h = ms // 3600000
    ms %= 3600000
    m = ms // 60000
    ms %= 60000
    s = ms // 1000
    ms %= 1000
    return f"{h:02}:{m:02}:{s:02}.{ms:03}"


def shift_time_line(time_line: str, offset_ms: int) -> str:
    m = re.match(
        r"(\d+:\d+:\d+\.\d+)\s+-->\s+(\d+:\d+:\d+\.\d+)",
        time_line,
    )
    if not m:
        return time_line
    start = time_to_ms(m.group(1)) - offset_ms
    end = time_to_ms(m.group(2)) - offset_ms
    return f"{ms_to_time(start)} --> {ms_to_time(end)}"


def time_line_dur_ms(time_line: str) -> int:
    """Return cue duration in ms from a VTT timing line."""
    m = re.match(
        r"(\d+:\d+:\d+\.\d+)\s+-->\s+(\d+:\d+:\d+\.\d+)",
        time_line,
    )
    if not m:
        return 0
    return time_to_ms(m.group(2)) - time_to_ms(m.group(1))


def merge_time_lines(a: str, b: str) -> str:
    """Merge two timing lines into one covering both cue ranges."""
    m1 = re.match(
        r"(\d+:\d+:\d+\.\d+)\s+-->\s+(\d+:\d+:\d+\.\d+)",
        a,
    )
    m2 = re.match(
        r"(\d+:\d+:\d+\.\d+)\s+-->\s+(\d+:\d+:\d+\.\d+)",
        b,
    )
    if not m1 or not m2:
        return a
    s1, e1 = time_to_ms(m1.group(1)), time_to_ms(m1.group(2))
    s2, e2 = time_to_ms(m2.group(1)), time_to_ms(m2.group(2))
    return f"{ms_to_time(min(s1, s2))} --> {ms_to_time(max(e1, e2))}"


def merge_text(a: str, b: str) -> str:
    if a == b:
        return a
    if b.startswith(a):
        return b
    if a.startswith(b):
        return a
    max_overlap = 0
    max_len = min(len(a), len(b))
    for i in range(1, max_len + 1):
        if a[-i:] == b[:i]:
            max_overlap = i
    return a + b[max_overlap:]


def parse_vtt_blocks(raw: str) -> list:
    text = re.sub(r"WEBVTT\s*", "", raw)
    text = re.sub(r"X-TIMESTAMP-MAP=.*\n", "", text)
    blocks = re.split(r"\n\s*\n", text.strip())

    result = []
    for block in blocks:
        lines = [l.strip() for l in block.splitlines() if l.strip()]
        if not lines:
            continue

        time_line = None
        body_lines = []

        for line in lines:
            if "-->" in line:
                time_line = clean_time(line)
            else:
                body = clean_text(line)
                if body:
                    body_lines.append(body)

        if not time_line or not body_lines:
            continue

        body_text = "".join(body_lines)
        result.append((time_line, body_text))

    return result


def extract_url_range(start_url: str, end_url: str):
    i = 0
    while i < len(start_url) and i < len(end_url) and start_url[i] == end_url[i]:
        i += 1

    j1, j2 = len(start_url) - 1, len(end_url) - 1
    while j1 >= i and j2 >= i and start_url[j1] == end_url[j2]:
        j1 -= 1
        j2 -= 1

    start_str = start_url[i : j1 + 1]
    end_str = end_url[i : j2 + 1]

    if not start_str.isdigit() or not end_str.isdigit():
        raise ValueError(
            f"URL 中差异部分不是纯数字: '{start_str}' vs '{end_str}'"
        )

    start_num = int(start_str)
    end_num = int(end_str)
    if start_num > end_num:
        start_num, end_num = end_num, start_num

    template = start_url[:i] + "{}" + start_url[j1 + 1 :]

    return template, start_num, end_num


def extract_url_single(url: str):
    qmark = url.find("?")
    path_part = url[:qmark] if qmark != -1 else url
    query_part = url[qmark:] if qmark != -1 else ""

    matches = list(re.finditer(r"\d+", path_part))
    if not matches:
        raise ValueError("URL 路径中没有找到数字部分")
    last = matches[-1]
    start, end = last.span()
    template = path_part[:start] + "{}" + path_part[end:] + query_part
    file_id = int(last.group())
    return template, file_id


def get_time_range_ms(raw: str):
    blocks = parse_vtt_blocks(raw)
    if not blocks:
        return None, None
    min_ms = None
    max_ms = None
    for time_line, _ in blocks:
        m = re.match(r"(\d+:\d+:\d+\.\d+)\s+-->\s+(\d+:\d+:\d+\.\d+)", time_line)
        if m:
            s = time_to_ms(m.group(1))
            e = time_to_ms(m.group(2))
            if min_ms is None or s < min_ms:
                min_ms = s
            if max_ms is None or e > max_ms:
                max_ms = e
    return min_ms, max_ms


def extract_note_timestamps(raw: str) -> list:
    timestamps = []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("NOTE "):
            ts_str = line[5:]
            try:
                ts = datetime.fromisoformat(ts_str)
                timestamps.append(ts)
            except ValueError:
                pass
    return timestamps


def parse_local_time_window(start_time: str, end_time: str, ref_date):
    start_h, start_m = map(int, start_time.split(":"))
    end_h, end_m = map(int, end_time.split(":"))

    start_dt = datetime(ref_date.year, ref_date.month, ref_date.day,
                        start_h, start_m).astimezone()
    end_dt = datetime(ref_date.year, ref_date.month, ref_date.day,
                      end_h, end_m).astimezone()

    if end_dt <= start_dt:
        end_dt += timedelta(days=1)

    return start_dt, end_dt


def note_to_local(dt: datetime) -> datetime:
    return dt.astimezone().replace(tzinfo=None)


# ============================================================
# 状态
# ============================================================


class State:
    def __init__(self):
        self.offset_ms = None
        self.merged_blocks = []

    def write_output(self):
        if not self.merged_blocks:
            return

        output_blocks = []
        for time_line, body_text in self.merged_blocks:
            output_blocks.append(f"{time_line}\n{body_text}")

        merged_vtt = "WEBVTT\n\n" + "\n\n".join(output_blocks) + "\n"
        OUTPUT_FILE.write_text(merged_vtt, encoding="utf-8")


# ============================================================
# 下载与处理
# ============================================================


def process_file(file_id: int, raw: str, state: State) -> int:
    OUTPUT_DIR.mkdir(exist_ok=True)
    (OUTPUT_DIR / f"{file_id}.vtt").write_text(raw, encoding="utf-8")

    blocks = parse_vtt_blocks(raw)
    if not blocks:
        return 0

    if state.offset_ms is None:
        first_time_line = blocks[0][0]
        m = re.match(r"(\d+:\d+:\d+\.\d+)", first_time_line)
        if m:
            state.offset_ms = time_to_ms(m.group(1))
            print(f"[OFFSET] 第一条字幕起始时间 = {m.group(1)} -> 00:00:00.000")
        else:
            state.offset_ms = 0

    added = 0
    for unshifted_time, body_text in blocks:
        shifted_time = shift_time_line(unshifted_time, state.offset_ms)

        if state.merged_blocks:
            last_time, last_text = state.merged_blocks[-1]

            if last_time == shifted_time:
                merged = merge_text(last_text, body_text)
                if len(state.merged_blocks) >= 2 and merged == state.merged_blocks[-2][1]:
                    # Same two-line caption re-emitted in the next segment:
                    # merge both copies into one cue covering both ranges.
                    state.merged_blocks[-2] = (
                        merge_time_lines(state.merged_blocks[-2][0], shifted_time),
                        merged,
                    )
                    state.merged_blocks.pop()
                    continue
                state.merged_blocks[-1] = (shifted_time, merged)
                continue

            if body_text == last_text:
                # Re-emitted truncated copy + full-length copy: cover both
                # time ranges instead of keeping either one.
                state.merged_blocks[-1] = (
                    merge_time_lines(last_time, shifted_time),
                    body_text,
                )
                continue

        state.merged_blocks.append((shifted_time, body_text))
        added += 1

    return added


# ============================================================
# 主逻辑
# ============================================================


MAX_CONSECUTIVE_FAILURES = 20
MAX_NO_PROGRESS = 100
MAX_OUT_OF_WINDOW = 500
SEARCH_MARGIN = 30
MAX_LATE_MINUTES = 5


def cleanup():
    import shutil
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
        print(f"[CLEAN] 已删除临时目录 {OUTPUT_DIR}")


def convert_to_srt(vtt_path: Path) -> bool:
    date_str = datetime.now().strftime("%y%m%d")
    srt_path = vtt_path.with_stem(date_str).with_suffix(".srt")
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(vtt_path), str(srt_path)],
            check=True, capture_output=True, text=True,
        )
        print(f"[SRT] {srt_path}")
        return True
    except FileNotFoundError:
        print("[WARN] 未找到 ffmpeg，跳过 SRT 转换")
    except subprocess.CalledProcessError as e:
        print(f"[ERR] SRT 转换失败: {e.stderr.strip()}")
    return False


def download_one(template: str, file_id: int, headers: dict) -> str | None:
    url = template.format(file_id)
    return download_raw(url, headers, file_id)


def download_raw(url: str, headers: dict, tag=None) -> str | None:
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            raw = response.read().decode("utf-8", errors="ignore")
        if "WEBVTT" not in raw:
            if tag is not None:
                print(f"[SKIP] {tag} -> 不是有效 VTT")
            return None
        return raw
    except urllib.error.HTTPError as e:
        if tag is not None:
            print(f"[SKIP] {tag} -> HTTP {e.code}")
        return None
    except Exception as e:
        if tag is not None:
            print(f"[ERR] {tag}: {e}")
        return None


def main_range(start_url: str, end_url: str, output_file: str | None = None):
    global OUTPUT_FILE
    if output_file:
        OUTPUT_FILE = Path(output_file)

    template, start_id, end_id = extract_url_range(start_url, end_url)

    print(f"模板: {template}")
    print(f"ID 范围: {start_id} -> {end_id} (共 {end_id - start_id + 1} 个)")
    print()

    state = State()
    headers = {"User-Agent": USER_AGENT}

    for file_id in range(start_id, end_id + 1):
        url = template.format(file_id)
        req = urllib.request.Request(url, headers=headers)

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                raw = response.read().decode("utf-8", errors="ignore")

            if "WEBVTT" not in raw:
                print(f"[SKIP] id={file_id} -> 不是有效 VTT")
                continue

            added = process_file(file_id, raw, state)
            print(f"[OK] id={file_id} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

        except urllib.error.HTTPError as e:
            print(f"[SKIP] id={file_id} -> HTTP {e.code}")
        except Exception as e:
            print(f"[ERR] id={file_id}: {e}")

        time.sleep(SUCCESS_DELAY)

    state.write_output()
    print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")


def main_start(start_url: str, duration_min: float, output_file: str | None = None):
    global OUTPUT_FILE
    if output_file:
        OUTPUT_FILE = Path(output_file)

    template, start_id = extract_url_single(start_url)
    duration_ms = int(duration_min * 60 * 1000)

    print(f"模板: {template}")
    print(f"起始 ID: {start_id}")
    print(f"持续时间: {duration_min} 分钟")
    print()

    state = State()
    headers = {"User-Agent": USER_AGENT}
    consecutive_failures = 0
    consecutive_no_progress = 0
    last_end_ms = 0
    file_id = start_id

    while True:
        url = template.format(file_id)
        req = urllib.request.Request(url, headers=headers)

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                raw = response.read().decode("utf-8", errors="ignore")

            if "WEBVTT" not in raw:
                print(f"[SKIP] id={file_id} -> 不是有效 VTT")
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                    break
                file_id += 1
                time.sleep(SUCCESS_DELAY)
                continue

            consecutive_failures = 0
            prev_block_count = len(state.merged_blocks)
            added = process_file(file_id, raw, state)
            print(f"[OK] id={file_id} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

            if state.merged_blocks:
                last_time_line = state.merged_blocks[-1][0]
                m = re.match(
                    r"\d+:\d+:\d+\.\d+\s+-->\s+(\d+:\d+:\d+\.\d+)",
                    last_time_line,
                )
                if m:
                    current_end_ms = time_to_ms(m.group(1))
                    if current_end_ms > last_end_ms:
                        last_end_ms = current_end_ms
                        consecutive_no_progress = 0
                    else:
                        consecutive_no_progress += 1

                    if current_end_ms >= duration_ms:
                        print(f"[STOP] 已达到 {duration_min} 分钟")
                        break
                else:
                    consecutive_no_progress += 1
            elif prev_block_count == 0:
                consecutive_no_progress += 1

            if consecutive_no_progress >= MAX_NO_PROGRESS:
                print(f"[ABORT] 连续 {MAX_NO_PROGRESS} 个文件时间无推进，字幕可能已结束")
                break

        except urllib.error.HTTPError as e:
            print(f"[SKIP] id={file_id} -> HTTP {e.code}")
            consecutive_failures += 1
            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                break
        except Exception as e:
            print(f"[ERR] id={file_id}: {e}")
            consecutive_failures += 1
            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                break

        file_id += 1
        time.sleep(SUCCESS_DELAY)

    state.write_output()
    print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")


def main_end(end_url: str, duration_min: float, output_file: str | None = None):
    global OUTPUT_FILE
    if output_file:
        OUTPUT_FILE = Path(output_file)

    template, end_id = extract_url_single(end_url)
    duration_ms = int(duration_min * 60 * 1000)

    print(f"模板: {template}")
    print(f"结尾 ID: {end_id}")
    print(f"持续时间: {duration_min} 分钟")
    print()

    headers = {"User-Agent": USER_AGENT}
    collected = []
    global_min_ms = None
    global_max_ms = None
    consecutive_failures = 0
    consecutive_no_progress = 0
    last_span = 0
    file_id = end_id

    while True:
        url = template.format(file_id)
        req = urllib.request.Request(url, headers=headers)

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                raw = response.read().decode("utf-8", errors="ignore")

            if "WEBVTT" not in raw:
                print(f"[SKIP] id={file_id} -> 不是有效 VTT")
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                    break
                file_id -= 1
                time.sleep(SUCCESS_DELAY)
                continue

            consecutive_failures = 0
            collected.append((file_id, raw))

            file_min, file_max = get_time_range_ms(raw)
            if file_min is not None:
                if global_min_ms is None or file_min < global_min_ms:
                    global_min_ms = file_min
                if global_max_ms is None or file_max > global_max_ms:
                    global_max_ms = file_max

            span = (global_max_ms - global_min_ms) if (global_min_ms is not None and global_max_ms is not None) else 0
            print(f"[DL] id={file_id} (已收集 {len(collected)} 个, 时长 {span / 1000:.1f}s)")

            if span > last_span:
                last_span = span
                consecutive_no_progress = 0
            else:
                consecutive_no_progress += 1

            if span >= duration_ms:
                print(f"[STOP] 已收集 {duration_min} 分钟的字幕")
                break

            if consecutive_no_progress >= MAX_NO_PROGRESS:
                print(f"[ABORT] 连续 {MAX_NO_PROGRESS} 个文件时长无变化，字幕可能已结束")
                break

        except urllib.error.HTTPError as e:
            print(f"[SKIP] id={file_id} -> HTTP {e.code}")
            consecutive_failures += 1
            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                break
        except Exception as e:
            print(f"[ERR] id={file_id}: {e}")
            consecutive_failures += 1
            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                break

        file_id -= 1
        time.sleep(SUCCESS_DELAY)

    collected.sort(key=lambda x: x[0])

    print(f"\n[MERGE] 正向合并 {len(collected)} 个文件...")
    state = State()
    for fid, raw in collected:
        added = process_file(fid, raw, state)
        print(f"[MERGE] id={fid} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

    state.write_output()
    print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")


def main_around(url: str, before_min: float, after_min: float, output_file: str | None = None):
    global OUTPUT_FILE
    if output_file:
        OUTPUT_FILE = Path(output_file)

    template, ref_id = extract_url_single(url)
    before_ms = int(before_min * 60 * 1000)
    after_ms = int(after_min * 60 * 1000)

    print(f"模板: {template}")
    print(f"参考 ID: {ref_id}")
    print(f"前: {before_min} 分钟, 后: {after_min} 分钟")
    print()

    headers = {"User-Agent": USER_AGENT}

    ref_raw = download_one(template, ref_id, headers)
    if not ref_raw:
        print("[ERR] 无法下载参考 URL")
        return

    ref_min_ms, ref_max_ms = get_time_range_ms(ref_raw)
    if ref_min_ms is None:
        print("[ERR] 参考文件中没有有效字幕")
        return

    print(f"[REF] id={ref_id}, 时间范围: {ms_to_time(ref_min_ms)} ~ {ms_to_time(ref_max_ms)}")

    collected = {ref_id: ref_raw}

    if before_ms > 0:
        print(f"\n[Phase 1] 反向下载 {before_min} 分钟...")
        target_min_ms = ref_min_ms - before_ms
        consecutive_failures = 0
        consecutive_no_progress = 0
        last_min_ms = ref_min_ms
        file_id = ref_id - 1

        while True:
            raw = download_one(template, file_id, headers)
            if raw is None:
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止反向")
                    break
                file_id -= 1
                time.sleep(SUCCESS_DELAY)
                continue

            consecutive_failures = 0
            collected[file_id] = raw

            file_min, _ = get_time_range_ms(raw)
            if file_min is not None:
                if file_min < last_min_ms:
                    last_min_ms = file_min
                    consecutive_no_progress = 0
                else:
                    consecutive_no_progress += 1
            else:
                consecutive_no_progress += 1

            span = (ref_min_ms - file_min) if file_min is not None else 0
            print(f"  id={file_id} (已收集 {len(collected)} 个, 前向覆盖 {span / 1000:.1f}s)")

            if file_min is not None and file_min <= target_min_ms:
                print(f"[STOP] 前向已覆盖 {before_min} 分钟")
                break

            if consecutive_no_progress >= MAX_NO_PROGRESS:
                print(f"[ABORT] 连续 {MAX_NO_PROGRESS} 个文件时间无推进，字幕可能已结束")
                break

            file_id -= 1
            time.sleep(SUCCESS_DELAY)

    if after_ms > 0:
        print(f"\n[Phase 2] 正向下载 {after_min} 分钟...")
        target_max_ms = ref_min_ms + after_ms
        consecutive_failures = 0
        consecutive_no_progress = 0
        last_max_ms = ref_min_ms
        file_id = ref_id + 1

        while True:
            raw = download_one(template, file_id, headers)
            if raw is None:
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止正向")
                    break
                file_id += 1
                time.sleep(SUCCESS_DELAY)
                continue

            consecutive_failures = 0
            collected[file_id] = raw

            _, file_max = get_time_range_ms(raw)
            if file_max is not None:
                if file_max > last_max_ms:
                    last_max_ms = file_max
                    consecutive_no_progress = 0
                else:
                    consecutive_no_progress += 1
            else:
                consecutive_no_progress += 1

            span = (file_max - ref_min_ms) if file_max is not None else 0
            print(f"  id={file_id} (已收集 {len(collected)} 个, 后向覆盖 {span / 1000:.1f}s)")

            if file_max is not None and file_max >= target_max_ms:
                print(f"[STOP] 后向已覆盖 {after_min} 分钟")
                break

            if consecutive_no_progress >= MAX_NO_PROGRESS:
                print(f"[ABORT] 连续 {MAX_NO_PROGRESS} 个文件时间无推进，字幕可能已结束")
                break

            file_id += 1
            time.sleep(SUCCESS_DELAY)

    sorted_ids = sorted(collected.keys())
    print(f"\n[MERGE] 正向合并 {len(sorted_ids)} 个文件 (ID {sorted_ids[0]} -> {sorted_ids[-1]})...")

    state = State()
    for fid in sorted_ids:
        added = process_file(fid, collected[fid], state)
        print(f"[MERGE] id={fid} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

    state.write_output()
    print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")


def main_timewindow(url: str, start_time: str, end_time: str,
                    output_file: str | None = None):
    global OUTPUT_FILE
    if output_file:
        OUTPUT_FILE = Path(output_file)

    template, ref_id = extract_url_single(url)

    print(f"模板: {template}")
    print(f"参考 ID: {ref_id}")
    print(f"时间窗口 (本地时间): {start_time} ~ {end_time}")
    print()

    headers = {"User-Agent": USER_AGENT}

    ref_raw = download_one(template, ref_id, headers)
    if not ref_raw:
        print("[ERR] 无法下载参考 URL")
        return

    ref_notes = extract_note_timestamps(ref_raw)
    if not ref_notes:
        print("[WARN] 参考文件中没有 NOTE 时间戳, 在附近搜索...")
        for search_offset in [10, -10, 25, -25, 50, -50, 100, -100, 200, -200]:
            search_id = ref_id + search_offset
            search_raw = download_one(template, search_id, headers)
            if not search_raw:
                continue
            search_notes = extract_note_timestamps(search_raw)
            if search_notes:
                print(f"[FOUND] id={search_id} 有 NOTE, 以此为新参考")
                ref_notes = search_notes
                ref_raw = search_raw
                ref_id = search_id
                break
        if not ref_notes:
            print("[ERR] 附近找不到带时间戳的字幕文件")
            return

    ref_date = ref_notes[0].date()
    target_start, target_end = parse_local_time_window(
        start_time, end_time, ref_date)

    ref_min = min(ref_notes)
    ref_max = max(ref_notes)

    ref_local_start = note_to_local(ref_min)
    ref_local_end = note_to_local(ref_max)

    print(f"[REF] id={ref_id} "
          f"(本地 {ref_local_start.strftime('%H:%M:%S')} ~ {ref_local_end.strftime('%H:%M:%S')})")
    print(f"[TARGET] 本地 {start_time} ~ {end_time}")
    print()

    collected = {}
    overall_min = None
    overall_max = None

    def _update_overall(notes):
        nonlocal overall_min, overall_max
        if notes:
            nmin = min(notes)
            nmax = max(notes)
            if overall_min is None or nmin < overall_min:
                overall_min = nmin
            if overall_max is None or nmax > overall_max:
                overall_max = nmax

    # include reference if in range
    if any(target_start <= n <= target_end for n in ref_notes):
        collected[ref_id] = ref_raw
        _update_overall(ref_notes)
        print(f"[IN RANGE] id={ref_id}")

    def _estimate_ratio():
        """Try probes in both directions to find ID/time ratio."""
        for direction in [-1, 1]:
            for offset in [50, 150, 400, 1000, 3000]:
                probe_id = ref_id + direction * offset
                if probe_id < 0:
                    continue
                probe_raw = download_one(template, probe_id, headers)
                if not probe_raw:
                    continue
                probe_notes = extract_note_timestamps(probe_raw)
                if not probe_notes:
                    continue
                probe_time = (max(probe_notes) if direction == -1
                              else min(probe_notes))
                time_diff = abs((probe_time - ref_min).total_seconds())
                if time_diff > 30:
                    ratio = offset / time_diff
                    print(f"  [RATIO] id={probe_id} 偏移 {offset}, "
                          f"时差 {time_diff:.0f}s, "
                          f"比率 {ratio:.4f} IDs/s")
                    return ratio
        return None

    # Calculate target ID range
    ids_per_sec = _estimate_ratio()

    if ids_per_sec is not None:
        start_offset_s = (target_start - ref_min).total_seconds()
        end_offset_s = (target_end - ref_min).total_seconds()
        est_start_id = int(ref_id + start_offset_s * ids_per_sec)
        est_end_id = int(ref_id + end_offset_s * ids_per_sec)
        file_id = max(0, est_start_id - SEARCH_MARGIN)
        print(f"  预估起始 ID: {est_start_id}, 预估结束 ID: {est_end_id}")
        print(f"  扫描起点: id={file_id}\n")
    else:
        # Can't estimate, start from ref and scan both ways dynamically
        file_id = max(0, ref_id - 100)
        est_end_id = None
        print(f"  [FALLBACK] 无法估算比率，从 id={file_id} 开始动态扫描\n")

    consecutive_failures = 0
    consecutive_empty = 0
    consecutive_after = 0

    try:
        while True:
            if file_id < 0:
                print("[STOP] ID 已到 0，停止搜索")
                break

            if file_id in collected:
                file_id += 1
                continue

            raw = download_one(template, file_id, headers)
            if raw is None:
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"[ABORT] 连续 {MAX_CONSECUTIVE_FAILURES} 次下载失败")
                    break
                file_id += 1
                time.sleep(SUCCESS_DELAY)
                continue

            consecutive_failures = 0
            notes = extract_note_timestamps(raw)

            if not notes:
                consecutive_empty += 1
                print(f"  id={file_id} (无 NOTE)")
                if consecutive_empty >= MAX_OUT_OF_WINDOW:
                    print(f"[STOP] 连续 {MAX_OUT_OF_WINDOW} 个文件无时间戳")
                    break
                file_id += 1
                time.sleep(SUCCESS_DELAY)
                continue

            nmin = min(notes)
            nmax = max(notes)

            # Dynamic jump: if we're before target_start, skip ahead
            if ids_per_sec is not None and consecutive_empty == 0:
                if nmax < target_start:
                    to_start_s = (target_start - nmax).total_seconds()
                    jump_dist = int(to_start_s * ids_per_sec)
                    if jump_dist > 50:
                        new_id = file_id + jump_dist
                        print(f"  [JUMP] 距窗口起点 {to_start_s:.0f}s, "
                              f"前跳 {jump_dist} ID -> id={new_id}")
                        file_id = new_id
                        consecutive_empty = 0
                        consecutive_after = 0
                        time.sleep(SUCCESS_DELAY)
                        continue

            if any(target_start <= n <= target_end for n in notes):
                collected[file_id] = raw
                _update_overall(notes)
                consecutive_empty = 0
                consecutive_after = 0
                print(f"  [IN RANGE] id={file_id} "
                      f"({nmin.strftime('%H:%M:%S')} ~ {nmax.strftime('%H:%M:%S')})")
            elif nmin > target_end:
                consecutive_after += 1
                print(f"  [AFTER] id={file_id} "
                      f"({nmin.strftime('%H:%M:%S')} ~ {nmax.strftime('%H:%M:%S')})")
                if consecutive_after >= 20:
                    print(f"[STOP] 已连续 20 个文件超出时间窗口（终点之后）")
                    break
            elif nmax < target_start:
                consecutive_empty = 0
                consecutive_after = 0
                print(f"  [BEFORE] id={file_id} "
                      f"({nmin.strftime('%H:%M:%S')} ~ {nmax.strftime('%H:%M:%S')})")
            else:
                print(f"  [SKIP] id={file_id}")

            file_id += 1
            time.sleep(SUCCESS_DELAY)

            # Stop if we're well past the estimated end and seeing [AFTER] notes
            if (est_end_id is not None
                    and file_id > est_end_id + 100
                    and (consecutive_after + consecutive_empty) >= 30):
                print(f"[STOP] 已超过预估结束范围")
                break
    except KeyboardInterrupt:
        print("\n[INTERRUPT] 用户中断，保存已收集的字幕...")

    if not collected:
        print("[ERR] 未找到目标时间范围内的字幕文件")
        return

    sorted_ids = sorted(collected.keys())
    print(f"\n[MERGE] 合并 {len(sorted_ids)} 个文件 "
          f"(ID {sorted_ids[0]} -> {sorted_ids[-1]})...")

    time_offset_ms = None
    for fid in sorted_ids:
        test_raw = collected[fid]
        test_vtt_min, _ = get_time_range_ms(test_raw)
        test_notes = extract_note_timestamps(test_raw)
        if test_vtt_min is not None and test_notes:
            note_min_utc = min(test_notes)
            vtt_min_td = timedelta(milliseconds=test_vtt_min)
            stream_start_utc = note_min_utc - vtt_min_td
            time_offset_ms = int(
                (target_start - stream_start_utc).total_seconds() * 1000
            )
            if time_offset_ms < 0:
                time_offset_ms = 0
            print(f"[OFFSET] 推算流起点: {stream_start_utc.astimezone().strftime('%H:%M:%S')} (本地)")
            print(f"[OFFSET] 时间偏移: {ms_to_time(time_offset_ms)} "
                  f"({target_start.strftime('%H:%M:%S')} 本地 -> 00:00:00.000)")
            print()
            break

    state = State()
    if time_offset_ms is not None:
        state.offset_ms = time_offset_ms
    for fid in sorted_ids:
        added = process_file(fid, collected[fid], state)
        print(f"[MERGE] id={fid} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

    state.write_output()
    print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")


# ============================================================
# 实时混合模式: 追赶历史 + 轮询等待未来
# ============================================================


def main_live_window(url: str, start_time: str, end_time: str,
                     output_file: str | None = None,
                     playlist_url: str | None = None):
    global OUTPUT_FILE
    if output_file:
        OUTPUT_FILE = Path(output_file)

    template, ref_id = extract_url_single(url)

    print(f"模板: {template}")
    print(f"参考 ID: {ref_id}")
    print(f"时间窗口 (本地时间): {start_time} ~ {end_time}")
    print()

    headers = {"User-Agent": USER_AGENT}

    # ── 获取当前 playlist 的边界 ──────────────────────────────────────
    boundary_id = ref_id
    if playlist_url:
        print("[BOUNDARY] 获取实时 playlist 确定边界...")
        try:
            playlist_segments = fetch_playlist(playlist_url, headers)
        except Exception as e:
            print(f"[ERR] playlist 获取失败: {e}")
            return

        if not playlist_segments:
            print("[ERR] playlist 为空")
            return

        for seg_url, seg_pdt, seg_dur in playlist_segments:
            sid = extract_id_from_url(seg_url)
            if sid > boundary_id:
                boundary_id = sid

        first_pdt = playlist_segments[0][1]
        last_pdt = playlist_segments[-1][1]
        print(f"[BOUNDARY] playlist 有 {len(playlist_segments)} 个分段, "
              f"ID 范围: {extract_id_from_url(playlist_segments[0][0])} ~ {boundary_id}")
        if first_pdt:
            print(f"[BOUNDARY] PDT 范围: {note_to_local(first_pdt).strftime('%H:%M:%S')}"
                  f" ~ {note_to_local(last_pdt).strftime('%H:%M:%S')} (本地)")

    # ── 下载参考点确定时间窗口 ──────────────────────────────────────
    ref_raw = download_one(template, ref_id, headers)
    ref_notes = None
    if ref_raw:
        ref_notes = extract_note_timestamps(ref_raw)

    if not ref_notes:
        print("[WARN] 参考文件中没有 NOTE 时间戳, 在附近搜索...")
        for search_offset in [10, -10, 25, -25, 50, -50, 100, -100, 200, -200]:
            search_id = ref_id + search_offset
            search_raw = download_one(template, search_id, headers)
            if not search_raw:
                continue
            search_notes = extract_note_timestamps(search_raw)
            if search_notes:
                print(f"[FOUND] id={search_id} 有 NOTE, 以此为新参考")
                ref_notes = search_notes
                ref_raw = search_raw
                ref_id = search_id
                break
        if not ref_notes:
            print("[ERR] 附近找不到带时间戳的字幕文件")
            print("[FALLBACK] 使用 playlist PDT 作为参考时间")
            # Use playlist PDT as fallback
            if playlist_url and playlist_segments:
                first_pdt = playlist_segments[0][1]
                if first_pdt:
                    # Create a synthetic "NOTE" from PDT
                    ref_notes = [first_pdt]
                else:
                    print("[ERR] playlist 也无 PDT，无法继续")
                    return
            else:
                return

    ref_date = ref_notes[0].date()
    target_start, target_end = parse_local_time_window(
        start_time, end_time, ref_date)

    if datetime.now().astimezone() >= target_end + timedelta(minutes=MAX_LATE_MINUTES):
        print(f"[LIVE] 窗口已结束，用 playlist PDT 直接定位 ID 范围")

        # 用 playlist 第一个分段的 (ID, PDT) 配对做参考
        ref_seg = playlist_segments[0]
        ref_pdt = ref_seg[1]
        ref_seg_id = extract_id_from_url(ref_seg[0])
        ref_pdt_local = note_to_local(ref_pdt)
        print(f"  参考点: id={ref_seg_id}, PDT={ref_pdt_local.strftime('%H:%M:%S')} 本地")

        # 估算 IDs/sec（用 playlist 第二个分段避开可能的跳帧）
        ids_per_sec_est = 0.25
        if len(playlist_segments) >= 2:
            seg2 = playlist_segments[1]
            pdt2 = seg2[1]
            id2 = extract_id_from_url(seg2[0])
            if pdt2 and ref_pdt:
                diff_secs = abs((pdt2 - ref_pdt).total_seconds())
                diff_ids = abs(id2 - ref_seg_id)
                if diff_secs > 1 and diff_ids > 0:
                    ids_per_sec_est = diff_ids / diff_secs
                    print(f"  IDs/s={ids_per_sec_est:.4f} (playlist 实测)")

        secs_start = (ref_pdt - target_start).total_seconds()
        secs_end = (ref_pdt - target_end).total_seconds()
        est_start = max(0, int(ref_seg_id - secs_start * ids_per_sec_est) - SEARCH_MARGIN)
        est_end = int(ref_seg_id - secs_end * ids_per_sec_est) + SEARCH_MARGIN
        print(f"[LIVE] 扫描 ID: {est_start} -> {est_end}")

        collected = {}
        for fid in range(est_start, est_end + 1):
            raw = download_one(template, fid, headers)
            if not raw:
                continue
            notes = extract_note_timestamps(raw)
            if notes and any(target_start <= n <= target_end for n in notes):
                collected[fid] = raw
                nlocal = note_to_local(min(notes))
                print(f"  [SCAN] id={fid} ({nlocal.strftime('%H:%M:%S')} 本地)"
                      f" 共 {len(collected)} 个")
            elif notes and min(notes) > target_end:
                break
            time.sleep(SUCCESS_DELAY)

        if not collected:
            print("[ERR] 未找到目标时间范围内的字幕文件")
            return

        sorted_ids = sorted(collected.keys())
        print(f"\n[MERGE] 合并 {len(sorted_ids)} 个文件"
              f" (ID {sorted_ids[0]} -> {sorted_ids[-1]})...")

        time_offset_ms = None
        for fid in sorted_ids:
            test_raw = collected[fid]
            test_vtt_min, _ = get_time_range_ms(test_raw)
            test_notes = extract_note_timestamps(test_raw)
            if test_vtt_min is not None and test_notes:
                note_min_utc = min(test_notes)
                vtt_min_td = timedelta(milliseconds=test_vtt_min)
                stream_start_utc = note_min_utc - vtt_min_td
                time_offset_ms = int(
                    (target_start - stream_start_utc).total_seconds() * 1000)
                if time_offset_ms < 0:
                    time_offset_ms = 0
                print(f"[OFFSET] 推算流起点:"
                      f" {note_to_local(stream_start_utc).strftime('%H:%M:%S')} (本地)")
                print(f"[OFFSET] 时间偏移: {ms_to_time(time_offset_ms)}"
                      f" ({target_start.strftime('%H:%M:%S')} 本地 -> 00:00:00.000)\n")
                break

        if time_offset_ms is None:
            print("[WARN] 无法推算时间偏移，不进行时间对齐")
            time_offset_ms = 0

        state = State()
        state.offset_ms = time_offset_ms
        for fid in sorted_ids:
            added = process_file(fid, collected[fid], state)
            print(f"[MERGE] id={fid} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

        state.write_output()
        print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")
        return

    ref_min_utc = min(ref_notes)
    ref_local = note_to_local(ref_min_utc)
    print(f"[REF] id={ref_id} (本地 {ref_local.strftime('%H:%M:%S')})")
    print(f"[TARGET] 本地 {start_time} ~ {end_time}")
    print()

    # ── 预估扫描方向 ─────────────────────────────────────────────────
    def _estimate_ratio():
        for direction in [-1, 1]:
            for offset in [50, 150, 400, 1000, 3000]:
                probe_id = ref_id + direction * offset
                if probe_id < 0:
                    continue
                probe_raw = download_one(template, probe_id, headers)
                if not probe_raw:
                    continue
                probe_notes = extract_note_timestamps(probe_raw)
                if not probe_notes:
                    continue
                probe_time = (max(probe_notes) if direction == -1
                              else min(probe_notes))
                time_diff = abs((probe_time - ref_min_utc).total_seconds())
                if time_diff > 30:
                    ratio = offset / time_diff
                    print(f"  [RATIO] id={probe_id} 偏移 {offset}, "
                          f"时差 {time_diff:.0f}s, "
                          f"比率 {ratio:.4f} IDs/s")
                    return ratio
        return None

    ids_per_sec = _estimate_ratio()
    if ids_per_sec:
        print(f"  IDs/s: {ids_per_sec:.4f}")
    else:
        ids_per_sec = 0.25
        print(f"  [FALLBACK] 默认 IDs/s: {ids_per_sec}")

    # ── 共享状态 ────────────────────────────────────────────────────
    collected = {}
    lock = threading.Lock()
    running = [True]

    def _in_window(pdt: datetime) -> bool:
        return target_start <= pdt <= target_end

    # ── Phase 1(Thread B): 向后扫描历史 ─────────────────────────────
    def phase1_backward():
        fid = boundary_id - 1
        consecutive_failures = 0
        count = 0

        while fid >= 0 and running[0]:
            if fid in collected:
                fid -= 1
                continue

            raw = download_one(template, fid, headers)
            if raw is None:
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"[Phase 1] 连续 {MAX_CONSECUTIVE_FAILURES} 次失败，停止")
                    break
                fid -= 1
                time.sleep(SUCCESS_DELAY * 2)
                continue

            consecutive_failures = 0
            vtt_min, _ = get_time_range_ms(raw)

            # 用最近已知 NOTE 的偏移估测本分段的实际时间
            pdt_estimate = None
            with lock:
                sorted_ids = sorted(collected.keys())
                if sorted_ids:
                    last_id = sorted_ids[-1]
                    if last_id > fid:
                        last_raw = collected[last_id]
                        last_notes = extract_note_timestamps(last_raw)
                        last_vtt, _ = get_time_range_ms(last_raw)
                        if last_notes and last_vtt is not None:
                            secs_between = (last_id - fid) / ids_per_sec
                            pdt_estimate = min(last_notes) - timedelta(seconds=secs_between)

            if pdt_estimate is None and ref_notes:
                # Fallback: estimate from reference
                secs_diff = (ref_id - fid) / ids_per_sec
                pdt_estimate = ref_min_utc - timedelta(seconds=secs_diff)

            if pdt_estimate and _in_window(pdt_estimate):
                with lock:
                    collected[fid] = raw
                count += 1
                pdt_local = note_to_local(pdt_estimate)
                print(f"  [Phase 1] id={fid} (估 {pdt_local.strftime('%H:%M:%S')} 本地)"
                      f" 共 {len(collected)} 个")
            elif pdt_estimate and pdt_estimate < target_start:
                print(f"[Phase 1] id={fid} 已追过窗口起点，停止")
                break

            fid -= 1
            time.sleep(SUCCESS_DELAY)

        print(f"[Phase 1] 结束: 共收集 {count} 个历史分段")

    # ── Phase 2(Thread A): playlist 轮询 ────────────────────────────
    def phase2_forward():
        seen_ids = set()
        count = 0

        while running[0]:
            now = datetime.now().astimezone()
            if now > target_end + timedelta(minutes=MAX_LATE_MINUTES):
                print(f"[Phase 2] 现实时间已超过窗口 {MAX_LATE_MINUTES} 分钟，停止")
                running[0] = False
                break

            if playlist_url:
                try:
                    segments = fetch_playlist(playlist_url, headers)
                except Exception as e:
                    print(f"[Phase 2] playlist 失败: {e}")
                    time.sleep(2)
                    continue

                next_ready = None
                for seg_url, seg_pdt, seg_dur in segments:
                    sid = extract_id_from_url(seg_url)
                    if sid in seen_ids:
                        continue
                    seen_ids.add(sid)

                    if not seg_pdt:
                        continue

                    seg_end = seg_pdt + timedelta(seconds=max(seg_dur, 1))
                    next_ready = seg_end

                    if _in_window(seg_pdt) or _in_window(seg_end):
                        raw = download_raw(seg_url, headers, tag=sid)
                        if raw:
                            with lock:
                                collected[sid] = raw
                            count += 1
                            pdt_local = note_to_local(seg_pdt)
                            print(f"  [Phase 2] id={sid} ({pdt_local.strftime('%H:%M:%S')} 本地)"
                                  f" 共 {len(collected)} 个")
                    elif seg_pdt > target_end:
                        break

                if next_ready and next_ready.tzinfo:
                    wait = (next_ready - datetime.now(timezone.utc)).total_seconds()
                    if wait > 0.5:
                        wait += 0.5
                        if wait > 5:
                            wait = min(wait, 5.0)
                        print(f"  [Phase 2] 等待 {wait:.1f}s (下一批约 "
                              f"{note_to_local(next_ready).strftime('%H:%M:%S')} 本地)")
                        time.sleep(wait)
            else:
                # 无 playlist_url: ID 扫描模式（简化版，主路径用 playlist）
                scan_id = boundary_id + 1
                consecutive_404 = 0

                while running[0]:
                    now = datetime.now().astimezone()
                    if now > target_end + timedelta(minutes=MAX_LATE_MINUTES):
                        running[0] = False
                        break

                    with lock:
                        collected_ids = set(collected.keys())
                    if scan_id in collected_ids:
                        scan_id += 1
                        continue

                    raw = download_one(template, scan_id, headers)
                    if raw is None:
                        consecutive_404 += 1
                        if consecutive_404 >= 20:
                            scan_id += 1
                            consecutive_404 = 0
                        time.sleep(2)
                        continue

                    consecutive_404 = 0
                    notes = extract_note_timestamps(raw)
                    if notes:
                        pdt = min(notes)
                        if _in_window(pdt):
                            with lock:
                                collected[scan_id] = raw
                            count += 1
                        elif pdt > target_end:
                            running[0] = False
                            break
                    scan_id += 1
                    time.sleep(SUCCESS_DELAY)

        print(f"[Phase 2] 结束: 共收集 {count} 个新分段")

    # ── 预等待：窗口尚未开始则 sleep 到开始前 30 秒 ──────────────
    now = datetime.now().astimezone()
    if target_start > now:
        wait_secs = (target_start - now).total_seconds() - 30
        if wait_secs > 0:
            print(f"[WAIT] 窗口 {target_start.strftime('%H:%M:%S')} 尚未开始，"
                  f"等待 {wait_secs:.0f}s...")
            time.sleep(wait_secs)

    # ── 启动双线程 ─────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"[开始] Phase 1(历史) 和 Phase 2(实时) 同时进行")
    print(f"{'='*60}\n")

    t1 = threading.Thread(target=phase2_forward, daemon=True, name="Phase2")
    t2 = threading.Thread(target=phase1_backward, daemon=True, name="Phase1")
    t1.start()
    t2.start()

    try:
        t1.join()
        t2.join()
    except KeyboardInterrupt:
        print("\n[INTERRUPT] 用户中断")
        running[0] = False
        t1.join(timeout=5)
        t2.join(timeout=5)

    # ── 合并输出 ──────────────────────────────────────────────────
    if not collected:
        print("[ERR] 未找到目标时间范围内的字幕文件")
        return

    sorted_ids = sorted(collected.keys())
    print(f"\n[MERGE] 合并 {len(sorted_ids)} 个文件"
          f" (ID {sorted_ids[0]} -> {sorted_ids[-1]})...")

    # 推算时间偏移（对齐到 target_start）
    time_offset_ms = None
    for fid in sorted_ids:
        test_raw = collected[fid]
        test_vtt_min, _ = get_time_range_ms(test_raw)
        test_notes = extract_note_timestamps(test_raw)
        if test_vtt_min is not None and test_notes:
            note_min_utc = min(test_notes)
            vtt_min_td = timedelta(milliseconds=test_vtt_min)
            stream_start_utc = note_min_utc - vtt_min_td
            time_offset_ms = int(
                (target_start - stream_start_utc).total_seconds() * 1000
            )
            if time_offset_ms < 0:
                time_offset_ms = 0
            stream_local = note_to_local(stream_start_utc)
            print(f"[OFFSET] 推算流起点: {stream_local.strftime('%H:%M:%S')} (本地)")
            print(f"[OFFSET] 时间偏移: {ms_to_time(time_offset_ms)}"
                  f" ({target_start.strftime('%H:%M:%S')} 本地 -> 00:00:00.000)\n")
            break

    if time_offset_ms is None:
        print("[WARN] 无法推算时间偏移，不进行时间对齐")
        time_offset_ms = 0

    state = State()
    state.offset_ms = time_offset_ms
    for fid in sorted_ids:
        added = process_file(fid, collected[fid], state)
        print(f"[MERGE] id={fid} (+{added} 块, 累计 {len(state.merged_blocks)} 块)")

    state.write_output()
    print(f"\n[DONE] 共 {len(state.merged_blocks)} 块 -> {OUTPUT_FILE}")


# ============================================================
# TVer 自动获取锚点
# ============================================================

FETCH_SCRIPT = Path(__file__).resolve().parent / "tver_fetch_url.py"


# ── playlist 解析 ───────────────────────────────────────────────────────

PDT_RE = re.compile(r"#EXT-X-PROGRAM-DATE-TIME:(.+)")
EXTINF_RE = re.compile(r"#EXTINF:([\d.]+)")


def parse_playlist(playlist_text: str, base_url: str) -> list:
    """解析 VTT playlist，返回 [(url, pdt_utc, duration_sec), ...]"""
    segments = []
    current_pdt = None
    current_duration = None

    for line in playlist_text.splitlines():
        line = line.strip()
        m = PDT_RE.match(line)
        if m:
            try:
                current_pdt = datetime.fromisoformat(
                    m.group(1).replace("Z", "+00:00"))
            except ValueError:
                pass
            continue

        m = EXTINF_RE.match(line)
        if m:
            try:
                current_duration = float(m.group(1))
            except ValueError:
                pass
            continue

        if line and not line.startswith("#"):
            url = urljoin(base_url, line)
            segments.append((url, current_pdt, current_duration or 0))
            current_pdt = None
            current_duration = None

    return segments


def fetch_playlist(playlist_url: str, headers: dict) -> list:
    """下载并解析 VTT playlist"""
    req = urllib.request.Request(playlist_url, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as resp:
        text = resp.read().decode("utf-8", errors="ignore")
    return parse_playlist(text, playlist_url)


def extract_id_from_url(url: str) -> int:
    """从 VTT URL 提取数字 ID（最后一段数字）"""
    qmark = url.find("?")
    path_part = url[:qmark] if qmark != -1 else url
    match = re.search(r"(\d+)\.vtt$", path_part)
    if match:
        return int(match.group(1))
    matches = list(re.finditer(r"\d+", path_part))
    if matches:
        return int(matches[-1].group())
    return 0


def resolve_tver_anchor(tver_page_url: str, timeout: int = 60):
    """通过 tver_fetch_url.py 获取字幕 playlist，返回 (锚点URL, playlist URL)。"""
    print("[ANCHOR] 正在从 TVer 获取流地址...")
    py = sys.executable
    result = subprocess.run(
        [py, str(FETCH_SCRIPT), tver_page_url, "--timeout", str(timeout), "--json"],
        capture_output=True, text=True, timeout=timeout + 30,
    )
    if result.returncode != 0 or not result.stdout.strip():
        err = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"tver_fetch_url 失败: {err}")
    info = json.loads(result.stdout.strip())

    sub_url = info.get("subtitle_url")
    if not sub_url:
        raise RuntimeError("当前节目没有字幕轨道")

    print(f"[ANCHOR] 下载字幕 playlist...")
    req = urllib.request.Request(sub_url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            playlist_text = resp.read().decode("utf-8", errors="ignore")
    except Exception as e:
        raise RuntimeError(f"字幕 playlist 下载失败: {e}")

    if "#EXTM3U" not in playlist_text and "#EXTINF" not in playlist_text:
        raise RuntimeError("字幕 playlist 不是有效 m3u8")

    anchor = None
    for line in playlist_text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            anchor = urljoin(sub_url, line)
            if "arib-vtt" in anchor:
                break

    if not anchor:
        raise RuntimeError("字幕 playlist 中没有分段")

    print(f"[ANCHOR] 锚点 URL: {anchor[:120]}...")
    return anchor, sub_url


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="下载并合并 VTT 字幕文件")
    parser.add_argument("--tver-page", help="TVer 直播页面 URL, 自动获取字幕 (如 https://tver.jp/live/tbs)")
    parser.add_argument("--start-url", help="起始 URL")
    parser.add_argument("--end-url", help="结束 URL")
    parser.add_argument("--url", help="参考 URL（配合 --before/--after 使用）")
    parser.add_argument("--duration", type=float, help="持续时间（分钟）")
    parser.add_argument("--before", type=float, default=0, help="参考点之前的分钟数")
    parser.add_argument("--after", type=float, default=0, help="参考点之后的分钟数")
    parser.add_argument("--output", help="输出文件名（默认: merged_shifted.vtt）")
    parser.add_argument("--keep", action="store_true", help="保留临时 vtt_files 目录")
    parser.add_argument("--time-start", help="起始时间 (HH:MM, 本地时间)")
    parser.add_argument("--time-end", help="结束时间 (HH:MM, 本地时间)")
    parser.add_argument("--no-srt", action="store_true", help="跳过 SRT 转换")
    parser.add_argument("--fetch-timeout", type=int, default=60, help="获取 m3u8 链接的超时秒数 (默认: 60)")
    args = parser.parse_args()

    try:
        if args.tver_page:
            if not (args.time_start and args.time_end):
                parser.error("--tver-page 需要 --time-start + --time-end")

            if not FETCH_SCRIPT.exists():
                print(f"错误: 找不到 {FETCH_SCRIPT}", file=sys.stderr)
                sys.exit(1)

            try:
                anchor_url, playlist_url = resolve_tver_anchor(
                    args.tver_page, timeout=args.fetch_timeout)
            except Exception as e:
                print(f"错误: {e}", file=sys.stderr)
                sys.exit(1)

            main_live_window(anchor_url, args.time_start,
                             args.time_end, args.output,
                             playlist_url=playlist_url)

        elif args.url and args.time_start and args.time_end:
            main_timewindow(args.url, args.time_start, args.time_end, args.output)
        elif args.url and (args.before > 0 or args.after > 0):
            main_around(args.url, args.before, args.after, args.output)
        elif args.start_url and args.end_url and not args.duration:
            main_range(args.start_url, args.end_url, args.output)
        elif args.start_url and args.duration and not args.end_url:
            main_start(args.start_url, args.duration, args.output)
        elif args.end_url and args.duration and not args.start_url:
            main_end(args.end_url, args.duration, args.output)
        else:
            parser.error(
                "请使用以下组合之一:\n"
                "  --tver-page + --time-start + --time-end (自动获取)\n"
                "  --start-url + --end-url                (范围模式)\n"
                "  --start-url + --duration               (从开头提取 N 分钟)\n"
                "  --end-url   + --duration               (从结尾反向提取 N 分钟)\n"
                "  --url + --before + --after             (从参考点前后提取)\n"
                "  --url + --time-start + --time-end      (按现实时间段提取)"
            )

        if not args.no_srt and OUTPUT_FILE.exists():
            if convert_to_srt(OUTPUT_FILE):
                if OUTPUT_FILE.exists():
                    OUTPUT_FILE.unlink()
    finally:
        if not args.keep:
            cleanup()

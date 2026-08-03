#!/usr/bin/env python3
"""
Live HLS recorder with subtitle support and automatic ad skipping.
Downloads video (TS) + subtitles (VTT), skips SCTE35-marked ads,
merges video to MP4 and subtitles to SRT with corrected timing.
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import urlparse, urlunparse

import requests
import m3u8
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad

SEGMENT_EXT = ".ts"
HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}


def timestamp():
    return datetime.now().strftime("%H:%M:%S")


# ── variant scanning ──────────────────────────────────────────────────────────

def probe_variant_resolution(m3u8_url):
    import subprocess
    import tempfile

    resp = requests.get(m3u8_url, headers=HEADERS, timeout=15)
    resp.raise_for_status()
    playlist = m3u8.loads(resp.text, uri=m3u8_url)
    if not playlist.segments:
        return None

    seg = playlist.segments[0]
    key_info = None
    if seg.key and seg.key.method == "AES-128":
        iv_str = seg.key.iv or f"0x{playlist.media_sequence:032x}"
        key_info = (seg.key.uri, iv_str)

    seg_resp = requests.get(seg.uri, timeout=15)
    data = seg_resp.content
    if key_info:
        key_uri, iv_str = key_info
        key_resp = requests.get(key_uri, timeout=10)
        key = key_resp.content
        iv = int(iv_str, 16).to_bytes(16, "big")
        cipher = AES.new(key, AES.MODE_CBC, iv=iv)
        data = unpad(cipher.decrypt(data), AES.block_size)

    tmp = tempfile.NamedTemporaryFile(suffix=".ts", delete=False)
    tmp.write(data)
    tmp_path = tmp.name
    tmp.close()

    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "stream=width,height,codec_name",
         "-of", "csv=p=0", tmp_path],
        capture_output=True, text=True,
    )
    os.unlink(tmp_path)

    max_pixels, best_w, best_h = 0, 0, 0
    for line in result.stdout.strip().split("\n"):
        parts = line.split(",")
        if len(parts) >= 3 and parts[0] in ("h264", "hevc", "mpeg2video"):
            try:
                w, h = int(parts[1]), int(parts[2])
                pixels = w * h
                if pixels > max_pixels:
                    max_pixels, best_w, best_h = pixels, w, h
            except ValueError:
                pass
    return (max_pixels, best_w, best_h) if max_pixels > 0 else None


def select_best_variant(url):
    parsed = urlparse(url)
    match = re.match(r"^(.*/)(\d+)\.m3u8$", parsed.path)
    if not match:
        return url, None
    base_path = match.group(1)

    print(f"[{timestamp()}] 扫描可用画质...")
    best_url, best_pixels, best_w, best_h = url, 0, 0, 0
    for v in range(10):
        variant_url = urlunparse(parsed._replace(path=f"{base_path}{v}.m3u8"))
        try:
            result = probe_variant_resolution(variant_url)
            if result:
                pixels, w, h = result
                print(f"  变体 {v}.m3u8 -> {w}x{h} ({pixels} pixels)")
                if pixels > best_pixels:
                    best_pixels, best_w, best_h = pixels, w, h
                    best_url = variant_url
        except Exception:
            if v > 3:
                break
            continue

    if best_pixels > 0:
        print(f"[{timestamp()}] 选择最高画质: {best_url.split('/')[-1].split('?')[0]} ({best_w}x{best_h})")
    else:
        print(f"[{timestamp()}] 未找到可用变体，使用原始 URL")
    return best_url, base_path


def check_subtitle_playlist(url):
    """Return url if it is a usable subtitle m3u8 playlist (contains .vtt segments), else None."""
    try:
        resp = requests.get(url, headers=HEADERS, timeout=10)
        if resp.status_code != 200:
            return None
        playlist = m3u8.loads(resp.text, uri=url)
        if playlist.segments and ".vtt" in playlist.segments[0].uri.lower():
            return url
    except Exception:
        pass
    return None


def find_subtitle_variant(base_path, parsed_url):
    # Convention guess: subtitle track lives next to the video variant as 3.m3u8
    return check_subtitle_playlist(
        urlunparse(parsed_url._replace(path=f"{base_path}3.m3u8"))
    )


def find_nearest_time(pdt, pdt_to_time):
    """Find the video output time for a given PDT. Returns 0 if not found."""
    if not pdt_to_time:
        return 0.0
    # Find the closest PDT that is <= the target PDT
    best_pdt = None
    best_time = 0.0
    for tp, t in pdt_to_time.items():
        if tp <= pdt:
            if best_pdt is None or tp > best_pdt:
                best_pdt = tp
                best_time = t
    return best_time

VTT_TIMING_RE = re.compile(
    r"(\d{1,3}:\d{2}:\d{2}[.,]\d{3})\s*-->\s*(\d{1,3}:\d{2}:\d{2}[.,]\d{3})"
)


def clean_vtt_text(text: str) -> str:
    text = re.sub(r"<rt>.*?</rt>", "", text)
    text = re.sub(r"</?ruby>", "", text)
    text = re.sub(r"</?c[^>]*>", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&nbsp;", " ")
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()


def parse_vtt_time(t):
    parts = t.strip().split(":")
    if len(parts) == 3:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2].replace(",", "."))
    return int(parts[0]) * 60 + float(parts[1].replace(",", "."))


def secs_to_vtt_time(sec):
    if sec < 0:
        sec = 0
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def parse_vtt_content(text):
    cues = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if VTT_TIMING_RE.search(lines[i].strip()):
            break
        i += 1
    while i < len(lines):
        line = lines[i].strip()
        m = VTT_TIMING_RE.search(line)
        if m:
            start = parse_vtt_time(m.group(1))
            end = parse_vtt_time(m.group(2))
            i += 1
            text_lines = []
            while i < len(lines) and lines[i].strip() != "":
                t = lines[i].strip()
                if not t.startswith("NOTE"):
                    text_lines.append(t)
                i += 1
            cue_text = clean_vtt_text("".join(text_lines))
            if cue_text:
                cues.append((start, end, cue_text))
        else:
            i += 1
    return cues


# ── SCTE35 ad tracker ──────────────────────────────────────────────────────

DATERANGE_RE = re.compile(r'#EXT-X-DATERANGE:(.+)$')
ATTR_RE = re.compile(r'(\w[\w-]*)=(?:"([^"]*)"|(0x[0-9A-Fa-f]+|\d+\.?\d*))')


def parse_daterange_attrs(line):
    attrs = {}
    m = DATERANGE_RE.search(line)
    if not m:
        return attrs
    for am in ATTR_RE.finditer(m.group(1)):
        key = am.group(1)
        val = am.group(2) if am.group(2) is not None else am.group(3)
        attrs[key] = val
    return attrs


class AdTracker:
    def __init__(self):
        self.ad_intervals = []          # [(start_dt, end_dt), ...]  wall-clock times
        self.pending_out = None         # (dr_id, start_dt)
        self.pending_planned = None     # (dr_id, start_dt, planned_end_dt) when no IN yet
        self.seen_ids = set()
        self.program_start = None       # wall-clock datetime of program start
        self.main_seg_count = 0
        self.ad_seg_count = 0

    def process_raw_m3u8(self, raw_text):
        new_ad_added = False
        for line in raw_text.split("\n"):
            if 'DATERANGE' not in line:
                continue
            attrs = parse_daterange_attrs(line)
            if not attrs:
                continue

            dr_id = attrs.get("ID")
            start_str = attrs.get("START-DATE")
            if not start_str:
                continue

            try:
                start_dt = datetime.fromisoformat(
                    start_str.replace("Z", "+00:00")
                )
            except ValueError:
                continue

            has_out = "SCTE35-OUT" in attrs
            has_in = "SCTE35-IN" in attrs

            if has_out and dr_id and dr_id not in self.seen_ids:
                self.seen_ids.add(dr_id)
                # TVer sends no SCTE35-IN: a new OUT is the real end of the
                # previous ad (PLANNED-DURATION is only a fallback estimate).
                if self.pending_planned:
                    _, pstart, _ = self.pending_planned
                    if pstart < start_dt:
                        self.ad_intervals.append((pstart, start_dt))
                    self.pending_planned = None
                if self.pending_out:
                    _, pstart = self.pending_out
                    if pstart < start_dt:
                        self.ad_intervals.append((pstart, start_dt))
                    self.pending_out = None
                planned = attrs.get("PLANNED-DURATION")
                if planned:
                    try:
                        planned_sec = float(planned)
                        planned_end = start_dt + timedelta(seconds=planned_sec)
                        self.pending_planned = (dr_id, start_dt, planned_end)
                        print(f"[{timestamp()}] SCTE35 广告开始, 预计 {planned_sec:.0f}s")
                        new_ad_added = True
                    except ValueError:
                        self.pending_out = (dr_id, start_dt)
                        new_ad_added = True
                else:
                    self.pending_out = (dr_id, start_dt)
                    new_ad_added = True

            if has_in and start_dt:
                closed = False
                if self.pending_out:
                    out_id, out_start = self.pending_out
                    if out_start < start_dt:
                        self.ad_intervals.append((out_start, start_dt))
                    self.pending_out = None
                    closed = True
                elif self.pending_planned:
                    _, out_start, _ = self.pending_planned
                    if out_start < start_dt:
                        self.ad_intervals.append((out_start, start_dt))
                    self.pending_planned = None
                    closed = True
                if closed:
                    print(f"[{timestamp()}] SCTE35 广告结束")

    def is_ad_wallclock(self, dt):
        """Check if wall-clock datetime falls within any known ad interval."""
        for start, end in self.ad_intervals:
            if start <= dt < end:
                return True
        if self.pending_planned:
            _, pstart, pend = self.pending_planned
            if pstart <= dt < pend:
                return True
        if self.pending_out:
            _, pstart = self.pending_out
            if dt >= pstart:
                return True
        return False

    def get_ad_intervals_program(self):
        """Return ad intervals in program-relative seconds.
        Requires program_start to be set first."""
        if self.program_start is None:
            return []
        intervals = []
        for start, end in self.ad_intervals:
            s = (start - self.program_start).total_seconds()
            e = (end - self.program_start).total_seconds()
            if e > 0:
                intervals.append((max(s, 0), e))
        if self.pending_planned:
            _, pstart, pend = self.pending_planned
            s = (pstart - self.program_start).total_seconds()
            e = (pend - self.program_start).total_seconds()
            if e > 0:
                intervals.append((max(s, 0), e))
        return sorted(intervals)

    def adjust_subtitle_time(self, program_sec):
        """Given a subtitle cue's program-relative time, return the adjusted time
        after removing ad durations, or None if the cue is inside an ad."""
        intervals = self.get_ad_intervals_program()
        total_ad_before = 0.0
        for ad_s, ad_e in intervals:
            if program_sec >= ad_e:
                total_ad_before += (ad_e - ad_s)
            elif program_sec > ad_s:
                return None
        return program_sec - total_ad_before

    def debug_ad_state(self):
        """Print current ad tracking state for debugging."""
        intervals = self.get_ad_intervals_program()
        if intervals:
            for s, e in intervals:
                print(f"  ad: {s:.1f}s ~ {e:.1f}s ({e-s:.1f}s)")
        else:
            print(f"  (无广告时段)")
        if self.program_start:
            print(f"  program_start={self.program_start.isoformat()}")


# ── video recorder ────────────────────────────────────────────────────────

class VideoRecorder:
    def __init__(self, m3u8_url, output_path, ad_tracker,
                 concurrency=8, poll_interval=2.0):
        self.m3u8_url = m3u8_url
        self.output_path = output_path
        self.ad_tracker = ad_tracker
        self.concurrency = concurrency
        self.poll_interval = poll_interval
        self.segments = {}          # {seq: (filepath, is_ad)}
        self.segment_data = {}       # {seq: (filepath, is_ad, pdt, duration)}
        self.seen_sequences = set()
        self.missing_seqs = set()    # seqs whose download ultimately failed
        self.segment_meta = {}       # {seq: is_ad} for missing-seg reporting
        self.first_pdt = None       # PDT of first downloaded segment
        self.first_main_pdt = None   # PDT of first MAIN-content segment
        self.key_cache = {}
        self.running = True
        self.lock = threading.Lock()
        self.temp_dir = Path.cwd() / f".live_video_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    def fetch_key(self, key_uri):
        if key_uri in self.key_cache:
            return self.key_cache[key_uri]
        for attempt in range(3):
            try:
                resp = requests.get(key_uri, headers=HEADERS, timeout=10)
                resp.raise_for_status()
                key = resp.content
                if len(key) != 16:
                    raise ValueError(f"密钥长度异常: {len(key)}")
                self.key_cache[key_uri] = key
                return key
            except Exception as e:
                if attempt == 2:
                    raise e
                time.sleep(1)

    def download_segment(self, seq, url, is_ad, key_info=None, pdt=None, duration=None):
        for attempt in range(3):
            try:
                resp = requests.get(url, headers=HEADERS, timeout=15)
                resp.raise_for_status()
                data = resp.content
                if key_info:
                    key_uri, iv_str = key_info
                    key = self.fetch_key(key_uri)
                    iv = int(iv_str, 16).to_bytes(16, "big")
                    cipher = AES.new(key, AES.MODE_CBC, iv=iv)
                    data = unpad(cipher.decrypt(data), AES.block_size)

                filepath = self.temp_dir / f"{seq:012d}{SEGMENT_EXT}"
                filepath.write_bytes(data)
                with self.lock:
                    self.segments[seq] = (str(filepath), is_ad)
                    self.segment_data[seq] = (str(filepath), is_ad, pdt, duration or 0)

                tag = "[广告]" if is_ad else "[正片]"
                size_mb = len(data) / (1024 * 1024)
                print(f"[{timestamp()}] 视频: seq={seq} {tag} ({size_mb:.2f}MB)")
                return seq
            except Exception as e:
                if attempt == 2:
                    print(f"[{timestamp()}] 视频下载失败 seq={seq}: {e}")
                    return None
                time.sleep(1)
        return None

    def merge(self):
        """Merge main-content segments. Returns (success, pdt_to_time_map)."""
        if not self.segments:
            return False, None

        sorted_seqs = sorted(self.segments.keys())
        main_files = []
        skipped_ad = 0
        pdt_to_time = {}  # {pdt: cumulative_main_seconds}
        cumulative = 0.0

        for seq in sorted_seqs:
            data = self.segment_data.get(seq)
            if data is None:
                data = (self.segments[seq][0], self.segments[seq][1], None, 0)
            filepath, is_ad, pdt, duration = data

            if not is_ad:
                if Path(filepath).exists():
                    main_files.append(filepath)
                    if pdt:
                        pdt_to_time[pdt] = cumulative
                    cumulative += duration
                else:
                    print(f"[{timestamp()}] 警告: 正片片段缺失 seq={seq}")
            else:
                skipped_ad += 1
                if pdt:
                    pdt_to_time[pdt] = cumulative
                # Ad time counts into the mapping: subtitles stay on the
                # real-time axis (overall shift), like download_vtt mode.
                cumulative += duration

        if skipped_ad:
            print(f"[{timestamp()}] 跳过 {skipped_ad} 个广告片段")
        missing_main = [s for s in sorted(self.missing_seqs)
                        if not self.segment_meta.get(s, False)]
        if missing_main:
            shown = ", ".join(str(s) for s in missing_main[:20])
            more = f" ...共 {len(missing_main)} 个" if len(missing_main) > 20 else ""
            print(f"[{timestamp()}] 警告: 正片片段缺失 seq={shown}{more}")
        if not main_files:
            print(f"[{timestamp()}] 没有正片片段可合并")
            return False, None

        print(f"[{timestamp()}] 正片共 {len(main_files)} 个片段，开始合并...")
        concat_file = self.temp_dir / "concat_list.txt"
        with open(concat_file, "w") as f:
            for fp in main_files:
                f.write(f"file '{Path(fp).resolve()}'\n")

        import subprocess
        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0",
            "-i", str(concat_file),
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k",
            self.output_path,
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
        except FileNotFoundError:
            print(f"[{timestamp()}] 视频合并失败: 未找到 ffmpeg，请先安装 "
                  f"(brew install ffmpeg) 或确认 PATH 包含 /opt/homebrew/bin")
            return False, None
        if result.returncode == 0:
            out_size = os.path.getsize(self.output_path) / (1024 * 1024)
            print(f"[{timestamp()}] 视频合并完成: {self.output_path} ({out_size:.2f}MB)")
            return True, pdt_to_time
        else:
            print(f"[{timestamp()}] 视频合并失败: {result.stderr}")
            return False, None

    def cleanup(self):
        import shutil
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def run_loop(self):
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        executor = ThreadPoolExecutor(max_workers=self.concurrency)
        pending = {}  # {future: seq} in-flight downloads
        try:
            while self.running:
                # Never block polling on slow downloads: the ~20s HLS sliding
                # window slides past unsubmitted segments while we wait.
                if pending:
                    done, _ = wait(list(pending), timeout=0,
                                   return_when=FIRST_COMPLETED)
                    for future in done:
                        seq = pending.pop(future)
                        try:
                            result = future.result()
                        except Exception:
                            result = None
                        if result is None:
                            with self.lock:
                                self.seen_sequences.discard(seq)
                                self.missing_seqs.add(seq)

                try:
                    resp = requests.get(self.m3u8_url, headers=HEADERS, timeout=15)
                    resp.raise_for_status()
                    raw_text = resp.text
                    playlist = m3u8.loads(raw_text, uri=self.m3u8_url)
                except Exception as e:
                    print(f"[{timestamp()}] 视频列表获取失败: {e}")
                    time.sleep(2)
                    continue

                # Feed SCTE35 data to ad tracker
                self.ad_tracker.process_raw_m3u8(raw_text)

                base_seq = playlist.media_sequence or 0
                new_segs = []
                for i, seg in enumerate(playlist.segments):
                    seq = base_seq + i
                    if seq not in self.seen_sequences:
                        key_info = None
                        if seg.key and seg.key.method == "AES-128":
                            iv_str = seg.key.iv or f"0x{seq:032x}"
                            key_info = (seg.key.uri, iv_str)
                        is_ad = False
                        if seg.program_date_time:
                            is_ad = self.ad_tracker.is_ad_wallclock(
                                seg.program_date_time
                            )
                            if self.first_pdt is None:
                                self.first_pdt = seg.program_date_time
                            if not is_ad and self.first_main_pdt is None:
                                self.first_main_pdt = seg.program_date_time
                            # Set program_start from first segment if not yet set
                            if self.ad_tracker.program_start is None:
                                self.ad_tracker.program_start = (
                                    seg.program_date_time
                                )
                        new_segs.append((seq, seg.uri, is_ad, key_info,
                                        seg.program_date_time, seg.duration))

                for seq, url, is_ad, ki, pdt, dur in new_segs:
                    with self.lock:
                        self.seen_sequences.add(seq)
                        self.segment_meta[seq] = is_ad
                    pending[executor.submit(
                        self.download_segment, seq, url, is_ad, ki, pdt, dur
                    )] = seq

                for _ in range(int(self.poll_interval * 10)):
                    if not self.running:
                        break
                    time.sleep(0.1)
        finally:
            executor.shutdown(wait=True, cancel_futures=True)


# ── subtitle downloader ───────────────────────────────────────────────────

class SubtitleDownloader:
    def __init__(self, m3u8_url, ad_tracker):
        self.m3u8_url = m3u8_url
        self.ad_tracker = ad_tracker
        self.segments = {}       # {seq: filepath}
        self.segment_pdts = {}   # {seq: program_date_time}
        self.seen_sequences = set()
        self.running = True
        self.lock = threading.Lock()
        self.temp_dir = Path.cwd() / f".live_sub_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    def download_vtt(self, seq, url):
        for attempt in range(3):
            try:
                resp = requests.get(url, headers=HEADERS, timeout=15)
                resp.raise_for_status()
                data = resp.content.decode("utf-8", errors="replace")

                filepath = self.temp_dir / f"{seq:012d}.vtt"
                filepath.write_text(data, encoding="utf-8")

                with self.lock:
                    self.segments[seq] = str(filepath)

                print(f"[{timestamp()}] 字幕: seq={seq} ({len(data)} chars)")
                return seq
            except Exception as e:
                if attempt == 2:
                    print(f"[{timestamp()}] 字幕下载失败 seq={seq}: {e}")
                    return None
                time.sleep(1)
        return None

    def merge_to_srt(self, output_path, pdt_to_time=None):
        if not self.segments:
            print(f"[{timestamp()}] 没有字幕片段，跳过")
            return False

        # First pass: count segments with cues
        total_files = len(self.segments)
        files_with_cues = 0
        files_total_cues = 0

        for seq in sorted(self.segments.keys()):
            filepath = self.segments[seq]
            try:
                text = Path(filepath).read_text(encoding="utf-8")
                cues = parse_vtt_content(text)
                if cues:
                    files_with_cues += 1
                    files_total_cues += len(cues)
            except Exception:
                pass

        print(f"[{timestamp()}] 字幕文件: {files_with_cues}/{total_files} 个含有效内容, "
              f"共 {files_total_cues} 条 cue")

        if files_total_cues == 0:
            print(f"[{timestamp()}] 当前时段无字幕内容，跳过")
            return False

        # Build PDT → video output time lookup
        # Each VTT segment at PDT P maps to video output time T (or nearest)
        all_cues = []

        for seq in sorted(self.segments.keys()):
            filepath = self.segments[seq]
            pdt = self.segment_pdts.get(seq)
            try:
                text = Path(filepath).read_text(encoding="utf-8")
                cues = parse_vtt_content(text)
                if not cues:
                    continue

                # Get video output time for this segment's PDT
                base_time = 0.0
                if pdt and pdt_to_time:
                    base_time = find_nearest_time(pdt, pdt_to_time)

                # Shift cues: use first cue's LOCAL time as segment anchor
                first_local = min(c[0] for c in cues)
                for start, end, cue_text in cues:
                    out_start = base_time + (start - first_local)
                    out_end = base_time + (end - first_local)
                    if out_end > 0:
                        all_cues.append((max(out_start, 0), out_end, cue_text))
            except Exception as e:
                print(f"[{timestamp()}] 解析字幕 seq={seq} 失败: {e}")

        # Sort and dedup
        all_cues.sort(key=lambda x: (x[0], x[1]))
        seen = set()
        unique_cues = []
        for s, e, t in all_cues:
            key = (round(s, 3), round(e, 3), t)
            if key not in seen:
                seen.add(key)
                unique_cues.append((s, e, t))

        vtt_lines = ["WEBVTT", ""]
        for _, (start, end, text) in enumerate(unique_cues, 1):
            vtt_lines.append(f"{secs_to_vtt_time(start)} --> {secs_to_vtt_time(end)}")
            vtt_lines.append(text)
            vtt_lines.append("")

        vtt_path = Path(output_path).with_suffix(".tmp.vtt")
        vtt_path.write_text("\n".join(vtt_lines), encoding="utf-8")

        try:
            result = subprocess.run(
                ["ffmpeg", "-y", "-i", str(vtt_path), str(output_path)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"[{timestamp()}] ffmpeg 转换失败: {result.stderr[:200]}")
                vtt_path.unlink(missing_ok=True)
                return False
        except FileNotFoundError:
            print(f"[{timestamp()}] 未找到 ffmpeg，跳过 SRT 转换")
            vtt_path.unlink(missing_ok=True)
            return False

        vtt_path.unlink(missing_ok=True)
        out_size = os.path.getsize(output_path)
        print(f"[{timestamp()}] 字幕合并完成: {output_path} ({out_size} bytes, {len(unique_cues)} 条)")
        return True

    def cleanup(self):
        import shutil
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def run_loop(self):
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        executor = ThreadPoolExecutor(max_workers=4)
        pending = {}  # {future: seq} in-flight downloads
        try:
            while self.running:
                # Same non-blocking reap as the video recorder.
                if pending:
                    done, _ = wait(list(pending), timeout=0,
                                   return_when=FIRST_COMPLETED)
                    for future in done:
                        seq = pending.pop(future)
                        try:
                            result = future.result()
                        except Exception:
                            result = None
                        if result is None:
                            with self.lock:
                                self.seen_sequences.discard(seq)

                try:
                    resp = requests.get(self.m3u8_url, headers=HEADERS, timeout=15)
                    resp.raise_for_status()
                    raw_text = resp.text
                    playlist = m3u8.loads(raw_text, uri=self.m3u8_url)
                except Exception as e:
                    print(f"[{timestamp()}] 字幕列表获取失败: {e}")
                    time.sleep(2)
                    continue

                # Feed SCTE35 to ad tracker
                self.ad_tracker.process_raw_m3u8(raw_text)

                base_seq = playlist.media_sequence or 0
                new_segs = []
                for i, seg in enumerate(playlist.segments):
                    seq = base_seq + i
                    if seq not in self.seen_sequences:
                        new_segs.append((seq, seg.uri, seg.program_date_time))

                for seq, url, pdt in new_segs:
                    with self.lock:
                        self.seen_sequences.add(seq)
                        if pdt:
                            self.segment_pdts[seq] = pdt
                    pending[executor.submit(self.download_vtt, seq, url)] = seq

                for _ in range(20):
                    if not self.running:
                        break
                    time.sleep(0.1)
        finally:
            executor.shutdown(wait=True, cancel_futures=True)


# ── main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="录制 HLS 直播流 + 字幕 (自动跳过广告)")
    parser.add_argument("url", help="m3u8 播放列表地址")
    parser.add_argument("-o", "--output", help="输出视频路径 (默认: output_时间戳.mp4)")
    parser.add_argument("-s", "--subtitle", help="输出字幕路径 (默认: 同视频名.srt)")
    parser.add_argument("--subtitle-url", help="字幕 m3u8 播放列表地址 (默认: 自动查找)")
    parser.add_argument("-c", "--concurrency", type=int, default=8, help="并发下载数 (默认: 8)")
    parser.add_argument("-p", "--poll-interval", type=float, default=2.0, help="轮询间隔秒数 (默认: 2.0)")
    parser.add_argument("-d", "--duration", type=float, help="录制时长 (分)，到时自动停止")
    parser.add_argument("--no-best", action="store_true", help="不自动选择最高画质")
    parser.add_argument("--start-at", metavar="HH:MM", help="延迟到指定时间开始录制 (今日当地时间)")
    args = parser.parse_args()

    if args.start_at:
        parts = args.start_at.split(":")
        if len(parts) not in (2, 3):
            parser.error("--start-at 格式: HH:MM 或 HH:MM:SS")
        try:
            h, m = int(parts[0]), int(parts[1])
            s = int(parts[2]) if len(parts) == 3 else 0
        except ValueError:
            parser.error("--start-at 格式: HH:MM 或 HH:MM:SS")
        now = datetime.now()
        target = now.replace(hour=h, minute=m, second=s, microsecond=0)
        if target <= now:
            target += timedelta(days=1)
            print(f"[{timestamp()}] {args.start_at} 今日已过，自动顺延到明天 "
                  f"{target.strftime('%Y-%m-%d %H:%M:%S')}")
        wait_secs = (target - now).total_seconds()
        print(f"[{timestamp()}] 将在 {target.strftime('%Y-%m-%d %H:%M:%S')} 开始录制 "
              f"(等待 {wait_secs / 3600:.1f} 小时)")
        print(f"[{timestamp()}] 等待中，按 Ctrl+C 取消...")
        try:
            time.sleep(wait_secs)
        except KeyboardInterrupt:
            print(f"\n[{timestamp()}] 已取消")
            return

    video_url = args.url
    base_path = None
    parsed = urlparse(args.url)

    if not args.no_best:
        video_url, base_path = select_best_variant(args.url)
    else:
        m = re.match(r"^(.*/)(\d+)\.m3u8$", parsed.path)
        if m:
            base_path = m.group(1)

    output_video = args.output or f"output_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
    output_sub = args.subtitle or str(Path(output_video).with_suffix(".srt"))

    # Find subtitle variant (explicit URL wins, fall back to convention guessing)
    sub_url = None
    if args.subtitle_url:
        sub_url = check_subtitle_playlist(args.subtitle_url)
        if not sub_url:
            print(f"[{timestamp()}] 指定字幕 URL 无效，尝试自动查找...")
    if not sub_url and base_path:
        sub_url = find_subtitle_variant(base_path, parsed)
    if sub_url:
        print(f"[{timestamp()}] 发现字幕轨道: {sub_url.split('/')[-1].split('?')[0]}")
    else:
        print(f"[{timestamp()}] 未发现字幕轨道，仅录制视频")

    # Shared SCTE35 ad tracker
    ad_tracker = AdTracker()

    # Shared running flag
    running = [True]

    def sig_handler(signum, frame):
        sig_name = signal.Signals(signum).name
        print(f"\n[{timestamp()}] 收到信号 {sig_name}，正在停止录制...")
        running[0] = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    video_rec = VideoRecorder(video_url, output_video, ad_tracker,
                              concurrency=args.concurrency,
                              poll_interval=args.poll_interval)
    video_thread = threading.Thread(target=video_rec.run_loop, daemon=True)

    sub_dl = None
    sub_thread = None
    if sub_url:
        sub_dl = SubtitleDownloader(sub_url, ad_tracker)
        sub_thread = threading.Thread(target=sub_dl.run_loop, daemon=True)

    print(f"[{timestamp()}] 广告跳过: 自动 (SCTE35 检测)")
    if args.duration:
        duration_secs = args.duration * 60
        print(f"[{timestamp()}] 定时停止: {args.duration:.1f} 分钟后自动结束")
    print(f"[{timestamp()}] 开始录制，按 Ctrl+C 停止...")
    print(f"[{timestamp()}] 视频输出: {output_video}")
    if sub_dl:
        print(f"[{timestamp()}] 字幕输出: {output_sub}")

    video_thread.start()
    if sub_thread:
        sub_thread.start()

    # Auto-stop timer
    if args.duration:
        duration_secs = args.duration * 60
        def auto_stop():
            time.sleep(duration_secs)
            if running[0]:
                print(f"\n[{timestamp()}] 定时 {args.duration:.1f} 分钟到达，自动停止...")
                running[0] = False
        threading.Thread(target=auto_stop, daemon=True).start()

    try:
        while running[0]:
            time.sleep(0.5)
    except KeyboardInterrupt:
        running[0] = False

    video_rec.running = False
    if sub_dl:
        sub_dl.running = False

    print(f"\n[{timestamp()}] 等待线程结束...")
    video_thread.join(timeout=30)
    if sub_thread:
        sub_thread.join(timeout=30)

    # Merge video (skips ads)
    main_count = sum(1 for fp, ad in video_rec.segments.values() if not ad)
    ad_count = sum(1 for fp, ad in video_rec.segments.values() if ad)
    print(f"[{timestamp()}] 下载统计: {main_count} 正片 + {ad_count} 广告")
    pdt_to_time = None
    if video_rec.segments:
        success, pdt_to_time = video_rec.merge()
        if success:
            video_rec.cleanup()
        else:
            print(f"[{timestamp()}] 视频合并失败，临时文件: {video_rec.temp_dir}")
    else:
        video_rec.cleanup()

    # Merge subtitles (uses video output timeline for alignment)
    if sub_dl and sub_dl.segments:
        sub_dl.merge_to_srt(output_sub, pdt_to_time)
        sub_dl.cleanup()

    # Ad report
    intervals = ad_tracker.get_ad_intervals_program()
    if intervals:
        total_ad = sum(e - s for s, e in intervals)
        print(f"[{timestamp()}] 广告统计: {len(intervals)} 段, 共 {total_ad:.1f}s")
    print(f"[{timestamp()}] 录制结束")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
radiko radio stream recorder with native API authentication.
Downloads HLS audio segments and merges to a single audio file.

用法:
  .venv/bin/python radiko_recorder.py QRR -o radio.m4a -d 30
  .venv/bin/python radiko_recorder.py QRR --start-at 21:00 -d 60 -o radio.m4a
"""

import argparse
import base64
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urljoin

import requests

HEADERS_BASE = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/128.0.0.0 Safari/537.36"
    ),
    "X-Radiko-App": "pc_html5",
    "X-Radiko-App-Version": "0.0.1",
    "X-Radiko-Device": "pc",
    "X-Radiko-User": "test-stream",
}

# Extracted from radiko player JS (playerCommon.js)
AUTH_KEY = "bcd151073c03b352e1ef2fd66c32209da9ca0afa"

SEGMENT_EXT = ".aac"


def timestamp():
    return datetime.now().strftime("%H:%M:%S")


# ── Authentication ──────────────────────────────────────────────────────

class RadikoAuth:
    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update(HEADERS_BASE)
        adapter = requests.adapters.HTTPAdapter(max_retries=5)
        self.session.mount("https://", adapter)
        self.auth_token = None
        self.partial_key = None

    def login(self):
        resp = self.session.get("https://radiko.jp/v2/api/auth1", timeout=15)
        resp.raise_for_status()

        self.auth_token = resp.headers.get("x-radiko-authtoken")
        key_length = int(resp.headers.get("x-radiko-keylength", "0"))
        key_offset = int(resp.headers.get("x-radiko-keyoffset", "0"))

        if not self.auth_token:
            raise RuntimeError("auth1: 未返回 authtoken")

        key_buffer = bytes(ord(c) for c in AUTH_KEY)
        partial_bytes = key_buffer[key_offset:key_offset + key_length]
        partial = base64.b64encode(partial_bytes).decode()

        resp2 = self.session.get(
            "https://radiko.jp/v2/api/auth2",
            headers={
                "x-radiko-authtoken": self.auth_token,
                "x-radiko-keylength": str(key_length),
                "x-radiko-keyoffset": str(key_offset),
                "x-radiko-partialkey": partial,
            },
            timeout=15,
        )
        resp2.raise_for_status()
        self.partial_key = base64.b64encode(resp2.content).decode("utf-8")
        print(f"[{timestamp()}] radiko 认证成功")
        return True

    def get_headers(self):
        return {
            "x-radiko-authtoken": self.auth_token,
            "x-radiko-partialkey": self.partial_key,
        }


# ── Stream fetcher ───────────────────────────────────────────────────────

def resolve_medialist_url(auth: RadikoAuth, station_id: str) -> str | None:
    url = f"https://radiko.jp/v2/station/stream_smh_multi/{station_id}.xml"
    resp = auth.session.get(url, headers=auth.get_headers(), timeout=15)
    resp.raise_for_status()

    root = ET.fromstring(resp.text)
    for url_elem in root.findall(".//url"):
        create_elem = url_elem.find("playlist_create_url")
        if create_elem is not None and create_elem.text:
            variant_url = create_elem.text

            resp2 = auth.session.get(
                variant_url, headers=auth.get_headers(), timeout=15)
            resp2.raise_for_status()

            for line in resp2.text.splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    return urljoin(variant_url, line)

    raise RuntimeError("未找到 medialist URL")


def fetch_segment_urls(auth: RadikoAuth, medialist_url: str) -> list[str]:
    resp = auth.session.get(
        medialist_url, headers=auth.get_headers(), timeout=15)
    resp.raise_for_status()
    segments = []
    for line in resp.text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            segments.append(urljoin(medialist_url, line))
    return segments


# ── Recorder ─────────────────────────────────────────────────────────────

class RadikoRecorder:
    def __init__(self, station_id: str, output_path: str, duration_min: float,
                 concurrency: int = 4, save_segments: bool = False):
        self.station_id = station_id
        self.output_path = Path(output_path)
        self.duration_sec = duration_min * 60
        self.concurrency = concurrency
        self.save_segments = save_segments
        self.auth = RadikoAuth()
        self.medialist_url = None
        self.seen_urls = set()
        self.downloaded = []
        self.running = True
        self.temp_dir = Path.cwd() / \
            f".radiko_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    def download_one(self, url: str) -> str | None:
        for attempt in range(3):
            try:
                resp = self.auth.session.get(
                    url, headers=self.auth.get_headers(), timeout=10)
                resp.raise_for_status()
                data = resp.content
                if len(data) < 100:
                    continue

                idx = len(self.downloaded)
                filepath = self.temp_dir / f"{idx:06d}{SEGMENT_EXT}"
                filepath.write_bytes(data)
                self.downloaded.append((str(filepath), url))
                print(f"[{timestamp()}] ↓ {len(data)}B  {url[-60:]}",
                      file=sys.stderr)
                return str(filepath)
            except Exception as e:
                if attempt == 2:
                    print(f"[{timestamp()}] 下载失败: {e}", file=sys.stderr)
                    return None
                time.sleep(1)
        return None

    def merge(self) -> bool:
        if not self.downloaded:
            return False

        concat_file = self.temp_dir / "concat_list.txt"
        with open(concat_file, "w") as f:
            for fp, _ in self.downloaded:
                f.write(f"file '{Path(fp).resolve()}'\n")

        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0",
            "-i", str(concat_file),
            "-c:a", "copy",
            str(self.output_path),
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"[{timestamp()}] ffmpeg 错误: {result.stderr[:200]}")
                return False
            size_mb = self.output_path.stat().st_size / (1024 * 1024)
            print(f"[{timestamp()}] 合并完成: {self.output_path} ({size_mb:.2f}MB)")
            return True
        except FileNotFoundError:
            print("[{timestamp()}] 未找到 ffmpeg，跳过合并")
            return False

    def cleanup(self):
        import shutil
        if self.temp_dir.exists() and not self.save_segments:
            shutil.rmtree(self.temp_dir, ignore_errors=True)
        elif self.save_segments:
            print(f"[{timestamp()}] 保留临时文件: {self.temp_dir}")

    def run(self):
        self.temp_dir.mkdir(parents=True, exist_ok=True)

        self.auth.login()
        self.medialist_url = resolve_medialist_url(self.auth, self.station_id)
        print(f"[{timestamp()}] 段列表: {self.medialist_url[:120]}...")

        start_time = time.time()
        executor = ThreadPoolExecutor(max_workers=self.concurrency)

        try:
            while self.running:
                elapsed = time.time() - start_time
                if elapsed >= self.duration_sec:
                    print(f"[{timestamp()}] 已达 {self.duration_sec / 60:.1f} 分钟，停止")
                    break

                try:
                    urls = fetch_segment_urls(self.auth, self.medialist_url)
                except Exception as e:
                    print(f"[{timestamp()}] 列表获取失败: {e}")
                    time.sleep(2)
                    continue

                new_urls = [u for u in urls if u not in self.seen_urls]
                if new_urls:
                    self.seen_urls.update(new_urls)
                    futures = {
                        executor.submit(self.download_one, u): u
                        for u in new_urls
                    }
                    for future in as_completed(futures):
                        future.result()

                time.sleep(1.0)

        finally:
            executor.shutdown(wait=True, cancel_futures=True)

        print(f"[{timestamp()}] 下载 {len(self.downloaded)} 个片段")
        if self.downloaded:
            self.merge()
        self.cleanup()


# ── main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="录制 radiko 广播流")
    parser.add_argument("station", help="电台 ID, 如 QRR, TBS, FMT, BAYFM78")
    parser.add_argument("-o", "--output", required=True,
                        help="输出文件路径 (建议 .m4a)")
    parser.add_argument("-d", "--duration", type=float, required=True,
                        help="录制时长 (分)")
    parser.add_argument("-c", "--concurrency", type=int, default=4,
                        help="并发下载数 (默认: 4)")
    parser.add_argument("-s", "--save-segments", action="store_true",
                        help="保留临时分段文件 (用于调试)")
    parser.add_argument("--start-at", metavar="HH:MM",
                        help="延迟到指定时间开始录制 (今日当地时间)")
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

    recorder = RadikoRecorder(
        station_id=args.station,
        output_path=args.output,
        duration_min=args.duration,
        concurrency=args.concurrency,
        save_segments=args.save_segments,
    )

    running = [True]

    def sig_handler(signum, frame):
        sig_name = signal.Signals(signum).name
        print(f"\n[{timestamp()}] 收到 {sig_name}，停止中...")
        running[0] = False
        recorder.running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    print(f"[{timestamp()}] 开始录制 {args.station}, {args.duration} 分钟 → {args.output}")
    recorder.run()
    print(f"[{timestamp()}] 录制结束")


if __name__ == "__main__":
    main()

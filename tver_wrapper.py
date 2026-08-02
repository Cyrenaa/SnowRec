#!/usr/bin/env python3
"""
TVer 直播录制定时包装器。
等待到指定时间 → 自动从 TVer 获取新鲜 m3u8 链接 → 调用 live_recorder_sub.py 录制。

用法:
  .venv/bin/python tver_wrapper.py \
    --tver-page https://tver.jp/live/tbs \
    --start-at 21:00 \
    --duration 30 \
    -o tbs_night.mp4

长时间挂载 (防系统休眠):
  caffeinate -s .venv/bin/python tver_wrapper.py --tver-page ... --start-at 21:00 --duration 30
"""

import argparse
import json
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
FETCH_SCRIPT = SCRIPT_DIR / "tver_fetch_url.py"
RECORD_SCRIPT = SCRIPT_DIR / "live_recorder_sub.py"
PYTHON = sys.executable


def timestamp():
    return datetime.now().strftime("%H:%M:%S")


def main():
    parser = argparse.ArgumentParser(
        description="TVer 定时录制包装器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  .venv/bin/python tver_wrapper.py --tver-page https://tver.jp/live/tbs --start-at 21:00 --duration 30 -o tbs.mp4
  caffeinate -s .venv/bin/python tver_wrapper.py --tver-page https://tver.jp/live/tbs --start-at 21:00 --duration 30
""",
    )
    parser.add_argument("--tver-page", required=True,
                        help="TVer 直播页面 URL, 如 https://tver.jp/live/tbs")
    parser.add_argument("--start-at", metavar="HH:MM",
                        help="延迟到指定时间开始录制 (今日当地时间)")
    parser.add_argument("-d", "--duration", type=float,
                        help="录制时长 (分)，到时自动停止")
    parser.add_argument("-o", "--output",
                        help="输出视频路径 (默认: output_时间戳.mp4)")
    parser.add_argument("-s", "--subtitle",
                        help="输出字幕路径 (默认: 同视频名.srt)")
    parser.add_argument("-c", "--concurrency", type=int, default=8,
                        help="并发下载数 (默认: 8)")
    parser.add_argument("-p", "--poll-interval", type=float, default=2.0,
                        help="轮询间隔秒数 (默认: 2.0)")
    parser.add_argument("--fetch-timeout", type=int, default=60,
                        help="获取 m3u8 链接的超时秒数 (默认: 60)")
    args = parser.parse_args()

    if not RECORD_SCRIPT.exists():
        print(f"错误: 找不到 {RECORD_SCRIPT}", file=sys.stderr)
        sys.exit(1)
    if not FETCH_SCRIPT.exists():
        print(f"错误: 找不到 {FETCH_SCRIPT}", file=sys.stderr)
        sys.exit(1)

    # ── 定时等待 ────────────────────────────────────────────────────────
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

    # ── 获取 m3u8 ───────────────────────────────────────────────────────
    print(f"[{timestamp()}] 正在从 TVer 获取流地址...")
    try:
        result = subprocess.run(
            [PYTHON, str(FETCH_SCRIPT), args.tver_page,
             "--timeout", str(args.fetch_timeout), "--json"],
            capture_output=True, text=True, timeout=args.fetch_timeout + 30,
        )
        if result.returncode != 0:
            print(f"[{timestamp()}] 获取失败:")
            print(result.stderr.strip())
            sys.exit(1)
        info = json.loads(result.stdout.strip())
    except subprocess.TimeoutExpired:
        print(f"[{timestamp()}] 获取超时", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError:
        print(f"[{timestamp()}] 解析输出失败: {result.stdout[:200]}", file=sys.stderr)
        sys.exit(1)

    video_url = info.get("video_url")
    if not video_url:
        print(f"[{timestamp()}] 未获取到视频流地址", file=sys.stderr)
        sys.exit(1)

    print(f"[{timestamp()}] 视频: {info.get('video_res', '?')}")
    print(f"[{timestamp()}] 视频 URL: {video_url[:100]}...")
    if info.get("subtitle_url"):
        print(f"[{timestamp()}] 字幕: {info['subtitle_url'][:100]}...")

    # ── 启动录制 ───────────────────────────────────────────────────────
    cmd = [
        PYTHON, str(RECORD_SCRIPT), video_url,
        "--no-best",
    ]
    if args.duration:
        cmd.extend(["-d", str(args.duration)])
    if args.output:
        cmd.extend(["-o", args.output])
    if args.subtitle:
        cmd.extend(["-s", args.subtitle])
    if info.get("subtitle_url"):
        cmd.extend(["--subtitle-url", info["subtitle_url"]])
    if args.concurrency:
        cmd.extend(["-c", str(args.concurrency)])
    if args.poll_interval:
        cmd.extend(["-p", str(args.poll_interval)])

    print(f"[{timestamp()}] 启动录制: {' '.join(cmd)}")
    print("-" * 50)

    # Forward signals to child
    proc = None

    def sig_handler(signum, frame):
        if proc:
            proc.send_signal(signum)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    proc = subprocess.Popen(cmd)
    proc.wait()

    print("-" * 50)
    print(f"[{timestamp()}] 录制结束 (退出码: {proc.returncode})")
    sys.exit(proc.returncode)


if __name__ == "__main__":
    main()

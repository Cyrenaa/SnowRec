#!/usr/bin/env python3
"""
YouTube live stream recorder powered by yt-dlp.
Records a live stream from a watch URL (/watch?v=), a live page
(/live), or a channel live page (@channel/live) into a playable MP4.
Supports scheduled start, auto-stop after N minutes, DVR replay from the
stream start (live_from_start), and a cookies file fallback.

用法:
  .venv/bin/python youtube_recorder.py "https://www.youtube.com/watch?v=xxxxx" -d 30 -o out.mp4
  .venv/bin/python youtube_recorder.py "https://www.youtube.com/@NASA/live" --start-at 21:00 -d 60 -o out.mp4
  .venv/bin/python youtube_recorder.py "https://www.youtube.com/watch?v=xxxxx" --cookies cookies.txt

注意事项:
  - 若遇到 403 或“无可用格式”, 请用 --cookies cookies.txt 传入浏览器导出的
    cookies (tv 客户端免 PO Token); 直播开头回看 (live_from_start) 属
    experimental, DVR 上限约 120 小时, 用 --no-live-from-start 关闭。
  - 需要 ffmpeg 用于多流 (视频+音频) 合并, 缺少时仅记录 (WARN) 并继续。
  - 退出码: 0 = 正常结束 (含用户手动停止 / 时长到点); 1 = 致命错误。
"""

import argparse
import os
import shutil
import signal
import sys
import time
from datetime import datetime, timedelta

import yt_dlp
from yt_dlp.utils import DownloadError, GeoRestrictedError, UserNotLive

# Flush prints immediately when stdout is redirected to a file (block
# buffering would hide progress in the launcher log until the buffer fills).
sys.stdout.reconfigure(line_buffering=True)


def timestamp():
    return datetime.now().strftime("%H:%M:%S")


def build_progress_hook(duration_min: float | None, hook_state: dict):
    """Return a progress_hooks callback for yt_dlp.

    Logs download progress every >=10s, prints [DONE] on 'finished', and
    self-terminates via a single SIGINT when the requested duration elapses.
    """
    start_time = None

    def hook(d):
        nonlocal start_time
        status = d.get("status")
        if status == "downloading":
            if start_time is None:
                start_time = time.monotonic()
            dl_elapsed = d.get("elapsed") or 0.0
            if dl_elapsed - hook_state.get("last_log", 0.0) >= 10.0:
                hook_state["last_log"] = dl_elapsed
                mm, ss = divmod(int(dl_elapsed), 60)
                speed = d.get("speed") or 0.0
                print(f"[{timestamp()}] 已录制 {mm:02d}:{ss:02d} "
                      f"{speed / 1024 / 1024:.2f} MB/s")
            if duration_min is not None and not hook_state.get("duration_stop"):
                if time.monotonic() - start_time >= duration_min * 60:
                    print(f"[{timestamp()}] 录制时长已到，停止中...")
                    hook_state["duration_stop"] = True
                    os.kill(os.getpid(), signal.SIGINT)
        elif status == "finished":
            print(f"[{timestamp()}] [DONE] 下载完成")

    return hook


def main():
    parser = argparse.ArgumentParser(description="录制 YouTube 直播流")
    parser.add_argument("url", help="YouTube 直播地址 (watch?v= / /live / @channel/live)")
    parser.add_argument("-o", "--output", help="输出视频路径 (默认: output_时间戳.mp4)")
    parser.add_argument("-d", "--duration", type=float,
                        help="录制时长 (分)，到时自动停止 (缺省: 录到直播结束)")
    parser.add_argument("--start-at", metavar="HH:MM",
                        help="延迟到指定时间开始录制 (今日当地时间)")
    parser.add_argument("--no-live-from-start", action="store_true",
                        help="不从直播开头回看, 从当前时间开始录制 (默认: 直播开头回看)")
    parser.add_argument("--cookies", help="浏览器导出的 cookies 文件路径 (PO Token/地区兜底)")
    parser.add_argument("--wait-for-video", type=float,
                        help="等待预约直播开播的秒数 (超时则失败)")
    args = parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print(f"[{timestamp()}] [WARN] 未检测到 ffmpeg，多流合并将失败")

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
            return 0

    output_path = args.output or f"output_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
    hook_state: dict = {"last_log": 0.0, "duration_stop": False}
    ydl_opts: dict = {
        "format": "bestvideo*+bestaudio/best",
        "outtmpl": output_path,
        "merge_output_format": "mp4",
        "live_from_start": not args.no_live_from_start,
        "hls_use_mpegts": True,
        "progress_hooks": [build_progress_hook(args.duration, hook_state)],
        "quiet": True,
        "no_warnings": False,
        "retries": 3,
        "fragment_retries": 3,
    }
    if args.cookies:
        ydl_opts["cookiefile"] = args.cookies
    if args.wait_for_video:
        ydl_opts["wait_for_video"] = (int(args.wait_for_video), int(args.wait_for_video))

    if args.start_at:
        print(f"[{timestamp()}] 开始录制 {args.url} → {output_path}")
    else:
        print(f"[{timestamp()}] 开始录制 {args.url} → {output_path} (Ctrl+C 停止)")

    def sigterm_handler(signum, frame):
        print(f"\n[{timestamp()}] 收到 SIGTERM，停止中...")
        os.kill(os.getpid(), signal.SIGINT)

    signal.signal(signal.SIGTERM, sigterm_handler)

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([args.url])
            if ydl._download_retcode != 0:
                print(f"[{timestamp()}] [ERR] 下载未完成 (retcode {ydl._download_retcode})",
                      file=sys.stderr)
                return 1
    except KeyboardInterrupt:
        if hook_state["duration_stop"]:
            print(f"[{timestamp()}] 已停止录制")
        else:
            print(f"[{timestamp()}] 收到 Ctrl+C，已停止")
        return 0
    except UserNotLive as e:
        print(f"[{timestamp()}] [ERR] 频道当前未在直播: {e}", file=sys.stderr)
        return 1
    except GeoRestrictedError as e:
        print(f"[{timestamp()}] [ERR] 地区限制: {e}", file=sys.stderr)
        return 1
    except DownloadError as e:
        print(f"[{timestamp()}] [ERR] 下载失败: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"[{timestamp()}] [ERR] 未知错误: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

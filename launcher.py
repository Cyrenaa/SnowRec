#!/usr/bin/env python3
"""
macOS 菜单栏工具：管理 TVer 录制、字幕下载、radiko 广播
"""

import json
import os
import re
import signal
import subprocess
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import rumps

try:
    import AppKit
    AppKit.NSApplication.sharedApplication().setActivationPolicy_(
        AppKit.NSApplicationActivationPolicyAccessory
    )
except Exception:
    pass

SCRIPT_DIR = Path(__file__).resolve().parent
PYTHON = str(SCRIPT_DIR / ".venv" / "bin" / "python3")
DATA_FILE = Path.home() / ".script_launcher.json"
LOG_DIR = Path.home() / ".script_logs"
MAX_HISTORY = 20
MAX_LOG_AGE_DAYS = 7

_DATA = {"presets": [], "history": []}


def _save_data():
    try:
        DATA_FILE.write_text(json.dumps(
            {"presets": _DATA["presets"], "history": _DATA["history"]},
            ensure_ascii=False, indent=2,
        ))
    except Exception:
        pass


def _cleanup_old_logs():
    try:
        if not LOG_DIR.exists():
            return
        cutoff = time.time() - MAX_LOG_AGE_DAYS * 86400
        for f in LOG_DIR.glob("*.log"):
            try:
                if f.stat().st_mtime < cutoff:
                    f.unlink()
                    print(f"[CLEAN] 删除旧日志 {f.name}")
            except OSError:
                pass
    except Exception:
        pass

CHANNELS = {
    "TBS": "https://tver.jp/live/tbs",
    "CX (富士)": "https://tver.jp/live/cx",
    "TX (东京)": "https://tver.jp/live/tx",
    "NTV (日テレ)": "https://tver.jp/live/ntv",
    "EX (朝日)": "https://tver.jp/live/ex",
}

RADIO_STATIONS = ["TBS", "QRR", "FMT", "BAYFM78", "LFR", "JORF", "INT"]


def osa_dialog(title, text, default=""):
    script = f'display dialog "{text}" with title "{title}" default answer "{default}"'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    for part in r.stdout.split(","):
        if "text returned:" in part:
            return part.split("text returned:")[1].strip()
    return None


def osa_choose(title, prompt, items, default=None):
    defaults = f' default items {{"{default}"}}' if default else ""
    items_str = ", ".join(f'"{i}"' for i in items)
    script = (
        f'choose from list {{{items_str}}} with title "{title}"'
        f' with prompt "{prompt}"{defaults}'
    )
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0 or r.stdout.strip() == "false":
        return None
    return r.stdout.strip()


def osa_confirm(title, text):
    script = (
        f'display dialog "{text}" with title "{title}"'
        ' buttons {"确认", "取消"} default button "确认" cancel button "取消"'
    )
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.returncode == 0 and "确认" in r.stdout


class Task:
    def __init__(self, name, cmd):
        self.name = name
        self.cmd = cmd
        self.proc = None
        self.status = "运行中"
        self.thread = None
        self.history_entry = None
        self.started_at = None
        self.log_path = None

    def start(self):
        self.started_at = datetime.now()
        try:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            safe_name = re.sub(r"[^\w\u4e00-\u9fff-]+", "_", self.name)[:40]
            ts = self.started_at.strftime("%Y%m%d_%H%M%S")
            self.log_path = LOG_DIR / f"{ts}_{safe_name}.log"
            log_file = open(self.log_path, "w", encoding="utf-8")
        except Exception:
            log_file = None

        def _run():
            try:
                # GUI 应用继承 launchd 最小 PATH，缺 Homebrew bin，导致 ffmpeg 等找不到
                env = os.environ.copy()
                homebrew_bins = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
                env["PATH"] = homebrew_bins + ":" + env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                self.proc = subprocess.Popen(
                    self.cmd,
                    cwd=SCRIPT_DIR,
                    env=env,
                    stdout=log_file or subprocess.DEVNULL,
                    stderr=log_file or subprocess.DEVNULL,
                    start_new_session=True,
                )
                if self.history_entry is not None:
                    self.history_entry["pid"] = self.proc.pid
                    if self.log_path is not None:
                        self.history_entry["log"] = str(self.log_path)
                    _save_data()
                self.proc.wait()
                rc = self.proc.returncode
                self.status = "成功" if rc == 0 else "失败"
            except Exception:
                self.status = "失败"
            finally:
                self.proc = None
                if log_file:
                    try:
                        log_file.close()
                    except Exception:
                        pass
                if self.history_entry is not None:
                    self.history_entry["status"] = self.status
                    _save_data()

        self.thread = threading.Thread(target=_run, daemon=True)
        self.thread.start()

    def kill(self):
        if self.proc:
            self.proc.terminate()
        self.proc = None
        self.status = "失败"
        if self.history_entry is not None:
            self.history_entry["status"] = "失败"
            _save_data()

    @property
    def menu_title(self):
        return f"  {self.name}  [{self.status}]"


class LauncherApp(rumps.App):
    def __init__(self):
        super().__init__("❄️", quit_button="退出")
        self.tasks = []
        self._load_data()
        self._timer = rumps.Timer(self._tick, 5)
        self._timer.start()

    # ── 持久化 ────────────────────────────────────────────────────────
    def _load_data(self):
        _cleanup_old_logs()
        _DATA["presets"] = []
        _DATA["history"] = []
        try:
            if DATA_FILE.exists():
                data = json.loads(DATA_FILE.read_text())
                # 解析成功才备份，避免把损坏内容覆盖到备份
                import shutil
                try:
                    shutil.copy(DATA_FILE, DATA_FILE.with_suffix(".json.bak"))
                except Exception:
                    pass
                _DATA["presets"] = data.get("presets", [])
                _DATA["history"] = data.get("history", [])
                self._normalize_history()
        except Exception:
            pass

    def _normalize_history(self):
        for h in _DATA["history"]:
            s = h.get("status", "")
            if s in ("运行中", "已启动", "等待启动"):
                h["status"] = "运行"
            elif s == "已完成":
                h["status"] = "成功"
            elif s != "成功" and s != "失败" and s != "运行":
                h["status"] = "失败"

            # 上次会话遗留的"运行"任务：app 重启后无法追踪，视为中断
            if h.get("status") == "运行":
                self._kill_orphan(h)
                h["status"] = "失败"
        _save_data()

    @staticmethod
    def _kill_orphan(h):
        pid = h.get("pid")
        if not pid:
            return
        try:
            os.kill(pid, 0)  # 检查进程是否存在
            os.killpg(pid, signal.SIGTERM)  # 终止整个进程组
            print(f"[RECOVER] 终止上次会话遗留进程组 pid={pid}")
        except (ProcessLookupError, PermissionError):
            pass

    @property
    def presets(self):
        return _DATA["presets"]

    @property
    def history(self):
        return _DATA["history"]

    def _add_history(self, label, cmd, task=None):
        entry = {"label": label, "cmd": cmd, "status": "运行"}
        if task:
            task.history_entry = entry
        _DATA["history"].insert(0, entry)
        _DATA["history"] = _DATA["history"][:MAX_HISTORY]
        _save_data()

    # ── 菜单刷新 ──────────────────────────────────────────────────────
    def _tick(self, _):
        self._rebuild_menu()

    def _rebuild_menu(self):
        items = []
        active = [t for t in self.tasks if t.status in ("运行中", "等待启动")]
        if active:
            items.append(rumps.MenuItem("── 任务 ──"))
            for t in active:
                items.append(rumps.MenuItem(t.menu_title, callback=self._task_info))
            items.append(None)
        else:
            self.tasks = []

        items.append(rumps.MenuItem("📝 下载字幕", callback=self._new_subtitle))
        items.append(rumps.MenuItem("📻 录制广播", callback=self._new_radio))
        items.append(rumps.MenuItem("📺 录制 TVer", callback=self._new_recording))
        items.append(None)

        # 收藏
        preset_items = []
        for p in self.presets:
            preset_items.append(rumps.MenuItem(
                f"  {p['name']}", callback=self._run_preset
            ))
        preset_items.append(rumps.MenuItem("  ➕ 新建收藏...", callback=self._save_preset))
        preset_items.append(rumps.MenuItem("  ✏️ 管理收藏...", callback=self._manage_presets))
        items.append(rumps.MenuItem("⭐ 收藏", callback=None))
        for pi in preset_items:
            items.append(pi)
        items.append(None)

        # 最近
        hist_items = []
        for h in self.history:
            status_tag = f" [{h.get('status', '')}]" if h.get("status") else ""
            hist_items.append(rumps.MenuItem(
                f"  {h['label']}{status_tag}", callback=self._rerun_history
            ))
        if hist_items:
            hist_items.append(rumps.MenuItem("  ❌ 清除全部", callback=self._clear_history))
        else:
            hist_items.append(rumps.MenuItem("  (空)"))
        items.append(rumps.MenuItem("🕐 最近", callback=None))
        for hi in hist_items:
            items.append(hi)

        items.append(None)
        if active:
            items.append(rumps.MenuItem("⏹ 停止全部", callback=self._kill_all))
        items.append(None)
        items.append(rumps.MenuItem("退出", callback=rumps.quit_application))

        self.menu.clear()
        self.menu.update(items)

    # ── 收藏 ──────────────────────────────────────────────────────────
    def _save_preset(self, _):
        atype = osa_choose("新建收藏", "选择类型:", ["下载字幕", "录制广播", "录制 TVer"])
        if not atype:
            return

        if atype == "下载字幕":
            ch = osa_choose("新建收藏 — 字幕", "选择频道:", list(CHANNELS.keys()), default="TBS")
            if not ch:
                return
            time_start = osa_dialog("新建收藏", "开始时间 (HH:MM):", "19:00")
            if not time_start:
                return
            time_end = osa_dialog("新建收藏", "结束时间 (HH:MM):", "20:00")
            if not time_end:
                return
            out_name = osa_dialog("新建收藏", "输出文件名:", f"sub_{ch.lower()}")
            if not out_name:
                return
            pname = osa_dialog("新建收藏", "收藏名称:", f"字幕 {ch} {time_start}")
            if not pname:
                return
            self.presets.append({
                "name": pname, "action": "subtitle",
                "channel": ch, "time_start": time_start,
                "time_end": time_end, "output": out_name,
            })

        elif atype == "录制广播":
            st = osa_choose("新建收藏 — 广播", "选择电台:", RADIO_STATIONS, default="TBS")
            if not st:
                return
            start_at = osa_dialog("新建收藏", "开始时间 (HH:MM):", "21:00")
            if not start_at:
                return
            duration = osa_dialog("新建收藏", "录制时长 (分钟):", "30")
            if not duration:
                return
            out_name = osa_dialog("新建收藏", "输出文件名:", f"radio_{st.lower()}.m4a")
            if not out_name:
                return
            pname = osa_dialog("新建收藏", "收藏名称:", f"广播 {st} {start_at}")
            if not pname:
                return
            self.presets.append({
                "name": pname, "action": "radio",
                "station": st, "start_at": start_at,
                "duration": duration, "output": out_name,
            })

        else:  # 录制 TVer
            ch = osa_choose("新建收藏 — TVer", "选择频道:", list(CHANNELS.keys()), default="TBS")
            if not ch:
                return
            start_at = osa_dialog("新建收藏", "开始时间 (HH:MM):", "21:00")
            if not start_at:
                return
            duration = osa_dialog("新建收藏", "录制时长 (分钟):", "60")
            if not duration:
                return
            out_name = osa_dialog("新建收藏", "输出文件名:", f"{ch.lower()}.mp4")
            if not out_name:
                return
            pname = osa_dialog("新建收藏", "收藏名称:", f"{ch} {start_at}")
            if not pname:
                return
            self.presets.append({
                "name": pname, "action": "tver",
                "channel": ch, "start_at": start_at,
                "duration": duration, "output": out_name,
            })

        _save_data()

    def _manage_presets(self, _):
        if not self.presets:
            osa_dialog("管理收藏", "暂无收藏", "")
            return

        names = [p["name"] for p in self.presets]
        chosen = osa_choose("管理收藏", "选择要管理的收藏:", names)
        if not chosen:
            return

        action = osa_choose("管理收藏", f"对「{chosen}」执行:", ["重命名", "删除"])
        if not action:
            return

        if action == "重命名":
            new_name = osa_dialog("管理收藏", "新的收藏名称:", chosen)
            if not new_name:
                return
            for p in self.presets:
                if p["name"] == chosen:
                    p["name"] = new_name
                    break
            _save_data()
        elif action == "删除":
            if osa_confirm("管理收藏", f"确认删除收藏「{chosen}」？"):
                self.presets = [p for p in self.presets if p["name"] != chosen]
                _save_data()

    def _run_preset(self, sender):
        pname = str(sender.title).strip()
        for p in self.presets:
            if p["name"] != pname:
                continue

            action = p.get("action", "tver")

            if action == "subtitle":
                page_url = CHANNELS.get(p["channel"], "")
                cmd = [
                    "caffeinate", PYTHON, str(SCRIPT_DIR / "download_vtt.py"),
                    "--tver-page", page_url,
                    "--time-start", p["time_start"],
                    "--time-end", p["time_end"],
                    "--output", p["output"],
                ]
                label = f"字幕 {p['channel']} {p['time_start']}-{p['time_end']}"

            elif action == "radio":
                cmd = [
                    "caffeinate", PYTHON, str(SCRIPT_DIR / "radiko_recorder.py"),
                    p["station"],
                    "--start-at", p["start_at"],
                    "-d", str(p["duration"]),
                    "-o", p["output"],
                ]
                label = f"广播 {p['station']} {p['start_at']}-{self._end_time(p['start_at'], float(p['duration']))}"

            else:  # tver
                page_url = CHANNELS.get(p["channel"], "")
                cmd = [
                    "caffeinate", PYTHON, str(SCRIPT_DIR / "tver_wrapper.py"),
                    "--tver-page", page_url,
                    "--start-at", p["start_at"],
                    "-d", str(p["duration"]),
                    "-o", p["output"],
                ]
                label = f"TVer {p['channel']} {p['start_at']}-{self._end_time(p['start_at'], float(p['duration']))}"

            task = Task(p["name"], cmd)
            self.tasks.append(task)
            task.start()
            self._add_history(p["name"], cmd, task=task)
            return

    # ── 历史详情 ──────────────────────────────────────────────────────
    def _rerun_history(self, sender):
        label = re.sub(r"\s*\[.*\]$", "", str(sender.title).strip())
        for h in self.history:
            if h["label"] == label:
                status = h.get("status", "")
                log_path = h.get("log", "")
                info = (
                    f"任务: {h['label']}\n"
                    f"状态: {status if status else '未知'}\n"
                    f"日志: {log_path if log_path else '-'}\n\n"
                    f"命令: {' '.join(str(x) for x in h['cmd'])}"
                )
                info = info.replace('"', '\\"').replace("\n", '\\n')

                script = (
                    f'display dialog "{info}" with title "历史详情"'
                    ' buttons {"再次运行", "关闭"}'
                    ' default button "关闭"'
                    ' cancel button "关闭"'
                )
                result = subprocess.run(
                    ["osascript", "-e", script], capture_output=True, text=True
                )
                if "再次运行" in result.stdout:
                    task = Task(h["label"], h["cmd"])
                    self.tasks.append(task)
                    task.start()
                    self._add_history(h["label"], h["cmd"], task=task)
                return

    def _clear_history(self, _):
        if osa_confirm("清除历史", "确认清除全部历史记录？"):
            self.history.clear()
            _save_data()

    # ── TVer 预约录制 ────────────────────────────────────────────────
    def _new_recording(self, _):
        channels = list(CHANNELS.keys())
        ch = osa_choose("预约 TVer 录制", "选择频道:", channels, default="TBS")
        if not ch:
            return

        page_url = CHANNELS[ch]
        start_at = osa_dialog("预约 TVer 录制", "开始时间 (HH:MM):", "21:00")
        if not start_at:
            return
        duration = osa_dialog("预约 TVer 录制", "录制时长 (分钟):", "60")
        if not duration:
            return
        out_name = osa_dialog("预约 TVer 录制", "输出文件名:", f"{ch.lower()}.mp4")
        if not out_name:
            return

        cmd = [
            "caffeinate", PYTHON, str(SCRIPT_DIR / "tver_wrapper.py"),
            "--tver-page", page_url,
            "--start-at", start_at,
            "-d", duration,
            "-o", out_name,
        ]
        task = Task(f"TVer {ch} {start_at}-{self._end_time(start_at, duration)}", cmd)
        self.tasks.append(task)
        task.start()
        self._add_history(f"TVer {ch} {start_at}", cmd, task=task)

    @staticmethod
    def _end_time(start_at, duration_min):
        try:
            parts = start_at.split(":")
            h, m = int(parts[0]), int(parts[1])
            end = datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
            end += timedelta(minutes=float(duration_min))
            return end.strftime("%H:%M")
        except (ValueError, IndexError):
            return "?"

    # ── 字幕下载 ────────────────────────────────────────────────────
    def _new_subtitle(self, _):
        channels = list(CHANNELS.keys())
        ch = osa_choose("下载字幕", "选择频道:", channels, default="TBS")
        if not ch:
            return

        page_url = CHANNELS[ch]
        time_start = osa_dialog("下载字幕", "开始时间 (HH:MM):", "19:00")
        if not time_start:
            return
        time_end = osa_dialog("下载字幕", "结束时间 (HH:MM):", "20:00")
        if not time_end:
            return
        out_name = osa_dialog("下载字幕", "输出文件名:", f"sub_{ch.lower()}")
        if not out_name:
            return

        cmd = [
            "caffeinate", PYTHON, str(SCRIPT_DIR / "download_vtt.py"),
            "--tver-page", page_url,
            "--time-start", time_start,
            "--time-end", time_end,
            "--output", out_name,
        ]
        task = Task(f"字幕 {ch} {time_start}-{time_end}", cmd)
        self.tasks.append(task)
        task.start()
        self._add_history(f"字幕 {ch} {time_start}-{time_end}", cmd, task=task)

    # ── 广播录制 ────────────────────────────────────────────────────
    def _new_radio(self, _):
        st = osa_choose("录制广播", "选择电台:", RADIO_STATIONS, default="TBS")
        if not st:
            return

        start_at = osa_dialog("录制广播", "开始时间 (HH:MM):", "21:00")
        if not start_at:
            return
        duration = osa_dialog("录制广播", "录制时长 (分钟):", "30")
        if not duration:
            return
        out_name = osa_dialog("录制广播", "输出文件名:", f"radio_{st.lower()}.m4a")
        if not out_name:
            return

        cmd = [
            "caffeinate", PYTHON, str(SCRIPT_DIR / "radiko_recorder.py"),
            st,
            "--start-at", start_at,
            "-d", duration,
            "-o", out_name,
        ]
        task = Task(f"广播 {st} {start_at}-{self._end_time(start_at, duration)}", cmd)
        self.tasks.append(task)
        task.start()
        self._add_history(f"广播 {st} {start_at}", cmd, task=task)

    # ── 任务详情 ────────────────────────────────────────────────────
    def _task_info(self, sender):
        title = re.sub(r"\s*\[.*\]$", "", str(sender.title).strip())
        task = None
        for t in self.tasks:
            if t.name == title:
                task = t
                break
        if not task:
            return

        if task.started_at:
            elapsed = int((datetime.now() - task.started_at).total_seconds())
            elapsed_str = f"{elapsed // 3600}小时{(elapsed % 3600) // 60}分{elapsed % 60}秒"
        else:
            elapsed_str = "-"

        info = (
            f"任务: {task.name}\n"
            f"状态: {task.status}\n"
            f"已运行: {elapsed_str}\n"
            f"日志: {task.log_path if task.log_path else '-'}\n\n"
            f"命令: {' '.join(str(x) for x in task.cmd)}"
        )
        info = info.replace('"', '\\"').replace("\n", '\\n')

        script = (
            f'display dialog "{info}" with title "任务详情"'
            ' buttons {"停止", "关闭"}'
            ' default button "关闭"'
            ' cancel button "关闭"'
        )
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True
        )
        if "停止" in result.stdout and task.status in ("运行中", "等待启动"):
            task.kill()
            self.tasks = [t for t in self.tasks if t.status not in ("已停止",)]
            self._rebuild_menu()

    # ── 停止全部 ────────────────────────────────────────────────────
    def _kill_all(self, _):
        for t in self.tasks:
            if t.status in ("运行中", "等待启动"):
                t.kill()
        self.tasks = [t for t in self.tasks if t.status not in ("已停止",)]
        self._rebuild_menu()


if __name__ == "__main__":
    LauncherApp().run()

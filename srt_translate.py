#!/usr/bin/env python3
"""
Translate Japanese SRT subtitle text into Chinese via the DeepSeek API.
Only subtitle text lines are translated; sequence numbers, timestamps, and
blank lines are reassembled byte-identically.

用法:
  .venv/bin/python srt_translate.py input.srt
  .venv/bin/python srt_translate.py input.srt -o output.srt --model deepseek-v4-flash
"""

import argparse
import json
import os
import re
import signal
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

import requests

# Global fallback: any socket operation (including TLS handshakes through a
# proxy) must time out instead of hanging the process forever.
socket.setdefaulttimeout(20)
# Flush prints immediately when stdout is redirected to a file.
sys.stdout.reconfigure(line_buffering=True)

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/128.0.0.0 Safari/537.36"
    )
}

# Sequence-number line: only digits, optionally a trailing CR (lone-CR files).
_SEQUENCE_RE = re.compile(r"^[0-9]+\r?$")
# Timestamp line: "HH:MM:SS,mmm --> HH:MM:SS,mmm" (comma or dot millis).
_TIMESTAMP_RE = re.compile(
    r"^\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,.]\d{3}"
)


class AuthError(Exception):
    """Raised when the DeepSeek API rejects the credentials (HTTP 401)."""


def timestamp() -> str:
    return datetime.now().strftime("%H:%M:%S")


def parse_srt_lines(text: str) -> list[tuple[str, str, str]]:
    """Split SRT text into (kind, content, terminator) records.

    kind is one of "sequence" | "time" | "blank" | "text". The terminator is
    the line ending ("\\n", "\\r\\n", or "" for the final unterminated line)
    so reassembly can be byte-identical.
    """
    records = []
    for line in text.splitlines(keepends=True):
        # Extract the terminator first; content is the line without it.
        if line.endswith("\r\n"):
            content, terminator = line[:-2], "\r\n"
        elif line.endswith("\n"):
            content, terminator = line[:-1], "\n"
        else:
            content, terminator = line, ""
        # Classify the raw line so a trailing CR inside the line is handled.
        if _SEQUENCE_RE.match(line):
            kind = "sequence"
        elif _TIMESTAMP_RE.match(line):
            kind = "time"
        elif content.strip() == "":
            kind = "blank"
        else:
            kind = "text"
        records.append((kind, content, terminator))
    return records


def split_into_blocks(texts: list[str], block_size: int) -> list[list[str]]:
    """Split a flat list of text lines into consecutive blocks of block_size."""
    return [texts[i : i + block_size] for i in range(0, len(texts), block_size)]


def build_prompt(lines: list[str]) -> tuple[str, str]:
    """Build the (system, user) message pair for one translation block.

    The user prompt must number each line (1. / 2. / ...) and require a JSON
    response shaped like {"translations": [...]} with one entry per line.
    """
    system = (
        "你是一名专业的日文到简体中文字幕翻译专家。请逐行翻译以下字幕文本，"
        "并严格遵守以下规则：\n"
        "1. 只翻译字幕文本本身，不添加任何解释、注释或多余内容；\n"
        "2. 括号内的动作或声音注释按惯例翻译为中文，例如（笑い声）应翻译为（笑声）；\n"
        "3. 括号内的说话人姓名保持原文不变，例如（瀬尾）保持不变；\n"
        "4. 所有输出必须是一个 JSON 对象，禁止输出任何其他内容。"
    )
    numbered = "\n".join("%d. %s" % (i + 1, line) for i, line in enumerate(lines))
    user = (
        "请将下面每一行字幕逐行翻译为中文，并只返回一个 JSON 对象，"
        '格式如下：{"translations": ["第1行翻译", "第2行翻译", ...]}\n'
        "translations 数组中每个元素对应输入的一行，数量必须与输入行数完全一致。\n"
        "输入行：\n"
        + numbered
    )
    return system, user


def call_deepseek(
    api_key: str,
    base_url: str,
    model: str,
    messages: list[dict],
    temperature: float,
    session: requests.Session,
    max_retries: int,
) -> dict:
    """POST a chat-completions request to DeepSeek and return the parsed JSON.

    401 raises AuthError immediately (no retry). 429 sleeps 2s, 5xx/network
    errors and empty content sleep 1s, then retry up to max_retries attempts.
    """
    url = base_url.rstrip("/") + "/chat/completions"
    headers = {
        **HEADERS,
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
    }
    body = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "response_format": {"type": "json_object"},
        "thinking": {"type": "disabled"},
    }
    last_error = "unknown error"
    for attempt in range(max_retries):
        try:
            resp = session.post(url, headers=headers, json=body, timeout=20)
        except requests.RequestException as exc:
            last_error = "network error: %s" % exc
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        if resp.status_code == 401:
            raise AuthError("DeepSeek API 认证失败 (401): invalid api key")
        if resp.status_code == 429:
            last_error = "rate limited (429)"
            if attempt < max_retries - 1:
                time.sleep(2)
            continue
        if resp.status_code >= 500:
            last_error = "server error (HTTP %d)" % resp.status_code
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        try:
            data = resp.json()
        except ValueError:
            last_error = "invalid JSON response"
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        choices = data.get("choices") or []
        if not choices:
            last_error = "response missing choices"
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        choice = choices[0]
        content = (choice.get("message") or {}).get("content") or ""
        if not content.strip():
            last_error = "empty response content"
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        try:
            parsed = json.loads(content)
        except ValueError:
            last_error = "unparseable JSON content"
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        if choice.get("finish_reason") == "length":
            # Truncated output: retry once with a fresh request.
            last_error = "truncated response (finish_reason=length)"
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        return parsed
    raise RuntimeError("DeepSeek API 调用失败: %s" % last_error)


def translate_block(
    api_key: str,
    base_url: str,
    model: str,
    lines: list[str],
    temperature: float,
    session: requests.Session,
    max_retries: int,
) -> list[str]:
    """Translate one block of text lines and return the translated lines.

    Retries when the response lacks one translation per input line; raises
    after max_retries persistent failures so the caller can fall back.
    """
    system, user = build_prompt(lines)
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    last_error = None
    for attempt in range(max_retries):
        try:
            result = call_deepseek(
                api_key, base_url, model, messages, temperature, session, max_retries
            )
        except AuthError:
            raise
        except Exception as exc:
            last_error = exc
            if attempt < max_retries - 1:
                time.sleep(1)
            continue
        translations = result.get("translations")
        if (
            isinstance(translations, list)
            and len(translations) == len(lines)
            and all(isinstance(t, str) for t in translations)
        ):
            return translations
        got = len(translations) if isinstance(translations, list) else "none"
        last_error = RuntimeError(
            "翻译结果数量与输入行数不一致 (expected %d, got %s)" % (len(lines), got)
        )
        if attempt < max_retries - 1:
            time.sleep(1)
        continue
    raise RuntimeError("翻译块失败: %s" % last_error)


def translate_all(
    texts: list[str],
    block_size: int,
    concurrency: int,
    translate_fn,
    running: list[bool],
) -> dict[int, list[str]]:
    """Translate all text lines with a ThreadPoolExecutor, ordered by index.

    Returns {ordinal_text_index: [translated lines]}. `running` is a mutable
    stop flag checked by workers; interrupted work is abandoned. Blocks that
    raise are kept as the original text so the caller can log and move on.
    """
    blocks = split_into_blocks(texts, block_size)
    results = {}
    executor = ThreadPoolExecutor(max_workers=concurrency)
    try:
        future_to_idx = {}
        for idx, block in enumerate(blocks):
            if not running[0]:
                break
            future = executor.submit(translate_fn, block)
            future_to_idx[future] = idx
        for future in as_completed(future_to_idx):
            if not running[0]:
                break
            idx = future_to_idx[future]
            block = blocks[idx]
            start = idx * block_size
            try:
                result_lines = future.result()
            except AuthError:
                # Auth failures are fatal: they never retry and must not be
                # silently downgraded to "keep the original text".
                raise
            except Exception:
                # Keep the original text for this block (caller logs WARN).
                result_lines = block
            # Spread each translation under its global text ordinal so
            # assemble_srt can map it back to the matching text record.
            for j, line in enumerate(result_lines):
                if j >= len(block):
                    break
                results[start + j] = [line]
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    return results


def assemble_srt(
    records: list[tuple[str, str, str]],
    translations: dict[int, list[str]],
) -> str:
    """Reassemble SRT records, substituting translated text at text records.

    translations keys are ordinal indices among the text records only.
    """
    parts = []
    text_index = 0
    for kind, content, terminator in records:
        if kind == "text":
            if text_index in translations:
                content = "\n".join(translations[text_index])
            text_index += 1
        parts.append(content + terminator)
    return "".join(parts)


def load_srt(path: str) -> str:
    """Read an SRT file as text; try utf-8 (with BOM) first, then cp932."""
    with open(path, "rb") as f:
        data = f.read()
    for encoding in ("utf-8-sig", "cp932"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise UnicodeDecodeError(
        "utf-8-sig", data, 0, len(data), "undecodable SRT bytes"
    )


def default_output_path(path: str) -> str:
    """Append a Chinese suffix to the stem, keeping the original extension."""
    p = Path(path)
    return str(p.with_name(p.stem + "中" + p.suffix))


def main():
    parser = argparse.ArgumentParser(
        description="日文 SRT 字幕翻译为中文（DeepSeek API）"
    )
    parser.add_argument("input", help="输入 SRT 文件路径")
    parser.add_argument(
        "-o", "--output", help="输出文件路径（默认在输入文件名后加“中”）"
    )
    parser.add_argument(
        "--model", default="deepseek-v4-flash", help="DeepSeek 模型名称"
    )
    parser.add_argument(
        "--block-size", type=int, default=100, help="每批发送的字幕文本行数"
    )
    parser.add_argument(
        "-c", "--concurrency", type=int, default=4, help="并发翻译批次数"
    )
    parser.add_argument(
        "--temperature", type=float, default=0.2, help="采样温度"
    )
    parser.add_argument("--api-key", help="DeepSeek API 密钥")
    parser.add_argument(
        "--base-url", default="https://api.deepseek.com", help="DeepSeek API 基础地址"
    )
    parser.add_argument(
        "--max-retries", type=int, default=3, help="请求失败最大重试次数"
    )
    args = parser.parse_args()

    api_key = args.api_key or os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        print(
            "[%s] [ERR] 未提供 API 密钥（使用 --api-key 或设置 DEEPSEEK_API_KEY 环境变量）"
            % timestamp(),
            file=sys.stderr,
        )
        sys.exit(1)

    input_path = args.input
    output_path = args.output or default_output_path(input_path)
    if os.path.realpath(input_path) == os.path.realpath(output_path):
        print(
            "[%s] [ERR] 输出路径不能与输入路径相同: %s" % (timestamp(), output_path),
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        text = load_srt(input_path)
    except Exception as exc:
        print(
            "[%s] [ERR] 读取输入文件失败: %s" % (timestamp(), exc),
            file=sys.stderr,
        )
        sys.exit(1)

    records = parse_srt_lines(text)
    text_lines = [content for kind, content, _ in records if kind == "text"]
    blocks = split_into_blocks(text_lines, args.block_size)
    total_blocks = len(blocks)

    if not text_lines:
        # Nothing to translate: no API call is made and no output file is
        # written, so the caller is not misled by an empty artifact.
        print(
            "[%s] [WARN] 输入文件中没有找到任何字幕文本行, 跳过翻译" % timestamp(),
            file=sys.stderr,
        )
        sys.exit(0)

    running = [True]

    def _stop(_signum, _frame):
        running[0] = False

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    # Each worker thread gets its own requests.Session (thread-local).
    thread_local = threading.local()

    def translate_fn(block):
        if getattr(thread_local, "session", None) is None:
            thread_local.session = requests.Session()
        return translate_block(
            api_key=api_key,
            base_url=args.base_url,
            model=args.model,
            lines=block,
            temperature=args.temperature,
            session=thread_local.session,
            max_retries=args.max_retries,
        )

    print(
        "[%s] [OK] 开始翻译: %d 行字幕, 分 %d 块, 并发 %d"
        % (timestamp(), len(text_lines), total_blocks, args.concurrency),
        file=sys.stderr,
    )

    try:
        translated = translate_all(
            text_lines, args.block_size, args.concurrency, translate_fn, running
        )
    except AuthError as exc:
        print(
            "[%s] [ERR] %s" % (timestamp(), exc),
            file=sys.stderr,
        )
        sys.exit(1)

    fallen_back = 0
    for idx, block in enumerate(blocks):
        start = idx * args.block_size
        fell_back = True
        for j, original_line in enumerate(block):
            if translated.get(start + j) != [original_line]:
                fell_back = False
                break
        if fell_back:
            fallen_back += 1
            print(
                "[%s] [WARN] 翻译块 %d/%d 失败, 保留原文"
                % (timestamp(), idx + 1, total_blocks),
                file=sys.stderr,
            )

    output_text = assemble_srt(records, translated)
    with open(output_path, "w", encoding="utf-8", newline="") as f:
        f.write(output_text)

    print(
        "[%s] [DONE] 翻译完成: %d/%d 块成功, %d 块保留原文, 输出 %s"
        % (timestamp(), total_blocks - fallen_back, total_blocks, fallen_back, output_path),
        file=sys.stderr,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Fetch TVer live m3u8 playlist URL using Playwright headless browser.
Handles the birth-year + prefecture age confirmation popup automatically.
Resolves the master manifest to find the best video variant.
Outputs the best variant m3u8 URL to stdout on success.
"""

import argparse
import asyncio
import re
import sys
import json
from datetime import datetime
from urllib.parse import urljoin

import requests
import m3u8
from playwright.async_api import async_playwright, TimeoutError as PlaywrightTimeout

LEVEL_RE = re.compile(r"/(\d+)\.m3u8")
METRICS_HOST = "tver-metrics.streaks.jp"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}


def timestamp():
    return datetime.now().strftime("%H:%M:%S")


async def dismiss_age_popup(page) -> bool:
    await page.wait_for_timeout(2000)

    try:
        selects = page.locator("select")
        count = await selects.count()
        if count >= 2:
            print(f"[{timestamp()}] 检测到年龄确认弹窗 (下拉框数={count})",
                  file=sys.stderr)

            year_select = None
            region_select = None
            year_kw = ["年", "生", "year"]
            region_kw = ["都", "道", "府", "県", "地域", "area", "region"]

            for i in range(count):
                try:
                    label_lower = await selects.nth(i).evaluate(
                        "el => (el.labels?.[0]?.textContent || el.getAttribute('aria-label') || '').toLowerCase()"
                    )
                except Exception:
                    label_lower = ""
                if any(kw in label_lower for kw in year_kw):
                    year_select = selects.nth(i)
                if any(kw in label_lower for kw in region_kw):
                    region_select = selects.nth(i)

            if year_select is None:
                year_select = selects.first
            if region_select is None:
                region_select = selects.nth(1)

            try:
                options = await year_select.locator("option").all()
                if len(options) > 1:
                    opt = options[len(options) // 2]
                    val = await opt.get_attribute("value")
                    if val:
                        await year_select.select_option(value=val)
                        print(f"[{timestamp()}] 选择出生年: {val}", file=sys.stderr)
            except Exception as e:
                print(f"[{timestamp()}] 出生年选择失败: {e}", file=sys.stderr)

            try:
                options = await region_select.locator("option").all()
                found = False
                for opt in options:
                    text = await opt.text_content()
                    if text and "東京" in text:
                        val = await opt.get_attribute("value")
                        if val and val.strip():
                            await region_select.select_option(value=val)
                            print(f"[{timestamp()}] 选择地区: 東京", file=sys.stderr)
                            found = True
                            break
                if not found and len(options) > 1:
                    await region_select.select_option(index=1)
                    print(f"[{timestamp()}] 选择地区 (候补)", file=sys.stderr)
            except Exception as e:
                print(f"[{timestamp()}] 地区选择失败: {e}", file=sys.stderr)

            buttons = page.locator("button")
            btn_count = await buttons.count()
            for i in range(btn_count):
                btn = buttons.nth(i)
                try:
                    text = (await btn.text_content()).strip()
                    btn_kw = ["確認", "OK", "決定", "同意", "送信", "次へ"]
                    if any(kw in text for kw in btn_kw):
                        await btn.click()
                        print(f"[{timestamp()}] 点击按钮: {text}", file=sys.stderr)
                        break
                except Exception:
                    continue

            await page.wait_for_timeout(3000)
            return True
    except Exception as e:
        print(f"[{timestamp()}] 弹窗处理出错: {e}", file=sys.stderr)

    return False


async def dismiss_cookie_banner(page) -> bool:
    try:
        buttons = page.locator("button")
        btn_count = await buttons.count()
        for i in range(btn_count):
            btn = buttons.nth(i)
            try:
                text = (await btn.text_content()).strip()
                cookie_kw = ["同意", "Accept", "OK", "許可", "すべて"]
                if any(kw in text for kw in cookie_kw):
                    await btn.click()
                    print(f"[{timestamp()}] Cookie弹窗: {text}", file=sys.stderr)
                    await page.wait_for_timeout(1500)
                    return True
            except Exception:
                continue
    except Exception:
        pass
    return False


def probe_resolution(variant_url):
    import subprocess, tempfile, os
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import unpad

    try:
        resp = requests.get(variant_url, headers=HEADERS, timeout=15)
        resp.raise_for_status()
        playlist = m3u8.loads(resp.text, uri=variant_url)
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
    except Exception as e:
        print(f"  [PROBE] {variant_url[:80]}... 失败: {e}", file=sys.stderr)
        return None


def resolve_manifest(manifest_url: str) -> dict:
    """Download master manifest, find video + subtitle variants."""
    print(f"[{timestamp()}] 下载 manifest: {manifest_url[:100]}...", file=sys.stderr)
    try:
        resp = requests.get(manifest_url, headers=HEADERS, timeout=15)
        resp.raise_for_status()
    except Exception as e:
        print(f"[{timestamp()}] manifest 下载失败: {e}", file=sys.stderr)
        return {}

    content = resp.text
    playlist = m3u8.loads(content, uri=manifest_url)

    video_variants = []
    for pl in playlist.playlists:
        uri = urljoin(manifest_url, pl.uri)
        bw = pl.stream_info.bandwidth if pl.stream_info else 0
        res = pl.stream_info.resolution if pl.stream_info else None
        codecs = pl.stream_info.codecs if pl.stream_info else ""
        w, h = res if res else (0, 0)
        video_variants.append({
            "url": uri,
            "bandwidth": bw,
            "width": w,
            "height": h,
            "codecs": codecs,
        })

    subtitle_variants = []
    for media in playlist.media:
        if media.type == "SUBTITLES" or media.uri and ".vtt" in media.uri.lower():
            sub_uri = urljoin(manifest_url, media.uri) if media.uri else None
            subtitle_variants.append({
                "url": sub_uri,
                "language": media.language,
                "name": media.name,
                "group_id": media.group_id,
            })

    print(f"[{timestamp()}] manifest 解析: {len(video_variants)} 个视频变体, "
          f"{len(subtitle_variants)} 个字幕", file=sys.stderr)

    if video_variants:
        for v in video_variants:
            print(f"  video: {v['width']}x{v['height']} @ {v['bandwidth']}bps "
                  f"codecs={v['codecs'][:30]}", file=sys.stderr)

    # Probe resolutions for any variant missing resolution info
    unresolved = [v for v in video_variants if v["width"] == 0]
    if unresolved:
        print(f"[{timestamp()}] 探测 {len(unresolved)} 个无分辨率信息的变体...", file=sys.stderr)
        for v in unresolved:
            result = probe_resolution(v["url"])
            if result:
                pixels, w, h = result
                v["width"] = w
                v["height"] = h
                print(f"  {w}x{h}", file=sys.stderr)

    # Select best video variant (highest resolution)
    video_variants.sort(key=lambda v: (v["height"], v["bandwidth"]), reverse=True)
    best_video = video_variants[0] if video_variants else None
    best_sub = subtitle_variants[0] if subtitle_variants else None

    result = {}
    if best_video:
        result["video_url"] = best_video["url"]
        result["video_res"] = f"{best_video['width']}x{best_video['height']}"
        print(f"[{timestamp()}] 最佳视频: {best_video['width']}x{best_video['height']}",
              file=sys.stderr)
    if best_sub:
        result["subtitle_url"] = best_sub["url"]
        print(f"[{timestamp()}] 字幕: {best_sub['url'][:100]}", file=sys.stderr)

    return result


async def capture_manifest(tver_url: str, timeout: int = 45) -> str | None:
    """Use Playwright to open TVer page and capture the master m3u8 URL."""
    captured = []

    async def on_request(request):
        url = request.url
        if ".m3u8" in url and METRICS_HOST not in url:
            captured.append(url)

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-setuid-sandbox"],
        )
        context = await browser.new_context(
            user_agent=HEADERS["User-Agent"],
            locale="ja-JP",
            timezone_id="Asia/Tokyo",
        )
        page = await context.new_page()
        page.on("request", on_request)

        try:
            print(f"[{timestamp()}] 打开页面: {tver_url}", file=sys.stderr)
            await page.goto(tver_url, wait_until="domcontentloaded",
                            timeout=timeout * 1000)

            await dismiss_cookie_banner(page)
            await dismiss_age_popup(page)

            waited = 0
            while waited < timeout and not captured:
                try:
                    pages = context.pages
                    for pg in pages:
                        if pg != page and ".m3u8" in (pg.url or ""):
                            page = pg
                            page.on("request", on_request)
                            break
                except Exception:
                    pass
                await page.wait_for_timeout(2000)
                waited += 2

            if not captured:
                print(f"[{timestamp()}] 再等待 10 秒...", file=sys.stderr)
                await page.wait_for_timeout(10000)

        except PlaywrightTimeout:
            print(f"[{timestamp()}] 页面加载超时", file=sys.stderr)
        except Exception as e:
            print(f"[{timestamp()}] 异常: {e}", file=sys.stderr)
        finally:
            await browser.close()

    deduped = list(dict.fromkeys(captured))
    # Prefer URLs that contain "manifest" or are on the ssai host
    real_manifests = [u for u in deduped
                      if "manifest" in u.lower()
                      and "tver-metrics" not in u]
    if real_manifests:
        print(f"[{timestamp()}] 捕获到 manifest: {real_manifests[0][:120]}...", file=sys.stderr)
        return real_manifests[0]

    non_metrics = [u for u in deduped if METRICS_HOST not in u]
    if non_metrics:
        print(f"[{timestamp()}] 候选 m3u8: {non_metrics[0][:120]}...", file=sys.stderr)
        return non_metrics[0]

    return None


def main():
    parser = argparse.ArgumentParser(
        description="从 TVer 直播页面获取 m3u8 播放列表地址")
    parser.add_argument("tver_url", help="TVer 直播页面 URL")
    parser.add_argument("--timeout", type=int, default=60,
                        help="最大等待秒数 (默认: 60)")
    parser.add_argument("--json", action="store_true",
                        help="输出 JSON (含 video_url 和 subtitle_url)")
    args = parser.parse_args()

    manifest_url = asyncio.run(capture_manifest(args.tver_url, args.timeout))
    if not manifest_url:
        print("错误: 未捕获到 m3u8 链接", file=sys.stderr)
        sys.exit(1)

    resolved = resolve_manifest(manifest_url)

    if args.json and resolved:
        print(json.dumps(resolved, ensure_ascii=False))
    elif resolved.get("video_url"):
        print(resolved["video_url"])
    else:
        print(manifest_url)

    sys.exit(0 if resolved else 1)


if __name__ == "__main__":
    main()

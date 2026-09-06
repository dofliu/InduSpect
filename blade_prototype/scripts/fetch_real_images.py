#!/usr/bin/env python3
"""從 Openverse 抓取 CC 授權的真實風機照片，建立驗證語料庫。

用途：合成夾具（`blade_proto/synth.py`）與被測程式出自同一組假設，屬於循環驗
證。這支腳本抓真實照片，讓分割與結構定位面對合成天空掩蓋掉的失敗模式——雲、
樹林、電線、多台同框、背光、逆光剪影。

授權與禮節：
- 只抓 CC0 / CC BY / CC BY-SA（可自由重製與研究使用）。
- 影像**不進版控**（`blade_prototype/real_images/` 已在 .gitignore），只保留
  `manifest.json` 的出處與授權資訊，供結果可追溯與重現。
- 逐張間隔請求，帶可辨識的 User-Agent。
- upload.wikimedia.org 從本 proxy 出口會被限流（HTTP 429），因此預設排除
  wikimedia 來源；Flickr / StockSnap 等來源可直接下載。

用法：
    python scripts/fetch_real_images.py --out real_images --limit 40
"""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

API = "https://api.openverse.org/v1/images/"
UA = "InduSpect-blade-prototype/0.1 (algorithm validation; github.com/dofliu/induspect)"

# 只收可自由重製的授權；NC/ND 排除，避免後續衍生使用受限
LICENSES = ("cc0", "by", "by-sa")

# 從本環境實測可直接下載的來源；wikimedia 會 429，預設不取
SOURCES = ("flickr", "stocksnap", "rawpixel", "wordpress", "justtakeitfree", "nappy")

QUERIES = (
    "wind turbine",
    "wind turbines",
    "wind farm",
    "wind turbine blades",
    "windmill turbine sky",
    "offshore wind turbine",
    "wind turbine landscape",
    "wind power plant",
)

# 標題出現這些字幾乎都不是「立在場上的三葉風機」——運輸、工廠、零件特寫、
# 垂直軸機型、拆除殘骸。先用標題粗篩，剩下的仍需人工看圖確認。
NEGATIVE = (
    "transport", "delivery", "unload", "storage", "factory", "manufactur",
    "truck", "lorry", "trailer", "boat", "ship", "vessel", "rail", "crane",
    "savonius", "darrieus", "vertical axis", "remains", "demolition",
    "museum", "model", "toy", "diagram", "map", "logo", "icon", "sign",
    "interior", "nacelle interior", "construction site", "foundation",
)


@dataclass
class Item:
    """一筆候選影像的出處資訊（存進 manifest，供結果可追溯）。"""

    id: str
    title: str
    creator: str
    license: str
    license_version: str
    license_url: str
    source: str
    landing: str
    url: str
    width: int
    height: int
    query: str
    file: str = ""
    tags: list = field(default_factory=list)


def _get_json(url: str, timeout: float = 60.0) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def search(query: str, page_size: int = 20, page: int = 1) -> list[Item]:
    params = {
        "q": query,
        "license": ",".join(LICENSES),
        "source": ",".join(SOURCES),
        "page_size": page_size,
        "page": page,
        "mature": "false",
    }
    data = _get_json(API + "?" + urllib.parse.urlencode(params))
    out = []
    for r in data.get("results", []):
        out.append(Item(
            id=r.get("id", ""),
            title=(r.get("title") or "").strip(),
            creator=(r.get("creator") or "").strip(),
            license=r.get("license", ""),
            license_version=r.get("license_version", ""),
            license_url=r.get("license_url", ""),
            source=r.get("source", ""),
            landing=r.get("foreign_landing_url", ""),
            url=r.get("url", ""),
            width=int(r.get("width") or 0),
            height=int(r.get("height") or 0),
            query=query,
            tags=[t.get("name", "") for t in (r.get("tags") or [])][:12],
        ))
    return out


def looks_relevant(it: Item, min_side: int) -> bool:
    """粗篩：標題負面字排除、尺寸下限、排除極端長寬比（多半是全景或直幅特寫）。"""
    low = (it.title + " " + " ".join(it.tags)).lower()
    if any(k in low for k in NEGATIVE):
        return False
    if not it.url.lower().split("?")[0].endswith((".jpg", ".jpeg", ".png")):
        return False
    if min(it.width, it.height) < min_side:
        return False
    ar = it.width / max(it.height, 1)
    return 0.5 <= ar <= 2.4


def download(it: Item, out_dir: str, timeout: float = 90.0) -> bool:
    ext = os.path.splitext(it.url.split("?")[0])[1].lower() or ".jpg"
    path = os.path.join(out_dir, f"{it.id[:8]}{ext}")
    if os.path.exists(path) and os.path.getsize(path) > 10_000:
        it.file = os.path.basename(path)
        return True
    req = urllib.request.Request(it.url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            blob = r.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"  ! 下載失敗 {it.id[:8]}: {exc}")
        return False
    if len(blob) < 10_000:
        print(f"  ! 檔案過小 {it.id[:8]}: {len(blob)} bytes")
        return False
    with open(path, "wb") as f:
        f.write(blob)
    it.file = os.path.basename(path)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="real_images", help="輸出目錄（不進版控）")
    ap.add_argument("--limit", type=int, default=40, help="最多下載幾張")
    ap.add_argument("--min-side", type=int, default=640, help="短邊最小像素")
    ap.add_argument("--page-size", type=int, default=20)
    ap.add_argument("--pages", type=int, default=2, help="每個查詢抓幾頁")
    ap.add_argument("--sleep", type=float, default=0.6, help="請求間隔秒數")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    seen: set[str] = set()
    kept: list[Item] = []

    for q in QUERIES:
        for page in range(1, args.pages + 1):
            if len(kept) >= args.limit:
                break
            try:
                results = search(q, args.page_size, page)
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                print(f"! 查詢失敗 {q!r} p{page}: {exc}")
                break
            time.sleep(args.sleep)
            for it in results:
                if len(kept) >= args.limit:
                    break
                if it.id in seen:
                    continue
                seen.add(it.id)
                if not looks_relevant(it, args.min_side):
                    continue
                if download(it, args.out):
                    kept.append(it)
                    print(f"  + {it.file}  {it.width}x{it.height}  {it.license}  {it.title[:52]}")
                    time.sleep(args.sleep)

    manifest = os.path.join(args.out, "manifest.json")
    with open(manifest, "w", encoding="utf-8") as f:
        json.dump([vars(i) for i in kept], f, ensure_ascii=False, indent=1)
    print(f"\n共 {len(kept)} 張 → {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

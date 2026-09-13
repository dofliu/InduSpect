#!/usr/bin/env python3
"""抓 CC 授權的**葉片近身照**候選，供 Mode B（`BLADE_CLOSEUP_SPEC.md`）B0 階段使用。

與 `fetch_real_images.py` 的差別是**要的東西剛好相反**：那支要「整台風機立在場上」，
負面字表把運輸、工廠、零件特寫全部排掉；Mode B 要的正是那些——葉片填滿畫面的照片。

授權與禮節沿用同一套：
- 只收 CC0 / CC BY / CC BY-SA。NC 一律排除（理由見 `CLOSEUP_BASELINE_REPORT.md` §2：
  主力語料 DTU v2 就是 NC，混進訓練資料會讓整個模型不能出貨）。
- 影像**不進版控**（`blade_prototype/closeup_images/` 在 .gitignore），只留 manifest。
- upload.wikimedia.org 從本 proxy 出口會被限流，因此走 Openverse。

EXIF 用內建的極簡解析器讀，**不加相依**：只要 §2 用得到的那幾個標籤
（焦距、35mm 等效焦距、被攝距離、機型），其餘一律不碰。沒有 EXIF 是常態不是例外，
那本身就是 B0 要量的數字之一。

用法：
    python scripts/fetch_closeup_corpus.py --out closeup_images --limit 120
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

API = "https://api.openverse.org/v1/images/"
UA = "InduSpect-blade-prototype/0.1 (Mode B corpus; github.com/dofliu/induspect)"

LICENSES = ("cc0", "by", "by-sa")

# Openverse 對查詢字做 AND 比對，字一多結果就歸零（實測 "wind turbine blade repair"
# 只有 7 筆，"wind turbine blade" 有 240 筆）。所以查詢一律短，相關性靠事後看圖。
QUERIES = (
    "wind turbine blade",
    "turbine blade",
    "rotor blade",
    "windmill blade",
    "blade damage",
    "blade repair",
    "blade transport",
    "blade factory",
    "wind turbine damage",
    "wind turbine maintenance",
    "wind turbine repair",
    "broken turbine",
    "Rotorblatt",
    "pale eolienne",
)

# 這些字幾乎保證是遠景風場照，不是近身照。與 fetch_real_images.py 的負面字表互補。
NEGATIVE = (
    "wind farm", "windfarm", "landscape", "sunset", "sunrise", "panorama",
    "aerial view", "skyline", "field of", "hillside", "meadow", "silhouette",
    "logo", "icon", "diagram", "map", "chart", "clip art", "clipart",
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
    thumbnail: str
    width: int
    height: int
    query: str
    file: str = ""
    tags: list = field(default_factory=list)
    exif: dict = field(default_factory=dict)


# --- 極簡 EXIF 解析（只取 §2 需要的標籤，不加相依） ---------------------------

# tag id → 名稱。只列 Mode B §2 的尺度推算用得到的，其餘略過。
_TAGS = {
    0x010F: "Make", 0x0110: "Model", 0x9003: "DateTimeOriginal",
    0x920A: "FocalLength", 0xA405: "FocalLengthIn35mmFilm", 0x9206: "SubjectDistance",
    0xA002: "ExifImageWidth", 0xA003: "ExifImageHeight", 0xA20E: "FocalPlaneXResolution",
    0xA210: "FocalPlaneResolutionUnit", 0xA404: "DigitalZoomRatio", 0xA434: "LensModel",
    0x8769: "_ExifIFD",
}
_FMT_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}


def _read_ifd(buf: bytes, off: int, endian: str, out: dict, depth: int = 0) -> None:
    """讀一個 IFD；遇到 ExifIFD 指標就遞迴進去（深度上限 2，避免惡意檔案繞圈）。"""
    if depth > 2 or off + 2 > len(buf):
        return
    (count,) = struct.unpack_from(endian + "H", buf, off)
    for i in range(count):
        e = off + 2 + i * 12
        if e + 12 > len(buf):
            return
        tag, fmt, n = struct.unpack_from(endian + "HHI", buf, e)
        if fmt not in _FMT_SIZE:
            continue
        size = _FMT_SIZE[fmt] * n
        val_off = e + 8
        if size > 4:
            (val_off,) = struct.unpack_from(endian + "I", buf, e + 8)
            if val_off + size > len(buf):
                continue
        name = _TAGS.get(tag)
        if name == "_ExifIFD":
            (sub,) = struct.unpack_from(endian + "I", buf, val_off)
            _read_ifd(buf, sub, endian, out, depth + 1)
            continue
        if name is None:
            continue
        if fmt == 2:  # ASCII
            out[name] = buf[val_off:val_off + size].split(b"\x00")[0].decode("ascii", "replace")
        elif fmt in (3, 4):  # short / long
            code = "H" if fmt == 3 else "I"
            out[name] = struct.unpack_from(endian + code, buf, val_off)[0]
        elif fmt in (5, 10):  # rational / srational
            code = "II" if fmt == 5 else "ii"
            num, den = struct.unpack_from(endian + code, buf, val_off)
            out[name] = round(num / den, 4) if den else None


def read_exif(path: str) -> dict:
    """從 JPEG 的 APP1 段取 EXIF。讀不到就回空 dict——沒有 EXIF 是常態。"""
    try:
        with open(path, "rb") as f:
            blob = f.read(256 * 1024)
    except OSError:
        return {}
    if not blob.startswith(b"\xff\xd8"):
        return {}
    i = 2
    while i + 4 <= len(blob):
        if blob[i] != 0xFF:
            return {}
        marker = blob[i + 1]
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        (seg_len,) = struct.unpack_from(">H", blob, i + 2)
        if marker == 0xE1 and blob[i + 4:i + 10] == b"Exif\x00\x00":
            tiff = blob[i + 10:i + 2 + seg_len]
            if len(tiff) < 8:
                return {}
            endian = "<" if tiff[:2] == b"II" else ">" if tiff[:2] == b"MM" else None
            if endian is None:
                return {}
            (ifd0,) = struct.unpack_from(endian + "I", tiff, 4)
            out: dict = {}
            _read_ifd(tiff, ifd0, endian, out)
            return out
        if marker == 0xDA:  # 進入影像資料，之後沒有 metadata
            return {}
        i += 2 + seg_len
    return {}


# --- 抓取 -------------------------------------------------------------------

def _get_json(url: str, timeout: float = 60.0) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def search(query: str, page_size: int = 20, page: int = 1) -> list[Item]:
    params = {
        "q": query,
        "license": ",".join(LICENSES),
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
            thumbnail=r.get("thumbnail", ""),
            width=int(r.get("width") or 0),
            height=int(r.get("height") or 0),
            query=query,
            tags=[t.get("name", "") for t in (r.get("tags") or [])][:12],
        ))
    return out


def looks_relevant(it: Item, min_side: int) -> bool:
    """粗篩。近身與否**標題判不出來**，最後一定要看圖——這裡只擋掉保證不是的。"""
    low = (it.title + " " + " ".join(it.tags)).lower()
    if any(k in low for k in NEGATIVE):
        return False
    if not it.url.lower().split("?")[0].endswith((".jpg", ".jpeg", ".png")):
        return False
    return min(it.width, it.height) >= min_side


def download(it: Item, out_dir: str, timeout: float = 90.0) -> bool:
    ext = os.path.splitext(it.url.split("?")[0])[1].lower() or ".jpg"
    path = os.path.join(out_dir, f"{it.id[:8]}{ext}")
    if os.path.exists(path) and os.path.getsize(path) > 10_000:
        it.file = os.path.basename(path)
        it.exif = read_exif(path)
        return True
    blob = b""
    # 原始 URL 優先；upload.wikimedia.org 從本 proxy 出口會被擋，改走 Openverse 的縮圖代理
    for src in (it.url, it.thumbnail):
        if not src:
            continue
        req = urllib.request.Request(src, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                blob = r.read()
            break
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            print(f"  ! 下載失敗 {it.id[:8]} ({src[:40]}): {exc}")
    if not blob:
        return False
    if len(blob) < 10_000:
        print(f"  ! 檔案過小 {it.id[:8]}: {len(blob)} bytes")
        return False
    with open(path, "wb") as f:
        f.write(blob)
    it.file = os.path.basename(path)
    it.exif = read_exif(path)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="closeup_images", help="輸出目錄（不進版控）")
    ap.add_argument("--limit", type=int, default=120, help="最多下載幾張")
    ap.add_argument("--min-side", type=int, default=500, help="短邊最小像素")
    ap.add_argument("--page-size", type=int, default=20)
    ap.add_argument("--pages", type=int, default=6, help="每個查詢抓幾頁")
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
                    n_exif = len(it.exif)
                    print(f"  + {it.file}  {it.width}x{it.height}  {it.license}  "
                          f"exif={n_exif}  {it.title[:46]}", flush=True)
                    time.sleep(args.sleep)

    manifest = os.path.join(args.out, "manifest.json")
    with open(manifest, "w", encoding="utf-8") as f:
        json.dump([vars(i) for i in kept], f, ensure_ascii=False, indent=1)
    with_focal = sum(1 for i in kept if i.exif.get("FocalLengthIn35mmFilm") or i.exif.get("FocalLength"))
    print(f"\n共 {len(kept)} 張 → {manifest}")
    print(f"有焦距 EXIF：{with_focal}/{len(kept)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

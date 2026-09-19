#!/usr/bin/env python3
"""從 Wikimedia Commons 抓「機型已知、EXIF 焦距還在」的整機照，給姿態估計做真實驗證。

為什麼是 Commons：既有 75 張真實照片全部是 Flickr 的 1024 px 縮版，EXIF 被剝掉，姿態估計
（仰角 = 輪轂高 ÷ 由焦距反推的距離）在它們上面驗不了。Commons 保留原檔 EXIF，而且 Commons 在
**上傳時就把 EXIF 抽進 API 的 `metadata`**——可以先用 API 過濾（有 35 mm 等效焦距、夠大、CC 授權、
機型類別已知），再下載真的要用的那幾十張。機型來自類別（`Category:Enercon E-126` 等），轉子直徑
是型錄值；輪轂高度每座風場不同，描述有寫就用描述的，沒寫用該機型的典型值並標記來源。

**Commons 對這個環境限速很嚴**（連兩次就 429），所以每個請求之間固定間隔（預設 12 s），429 就等一分鐘再試。
帶可辨識的 User-Agent。影像放 scratchpad 不進版控；manifest（出處、授權、EXIF、機型、型錄值）進版控。

用法：
    python scripts/fetch_commons_turbines.py search   --out data/commons_turbines_manifest.json
    python scripts/fetch_commons_turbines.py download --manifest data/commons_turbines_manifest.json --dir <scratch>/commons_turbines --max 60
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://commons.wikimedia.org/w/api.php"
UA = "InduSpectBladeResearch/0.1 (https://github.com/dofliu/InduSpect; moredof@gmail.com) python-urllib"
DEFAULT_PACE_S = 12.0

# 機型 → (轉子直徑 m, 典型輪轂高 m, 出處)。輪轂高**每座風場不同**，這裡的是型錄常見值；描述有寫就以描述為準。
MODEL_SPECS: dict[str, tuple[float, float, str]] = {
    "Enercon E-126": (127.0, 135.0, "Enercon 型錄；E-126 常見 135 m（也有 131／198 m）"),
    "Enercon E-115": (115.7, 122.0, "Enercon 型錄；92／122／135／149 m"),
    "Enercon E-101": (101.0, 124.0, "Enercon 型錄；99／124／135／149 m"),
    "Enercon E-82": (82.0, 98.0, "Enercon 型錄；78／85／98／108／138 m"),
    "Enercon E-70": (71.0, 85.0, "Enercon 型錄；57–113 m，常見 64／85／98"),
    "Enercon E-66": (70.0, 98.0, "Enercon 型錄；67–98 m"),
    "Enercon E-40": (44.0, 65.0, "Enercon 型錄；46–78 m"),
    "Vestas V90": (90.0, 105.0, "Vestas 型錄；80／95／105／125 m"),
    "Vestas V80": (80.0, 78.0, "Vestas 型錄；60／67／78／100 m"),
    "Vestas V112": (112.0, 94.0, "Vestas 型錄；84／94／119 m"),
    "Vestas V52": (52.0, 60.0, "Vestas 型錄；44–74 m"),
    "Vestas V47": (47.0, 50.0, "Vestas 型錄；40–55 m"),
    "Vestas V66": (66.0, 67.0, "Vestas 型錄；60–78 m"),
    "Vestas V100": (100.0, 95.0, "Vestas 型錄；80／95 m"),
    "Vestas V117": (117.0, 91.5, "Vestas 型錄；80／91.5／116.5 m"),
    "Vestas V126": (126.0, 117.0, "Vestas 型錄；87／117／137 m"),
    "Siemens SWT-2.3-93": (93.0, 80.0, "Siemens 型錄；80／101 m"),
    "Siemens SWT-3.6-107": (107.0, 90.0, "Siemens 型錄（離岸）；約 80–90 m"),
    "Siemens SWT-3.6-120": (120.0, 90.0, "Siemens 型錄（離岸）；約 90 m"),
    "Nordex N117": (116.8, 120.0, "Nordex 型錄；91／120／141 m"),
    "Nordex N100": (99.8, 100.0, "Nordex 型錄；75／100 m"),
    "Nordex N90": (90.0, 100.0, "Nordex 型錄；80／100 m"),
    "Nordex N80": (80.0, 80.0, "Nordex 型錄；60／80 m"),
    "GE 1.5": (77.0, 80.0, "GE 1.5sle 型錄；65／80 m"),
    "GE 2.5": (100.0, 85.0, "GE 2.5xl 型錄；75／85／100 m"),
    "Gamesa G87": (87.0, 78.0, "Gamesa 型錄；67／78／90／100 m"),
    "Gamesa G90": (90.0, 78.0, "Gamesa 型錄；67–100 m"),
    "Gamesa G114": (114.0, 93.0, "Gamesa 型錄；80／93／125 m"),
    "Senvion MM92": (92.5, 100.0, "REpower/Senvion 型錄；68–100 m"),
    "Senvion MM82": (82.0, 80.0, "REpower/Senvion 型錄；59–100 m"),
    "REpower 5M": (126.0, 117.0, "REpower 型錄；100／117 m"),
}
# Commons 類別名 → 機型鍵。類別不存在時 API 回空，無妨。
CATEGORIES: dict[str, str] = {
    "Category:Enercon E-126": "Enercon E-126",
    "Category:Enercon E-115": "Enercon E-115",
    "Category:Enercon E-101": "Enercon E-101",
    "Category:Enercon E-82": "Enercon E-82",
    "Category:Enercon E-70": "Enercon E-70",
    "Category:Enercon E-66": "Enercon E-66",
    "Category:Enercon E-40": "Enercon E-40",
    "Category:Vestas V90": "Vestas V90",
    "Category:Vestas V80": "Vestas V80",
    "Category:Vestas V112": "Vestas V112",
    "Category:Vestas V52": "Vestas V52",
    "Category:Vestas V47": "Vestas V47",
    "Category:Vestas V66": "Vestas V66",
    "Category:Vestas V100": "Vestas V100",
    "Category:Vestas V117": "Vestas V117",
    "Category:Vestas V126": "Vestas V126",
    "Category:Siemens SWT-2.3-93": "Siemens SWT-2.3-93",
    "Category:Siemens SWT-3.6-107": "Siemens SWT-3.6-107",
    "Category:Siemens SWT-3.6-120": "Siemens SWT-3.6-120",
    "Category:Nordex N117": "Nordex N117",
    "Category:Nordex N100": "Nordex N100",
    "Category:Nordex N90": "Nordex N90",
    "Category:Nordex N80": "Nordex N80",
    "Category:GE 1.5": "GE 1.5",
    "Category:GE 2.5": "GE 2.5",
    "Category:Gamesa G87": "Gamesa G87",
    "Category:Gamesa G90": "Gamesa G90",
    "Category:Gamesa G114": "Gamesa G114",
    "Category:Senvion MM92": "Senvion MM92",
    "Category:REpower MM92": "Senvion MM92",
    "Category:REpower MM82": "Senvion MM82",
    "Category:REpower 5M": "REpower 5M",
}
HUB_RE = re.compile(r"(\d{2,3}(?:[.,]\d)?)\s*(?:m|meter|metre|Meter)\b[^.]{0,40}?(?:hub|Nabenh|nacelle|hub height)|"
                    r"(?:hub height|Nabenh(?:ö|oe|o)he|hub)[^0-9]{0,25}(\d{2,3}(?:[.,]\d)?)\s*(?:m|meter|metre)\b", re.I)

_last_request = 0.0


def _paced_get(url: str, pace_s: float, retries: int = 3) -> dict:
    """固定間隔的 GET；429 就等 60 s 再試。"""
    global _last_request
    for attempt in range(retries + 1):
        wait = pace_s - (time.time() - _last_request)
        if wait > 0:
            time.sleep(wait)
        _last_request = time.time()
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries:
                print(f"  429，等 60 s（第 {attempt + 1} 次）", file=sys.stderr)
                time.sleep(60)
                continue
            raise


def _strip_html(s: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", " ", s or "")).replace("\n", " ").strip()


def _meta(ii: dict) -> dict:
    out = {}
    for m in ii.get("metadata") or []:
        if not isinstance(m.get("value"), (list, dict)):
            out[m["name"]] = m["value"]
    return out


def _num(v) -> float | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip()
    m = re.match(r"^(\d+(?:\.\d+)?)(?:/(\d+))?", s)
    if not m:
        return None
    a = float(m.group(1))
    b = float(m.group(2)) if m.group(2) else 1.0
    return a / b if b else None


def _hub_from_description(desc: str) -> float | None:
    for m in HUB_RE.finditer(desc):
        g = m.group(1) or m.group(2)
        if g:
            v = float(g.replace(",", "."))
            if 30 <= v <= 200:
                return v
    return None


def _candidate(page: dict, model_key: str, origin: str) -> dict | None:
    ii = (page.get("imageinfo") or [{}])[0]
    if not ii or ii.get("mime") not in ("image/jpeg", "image/png"):
        return None
    md = _meta(ii)
    ext = ii.get("extmetadata") or {}
    lic = _strip_html(ext.get("LicenseShortName", {}).get("value", ""))
    desc = _strip_html(ext.get("ImageDescription", {}).get("value", ""))
    f35 = _num(md.get("FocalLengthIn35mmFilm"))
    fl = _num(md.get("FocalLength"))
    spec = MODEL_SPECS.get(model_key)
    hub_desc = _hub_from_description(desc)
    return {
        "title": page.get("title"),
        "pageid": page.get("pageid"),
        "page_url": f"https://commons.wikimedia.org/?curid={page.get('pageid')}",
        "origin": origin,
        "model": model_key,
        "rotor_diameter_m": spec[0] if spec else None,
        "hub_height_typical_m": spec[1] if spec else None,
        "hub_height_desc_m": hub_desc,
        "hub_height_m": hub_desc if hub_desc else (spec[1] if spec else None),
        "hub_height_source": "description" if hub_desc else ("typical" if spec else None),
        "spec_note": spec[2] if spec else None,
        "license": lic,
        "artist": _strip_html(ext.get("Artist", {}).get("value", ""))[:80],
        "width": ii.get("width"),
        "height": ii.get("height"),
        "url": ii.get("url"),
        "thumb_url": ii.get("thumburl"),
        "camera_model": md.get("Model"),
        "focal_length_mm": fl,
        "focal_35mm": f35,
        "date": md.get("DateTimeOriginal"),
        "description": desc[:400],
    }


def _accept(c: dict, min_side: int) -> tuple[bool, str]:
    if not c.get("license") or not (c["license"].startswith("CC") or "Public domain" in c["license"] or c["license"] == "CC0"):
        return False, "license"
    if not c.get("focal_35mm") or c["focal_35mm"] <= 0:
        return False, "no_f35"
    if (c.get("width") or 0) < min_side or (c.get("height") or 0) < min_side * 0.6:
        return False, "small"
    if c.get("rotor_diameter_m") is None:
        return False, "no_spec"
    return True, "ok"


def cmd_search(a: argparse.Namespace) -> int:
    cands: dict[int, dict] = {}
    stats = {"pages": 0, "license": 0, "no_f35": 0, "small": 0, "no_spec": 0, "ok": 0}
    for cat, model in CATEGORIES.items():
        params = {"action": "query", "generator": "categorymembers", "gcmtitle": cat, "gcmtype": "file",
                  "gcmlimit": str(a.per_category), "prop": "imageinfo",
                  "iiprop": "url|size|mime|metadata|extmetadata", "iiurlwidth": str(a.thumb_width), "format": "json"}
        try:
            d = _paced_get(API + "?" + urllib.parse.urlencode(params), a.pace)
        except Exception as e:  # noqa: BLE001
            print(f"{cat}: 失敗 {e}", file=sys.stderr)
            continue
        pages = (d.get("query") or {}).get("pages") or {}
        n_ok = 0
        for pid, page in pages.items():
            c = _candidate(page, model, cat)
            if c is None:
                continue
            stats["pages"] += 1
            ok, why = _accept(c, a.min_side)
            stats[why] += 1
            c["selected"] = ok
            c["reject_reason"] = None if ok else why
            n_ok += ok
            cands[int(pid)] = c
        print(f"{cat}: {len(pages)} 檔，可用 {n_ok}", file=sys.stderr)
    out = {
        "_readme": "Wikimedia Commons 整機照候選（機型類別已知）。由 scripts/fetch_commons_turbines.py search 產生；"
                   "selected = CC 授權 + EXIF 有 35 mm 等效焦距 + 尺寸夠 + 機型型錄值存在。影像不進版控。",
        "generated": time.strftime("%Y-%m-%d"),
        "pace_s": a.pace,
        "stats": stats,
        "specs": {k: {"rotor_diameter_m": v[0], "hub_height_typical_m": v[1], "note": v[2]} for k, v in MODEL_SPECS.items()},
        "candidates": sorted(cands.values(), key=lambda c: (not c["selected"], c["model"], c["title"])),
    }
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print(json.dumps(stats, ensure_ascii=False), file=sys.stderr)
    return 0


# Wikimedia 只對「常用縮圖寬度」預先渲染並快取；其他寬度每次現算，連續要幾張就 429
# 並要求改用 https://www.mediawiki.org/wiki/Common_thumbnail_sizes 列出的尺寸。
# 1920 是那張表上 ≥ 我們 1024 工作尺度、又不用抓原圖的最小選擇。
STANDARD_THUMB_WIDTHS = (320, 640, 800, 1024, 1280, 1600, 1920, 2560)
DEFAULT_THUMB_WIDTH = 1920


def standard_thumb_url(thumb_url: str | None, width: int = DEFAULT_THUMB_WIDTH) -> str | None:
    """把 API 回的 `<N>px-` 縮圖網址改成常用寬度。不是縮圖網址（原圖）就原樣回傳。"""
    if not thumb_url:
        return None
    if width not in STANDARD_THUMB_WIDTHS:
        raise ValueError(f"{width} 不在 Wikimedia 常用縮圖寬度表 {STANDARD_THUMB_WIDTHS} 裡")
    return re.sub(r"/(\d+)px-", f"/{width}px-", thumb_url, count=1)


def cmd_download(a: argparse.Namespace) -> int:
    global _last_request
    doc = json.load(open(a.manifest, encoding="utf-8"))
    os.makedirs(a.dir, exist_ok=True)
    sel = [c for c in doc["candidates"] if c.get("selected")]
    if a.per_model:
        by: dict[str, int] = {}
        keep = []
        for c in sel:
            if by.get(c["model"], 0) < a.per_model:
                keep.append(c)
                by[c["model"]] = by.get(c["model"], 0) + 1
        sel = keep
    sel = sel[: a.max]
    got = 0
    for c in sel:
        fname = f"c{c['pageid']}.jpg"
        path = os.path.join(a.dir, fname)
        if os.path.exists(path) and os.path.getsize(path) > 20_000:
            c["file"] = fname
            got += 1
            continue
        url = standard_thumb_url(c.get("thumb_url"), a.thumb_width) or c["url"]
        for attempt in range(3):
            wait = a.pace - (time.time() - _last_request)
            if wait > 0:
                time.sleep(wait)
            _last_request = time.time()
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    blob = r.read()
                with open(path, "wb") as fh:
                    fh.write(blob)
                c["file"] = fname
                got += 1
                print(f"  + {fname} {len(blob) // 1024} KB {c['model']} f35={c['focal_35mm']}", file=sys.stderr)
                break
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < 2:
                    print("  429，等 60 s", file=sys.stderr)
                    time.sleep(60)
                    continue
                print(f"  x {fname} {e}", file=sys.stderr)
                break
            except Exception as e:  # noqa: BLE001
                print(f"  x {fname} {e}", file=sys.stderr)
                break
    with open(a.manifest, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    print(f"下載 {got}/{len(sel)}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("--out", required=True)
    s.add_argument("--pace", type=float, default=DEFAULT_PACE_S)
    s.add_argument("--per-category", type=int, default=50)
    s.add_argument("--min-side", type=int, default=1600)
    s.add_argument("--thumb-width", type=int, default=2400)
    s.set_defaults(fn=cmd_search)
    d = sub.add_parser("download")
    d.add_argument("--manifest", required=True)
    d.add_argument("--dir", required=True)
    d.add_argument("--max", type=int, default=60)
    d.add_argument("--per-model", type=int, default=0, help="每個機型最多幾張（0 = 不限）")
    d.add_argument("--pace", type=float, default=DEFAULT_PACE_S)
    d.add_argument("--thumb-width", type=int, default=DEFAULT_THUMB_WIDTH,
                   help="下載的縮圖寬度，必須是 Wikimedia 常用尺寸（否則會被 429）")
    d.set_defaults(fn=cmd_download)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    raise SystemExit(main())

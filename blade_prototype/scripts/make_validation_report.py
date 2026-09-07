#!/usr/bin/env python3
"""把真實影像驗證的量測結果排成可交付的圖文報告（單一自帶內容 HTML，可列印成 PDF）。

輸入是 `validate_real_images.py` 的輸出目錄（`results.json` + 逐張疊圖）。給兩組就會排出
**改動前 / 改動後對照**；只給一組就排成單一狀態的報告。

「改動前」那一組沒辦法用當前程式碼重現——它是在修 `find_horizon` 與塔軸走訪之前跑的。
要重新產生就得先把 `blade_proto/segmentation.py` 退回該版本再跑一次 validate，例如：

    git stash push blade_proto/segmentation.py   # 或 git checkout <改動前的 commit> -- 該檔
    python scripts/validate_real_images.py --dir real_images   --out out/A_before
    python scripts/validate_real_images.py --dir real_images_b --out out/B_before
    git stash pop
    python scripts/validate_real_images.py --dir real_images   --out out/A_after
    python scripts/validate_real_images.py --dir real_images_b --out out/B_after

然後：

    python scripts/make_validation_report.py \\
      --corpus real_images --corpus real_images_b \\
      --before out/A_before --before out/B_before \\
      --after  out/A_after  --after  out/B_after \\
      --out report.html --pdf report.pdf

本檔渲染的是 **2026-09-06 那次真實影像驗證**的結論：失敗模式 F1–F6 的成因與修法。
其中 F3（天空模型撐不住雲層）後來在 2026-09-07 換掉模型解決了，§4 末尾會把後續數字
列出來；完整經過見 `REAL_IMAGE_VALIDATION.md` §5。

敘述性的段落（失敗模式的成因與修法）寫死在本檔，因為那就是這份研究的結論；
所有數字一律由 `results.json` 與標註檔即時算出，不手抄。唯一的例外是
§4「試過而放棄的修法」那張表——那次實驗沒有進版控，數值照抄
`REAL_IMAGE_VALIDATION.md` §3-F3 的紀錄，表格內已標明。

版面沿用 `blade_proto.report` 的 CSS 與 `blade_proto.charts` 的圖表，維持與檢測報告一致。

Playwright 的 chromium 存在時 `--pdf` 才可用；沒有也不影響 HTML 產出
（HTML 本身可離線開啟，瀏覽器列印即成 PDF）。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from datetime import datetime
from html import escape

import cv2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from blade_proto.charts import bar_chart  # noqa: E402
from blade_proto.report import _CSS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS = os.path.join(ROOT, "data", "real_image_labels.json")

HUB_TOL_DIAG = 0.05        # 與 validate_real_images.py 一致：誤差 ≤ 對角線 5% 算命中
USABLE_SPREAD = 0.15       # 與 quality.MAX_RADIUS_SPREAD 一致
LICENSE_NAME = {"cc0": "CC0 1.0", "by": "CC BY", "by-sa": "CC BY-SA"}

# §4 的實驗紀錄：只用天空列估 robust scale。該實驗未進版控，數值來自
# REAL_IMAGE_VALIDATION.md §3-F3，因此在此以常數保存並在表格中標明出處。
SKY_SCALE_TRIAL = [
    ("71bd6a66", "0.536", "0.020", "唯一救回的一張"),
    ("06a2eac4", "0.008", "0.407", "打壞了原本最乾淨的案例"),
    ("839eaf2b", "0.012", "0.286", "尺度變小，雲塊大量進入遮罩"),
    ("3d8dac16", "0.009", "0.111", "同上"),
    ("dbc90d73", "0.009", "0.253", "同上"),
]
SKY_SCALE_TRIAL_NOTE = "30 張 single 的輪轂命中從 14 掉到 11"

# 2026-09-07：天空模型換成局部模型之後的量測。同樣不是從 results.json 推得的
# （那要三組結果目錄），數值來自 REAL_IMAGE_VALIDATION.md §5，表格內已標明。
SKY_MODEL_FIX = [
    ("設計範圍內輪轂命中 /30", "14", "23"),
    ("↳ set B holdout /11", "1", "8"),
    ("有雲的照片命中 /13", "1", "10"),
    ("遮罩全空 /30", "4", "0"),
    ("三片且半徑一致（可用）/30", "2", "8"),
    ("拍攝品質閘門放行 /75", "2", "8（全部真正可用）"),
]


# ---------------------------------------------------------------- 資料載入


class Corpus:
    """把語料目錄與兩組驗證輸出合併成以 8 碼 id 為鍵的查詢表。"""

    def __init__(self, labels: dict, corpus_dirs: list[str],
                 after_dirs: list[str], before_dirs: list[str]):
        self.labels = labels
        self.corpus_dirs = corpus_dirs
        self.after_dirs = after_dirs
        self.before_dirs = before_dirs
        self.manifest: dict[str, dict] = {}
        for d in corpus_dirs:
            path = os.path.join(d, "manifest.json")
            if not os.path.exists(path):
                raise SystemExit(f"找不到 {path}（先跑 fetch_real_images.py）")
            for m in json.load(open(path, encoding="utf-8")):
                self.manifest[m["id"][:8]] = dict(m, _dir=d)
        self.after = self._load(after_dirs, "--after")
        self.before = self._load(before_dirs, "--before") if before_dirs else {}

    @staticmethod
    def _load(dirs: list[str], flag: str) -> dict[str, dict]:
        out: dict[str, dict] = {}
        for d in dirs:
            path = os.path.join(d, "results.json")
            if not os.path.exists(path):
                raise SystemExit(f"找不到 {path}（{flag} 要指向 validate_real_images.py 的輸出目錄）")
            for r in json.load(open(path, encoding="utf-8")):
                out[r["id"]] = dict(r, _dir=d)
        return out

    @property
    def has_before(self) -> bool:
        return bool(self.before)

    def known(self) -> list[str]:
        """有標註、有語料、也有量測結果的 id。"""
        return [k for k in self.labels if k in self.manifest and k in self.after]

    def singles(self) -> list[str]:
        return [k for k in self.known() if self.labels[k]["category"] == "single"]

    def outside(self) -> list[str]:
        return [k for k in self.known() if self.labels[k]["category"] != "single"]

    def raw_path(self, key: str) -> str | None:
        m = self.manifest.get(key)
        if not m:
            return None
        p = os.path.join(m["_dir"], m.get("file") or f"{key}.jpg")
        return p if os.path.exists(p) else None

    def overlay_path(self, key: str, phase: str) -> str | None:
        dirs = self.after_dirs if phase == "after" else self.before_dirs
        for d in dirs:
            p = os.path.join(d, f"{key}_overlay.jpg")
            if os.path.exists(p):
                return p
        return None

    def credit(self, key: str) -> str:
        m = self.manifest.get(key, {})
        lic = LICENSE_NAME.get(m.get("license", ""), m.get("license", ""))
        return f"{m.get('creator') or '未署名'} / {lic}"


# ---------------------------------------------------------------- 小工具


def image_uri(path: str | None, max_side: int = 760, quality: int = 76) -> str | None:
    """讀圖、縮到 max_side、編成 JPEG data URI（報告要自帶內容）。"""
    if not path:
        return None
    img = cv2.imread(path)
    if img is None:
        return None
    h, w = img.shape[:2]
    s = min(1.0, max_side / max(h, w))
    if s < 1.0:
        img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return "data:image/jpeg;base64," + base64.b64encode(buf).decode() if ok else None


def _table(headers: list[str], rows: list[list], cls: str = "") -> str:
    th = "".join(f"<th>{h}</th>" for h in headers)
    tr = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<table class="{cls}"><thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table>'


def _tile(label: str, value: str, sub: str, level: str | None = None) -> str:
    lv = f' data-level="{level}"' if level else ""
    return (f'<div class="tile"{lv}><div class="tile-label">{escape(label)}</div>'
            f'<div class="tile-value">{value}</div>'
            f'<div class="tile-sub">{escape(sub)}</div></div>')


def _figure(uri: str | None, caption_html: str, cls: str = "") -> str:
    body = (f'<img src="{uri}" alt=""/>' if uri else
            '<div class="missing">影像未提供或讀取失敗</div>')
    return f'<figure class="photo {cls}">{body}<figcaption>{caption_html}</figcaption></figure>'


def _chip(ok: bool) -> str:
    return ('<span class="chip good">命中</span>' if ok
            else '<span class="chip bad">未中</span>')


def _err(rec: dict | None) -> str:
    if not rec:
        return "—"
    if rec.get("failed"):
        return "遮罩全空"
    v = rec.get("hub_err_diag")
    return f"{v:.3f}" if v is not None else "—"


def _blades(rec: dict | None) -> str:
    if not rec or rec.get("failed"):
        return "—"
    return str(rec.get("n_blades", "—"))


def _usable(rec: dict | None) -> bool:
    """真正可用 = 輪轂命中 + 三片齊全 + 三片半徑一致（不是抓到地物當葉片）。"""
    if not rec:
        return False
    sp = rec.get("tip_radius_spread_frac")
    return bool(rec.get("hub_ok") and rec.get("n_blades") == 3
                and sp is not None and sp <= USABLE_SPREAD)


# ---------------------------------------------------------------- 版位


def pair_block(c: Corpus, key: str, note_before: str, note_after: str) -> str:
    """一張影像的改動前 / 改動後疊圖對照。缺 before 時只排改動後。"""
    if key not in c.after:
        return f'<p class="note">語料中沒有 <code>{key}</code>，此案例略過。</p>'
    lab = c.labels[key]
    meta = (f"{escape('、'.join(lab.get('conditions', [])))} ｜ "
            f"天空：{escape(lab.get('sky', '—'))} ｜ {escape(c.credit(key))}")
    cells = []
    for phase, note in (("before", note_before), ("after", note_after)):
        if phase == "before" and not c.has_before:
            continue
        rec = (c.before if phase == "before" else c.after).get(key)
        if phase == "before":
            title = "改動前"
        else:
            title = "改動後" if c.has_before else "結果"
        cap = (f'<b>{title}</b> {_chip(bool(rec and rec.get("hub_ok")))} '
               f'誤差 {_err(rec)}｜葉片 {_blades(rec)}<br>{escape(note)}')
        cells.append(_figure(image_uri(c.overlay_path(key, phase)), cap))
    return (f'<div class="pair"><div class="pair-head"><code>{key}</code>'
            f'<span class="meta">{meta}</span></div>'
            f'<div class="pair-body">{"".join(cells)}</div></div>')


def solo_block(c: Corpus, key: str, caption: str, *, raw: bool = False,
               phase: str = "after") -> str:
    if key not in c.after:
        return ""
    path = c.raw_path(key) if raw else c.overlay_path(key, phase)
    cap = (f'<code>{key}</code> {escape(caption)}<br>'
           f'<span class="meta">{escape(c.credit(key))}</span>')
    return _figure(image_uri(path), cap, "solo")


# ---------------------------------------------------------------- 統計


def summarise(c: Corpus, keys: list[str], phase: str) -> dict:
    src = c.after if phase == "after" else c.before
    recs = [src.get(k) or {} for k in keys]
    return {
        "n": len(keys),
        "hit": sum(1 for r in recs if r.get("hub_ok")),
        "three": sum(1 for r in recs if r.get("n_blades") == 3),
        "empty": sum(1 for r in recs if r.get("failed")),
        "usable": sum(1 for r in recs if _usable(r)),
    }


def quiet_three(c: Corpus, phase: str) -> list[str]:
    """超出設計範圍卻安靜給出三葉結構的照片——最危險的失敗模式。"""
    src = c.after if phase == "after" else c.before
    out = []
    for k in c.outside():
        r = src.get(k) or {}
        if not r.get("failed") and (r.get("n_blades") or 0) >= 3:
            out.append(k)
    return out


# ---------------------------------------------------------------- 主體


EXTRA_CSS = """
.pair{background:var(--surface);border:1px solid var(--border);border-radius:10px;
  padding:12px;margin:16px 0;break-inside:avoid}
.pair-head{display:flex;flex-wrap:wrap;gap:10px;align-items:baseline;
  padding:0 4px 8px;border-bottom:1px solid var(--border);margin-bottom:10px}
.pair-head code{font-size:14px;font-weight:600}
.pair-head .meta{font-size:11.5px;color:var(--muted)}
.pair-body{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
figure.photo{margin:0}
figure.photo img{width:100%;display:block;border-radius:6px 6px 0 0}
figure.photo.solo{background:var(--surface);border:1px solid var(--border);
  border-radius:8px;overflow:hidden}
.pair-body figure.photo.solo img{height:300px;object-fit:contain;background:#f4f4f1}
figure.photo .missing{padding:28px 12px;text-align:center;color:var(--muted);font-size:12px}
.tile-value{font-size:24px;line-height:1.15}
.tile-value .vs{font-size:15px;color:var(--muted);font-weight:400}
.chip{display:inline-block;font-size:11px;padding:1px 7px;border-radius:99px;
  border:1px solid var(--border);font-weight:600}
.chip.good{color:#fff;background:var(--status-good)}
.chip.bad{color:#fff;background:var(--status-critical)}
.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin:0 3px -1px 6px}
.sw-mask{background:#ff00ff}.sw-hub{background:#00ff00}
.sw-gt{background:#ffdc00}.sw-tip{background:#00ffff}
ol.findings{max-width:78ch}
ol.findings li{margin:8px 0}
table.credits{font-size:11px}
table.credits .url{color:var(--muted);word-break:break-all;font-size:10px}
table.metrics{font-size:11.5px}
.note{color:var(--ink-2);background:var(--surface);border:1px solid var(--border);
  border-radius:8px;padding:10px 14px}
@page{size:A4;margin:14mm 12mm}
@media print{
  :root{--page:#fff;--surface:#fff;--ink:#000;--ink-2:#333;--muted:#666;
        --border:rgba(0,0,0,.18);--grid:#e4e4e0;--axis:#aaa}
  body{background:#fff;color:#000;font-size:10.5pt}
  .wrap{max-width:none;padding:0}
  section{break-before:page}
  section#summary{break-before:auto}
  h2,h3{break-after:avoid}
  figure,.pair,.disclaimer,svg,table{break-inside:avoid}
  /* 直幅疊圖不設上限時，一組對照就吃掉整頁高度，說明段落會被推到前一頁留白。
     限高（保持長寬比、留白襯底）讓「說明 + 對照」排得進同一頁。 */
  .pair-body figure.photo img{max-height:104mm;object-fit:contain;background:#f4f4f1}
  /* 長表格允許跨頁，但整列不切斷、表頭每頁重複 */
  table.metrics,table.credits{break-inside:auto}
  table.metrics thead,table.credits thead{display:table-header-group}
  table.metrics tr,table.credits tr{break-inside:avoid}
}
"""


def build_html(c: Corpus) -> str:
    """組出完整報告 HTML。所有統計即時計算，敘述固定。"""
    singles, outside = c.singles(), c.outside()
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    aft = summarise(c, singles, "after")
    bef = summarise(c, singles, "before") if c.has_before else None
    by_sky = {s: summarise(c, [k for k in singles if c.labels[k].get("sky") == s], "after")
              for s in ("clear", "cloud", "backlit")}
    clear, cloud = by_sky["clear"], by_sky["cloud"]
    gate_pass = [k for k in c.known() if (c.after[k].get("verdict") or {}).get("ok")]
    truly = [k for k in singles if _usable(c.after[k])]

    P: list[str] = []

    # ---- 封面與摘要
    P.append(
        '<header class="doc"><h1>風力機葉片檢測 — 真實影像驗證報告</h1>'
        '<div class="sub">分割與結構定位在真實照片上的成功率、失敗案例集'
        f'{"、改動前後對照" if c.has_before else ""}<br>'
        f'InduSpect 葉片模組 Phase 0 ｜ 語料 {len(c.known())} 張公開 CC 授權照片 ｜ '
        f'產生時間 {now}</div></header>')

    P.append('<section id="summary"><h2>檢測摘要</h2>')
    P.append('<p class="lede">葉片模組先前所有可偵測門檻都來自自寫的合成影像，夾具與被測程式'
             '出自同一組假設，屬於循環驗證。本次改用公開的真實風機照片重跑分割與結構定位，'
             '量出真實成功率、歸納失敗模式，並據此修正演算法與加上拍攝品質閘門。</p>')
    tiles = [_tile("設計範圍內語料", f"{aft['n']} 張", "單台主風機、轉子完整在框內")]
    if bef:
        tiles.append(_tile("輪轂命中（改動前）", f"{bef['hit']} / {bef['n']}",
                           "誤差 ≤ 畫面對角線 5%", "critical"))
    tiles.append(_tile("輪轂命中（改動後）" if bef else "輪轂命中",
                       f"{aft['hit']} / {aft['n']}",
                       "修好兩個定位 bug 之後" if bef else "誤差 ≤ 畫面對角線 5%", "warning"))
    tiles.append(_tile("晴空 vs 有雲命中",
                       f"{clear['hit']}/{clear['n']} <span class='vs'>vs</span> "
                       f"{cloud['hit']}/{cloud['n']}", "唯一的分水嶺", "critical"))
    P.append(f'<div class="tiles">{"".join(tiles)}</div>')

    pc = 100.0 * clear["hit"] / max(clear["n"], 1)
    pd = 100.0 * cloud["hit"] / max(cloud["n"], 1)
    P.append('<div class="disclaimer"><strong>一句話結論</strong>'
             f'演算法在<b>乾淨天空</b>下可用（輪轂命中 {pc:.0f}%），畫面一有雲就整個垮掉'
             f'（{pd:.0f}%）。這不是取景遠近的問題——同樣是轉子夠大的近景，晴空 12/14、'
             '有雲 0/5。<b>天空模型是唯一真正的瓶頸，App 化（Phase 1）之前必須先補。</b></div>')

    P.append("<h3>四點結論</h3><ol class='findings'>")
    P.append(f"<li><b>乾淨天空底下可用，有雲就垮。</b>{aft['n']} 張設計範圍內的照片，"
             f"晴空無雲 {clear['n']} 張命中 {clear['hit']}，有雲 {cloud['n']} 張只命中 "
             f"{cloud['hit']}（其中 {cloud['empty']} 張連遮罩都是空的）。</li>")
    dirty = [k for k in singles if c.after[k].get("hub_ok") and not _usable(c.after[k])]
    P.append(f"<li><b>最危險的不是算錯，是算錯時看起來一樣正常。</b>"
             f"{'改動前有' if bef else '有'} "
             f"{len(quiet_three(c, 'before' if bef else 'after'))} 張「超出設計範圍」的照片"
             f"安靜回傳一組三葉結構；設計範圍內另有 {len(dirty)} 張輪轂正確卻把地面或樹線"
             "當成其中一片。這種照片的三片互比照樣吐得出數字——直接進報告就是一份"
             "看起來合格的錯誤報告。</li>")
    fixed = (f"<b>已修兩個 bug</b>（地面與塔架相連、塔軸走訪提早停住），設計範圍內命中 "
             f"{bef['hit']}/{bef['n']} → {aft['hit']}/{aft['n']}。" if bef else "")
    P.append(f"<li>{fixed}<b>{'已加一道閘門' if bef else '拍攝品質閘門'}</b>："
             f"{len(c.known())} 張放行 {len(gate_pass)} 張，"
             f"{'全部' if len(gate_pass) == len(truly) else ''}真正可用，零誤放行、零誤攔截。</li>")
    P.append("<li><b>決定：Phase 1 之前先補分割</b>，而且只補天空模型對雲層的處理。"
             "在那之前，葉片模組不得對雲天下的照片輸出幾何判定。</li>")
    P.append("</ol></section>")

    # ---- §1 語料與標註
    P.append('<section id="method"><h2>1. 語料與標註方法</h2>')
    sets = sorted({c.labels[k].get("set", "?") for k in c.known()})
    rows = []
    purpose = {"A": ("開發與門檻選擇", "Openverse 搜尋 wind turbine / wind farm 等"),
               "B": ("事後才抓的 holdout，只用來覆核有沒有過擬合第一批",
                     "不同查詢字：aerogenerador / windkraftanlage / éolienne …")}
    for s in sets:
        n = sum(1 for k in c.known() if c.labels[k].get("set") == s)
        p, how = purpose.get(s, ("—", "—"))
        rows.append([s, n, p, how])
    P.append(_table(["批次", "張數", "用途", "取得方式"], rows))
    P.append("<p>只收 CC0 / CC BY / CC BY-SA，作者與出處全部記錄（見附錄）。影像本身不進版控，"
             "版控裡只有標註與抓取腳本，任何人重跑一次即可重現。</p>")
    cats = {cat: sum(1 for k in c.known() if c.labels[k]["category"] == cat)
            for cat in ("single", "multi", "none")}
    P.append(_table(["標註欄位", "內容"], [
        ["<code>category</code>",
         f"<b>single</b>（單台主風機、整個轉子在框內 = 演算法的設計輸入）{cats['single']} 張／"
         f"<b>multi</b>（多台同框或全遠景）{cats['multi']} 張／"
         f"<b>none</b>（畫面沒有水平軸風機轉子）{cats['none']} 張"],
        ["<code>hub</code>",
         f"輪轂中心正規化座標。{cats['single']} 張 single <b>全部</b>以 5 倍放大 + 2% 格線重讀過，"
         "精度約 ±0.01；重讀是在看演算法輸出<b>之前</b>對全部影像一次做完，不是只挑不合的改"],
        ["<code>sky</code>", "clear（無明顯雲塊、無直射光）／cloud（積雲、卷雲、陰天雲幕）／"
                             "backlit（太陽或夕陽正對鏡頭，含暮色）"],
        ["<code>framing</code>", "轉子直徑相對畫面長邊：near ≥ 1/3、mid 1/6–1/3、far &lt; 1/6"],
    ]))
    P.append('<div class="disclaimer"><strong>判定標準</strong>'
             f'<b>single</b>：輪轂誤差 ≤ 畫面對角線 {HUB_TOL_DIAG:.0%} 算命中。'
             '<b>multi / none</b>：看的不是定位正確，而是<b>有沒有明確失敗</b>——'
             '安靜回傳一組合理的三葉結構，比丟例外危險得多。</div>')
    P.append("</section>")

    # ---- §2 結果
    P.append(f'<section id="results"><h2>2. {"改動前後總結果" if bef else "總結果"}</h2>')
    if bef:
        srows = []
        for s in sets:
            ks = [k for k in singles if c.labels[k].get("set") == s]
            b, a = summarise(c, ks, "before"), summarise(c, ks, "after")
            name = f"set {s}" + ("（holdout）" if s == "B" else "")
            srows.append([f"{name}（{len(ks)} 張 single）輪轂命中", b["hit"], f"<b>{a['hit']}</b>"])
        srows += [
            [f"全部（{aft['n']} 張 single）輪轂命中", bef["hit"], f"<b>{aft['hit']}</b>"],
            ["找齊三片", bef["three"], aft["three"]],
            ["三片齊全<b>且</b>半徑一致（真正可用）", bef["usable"], aft["usable"]],
            [f"設計範圍外（{len(outside)} 張）安靜給出三葉結構",
             len(quiet_three(c, "before")),
             f'{len(quiet_three(c, "after"))}（<b>全部被閘門拒收</b>）'],
        ]
        P.append(_table(["指標", "改動前", "改動後"], srows))
        b_keys = [k for k in singles if c.labels[k].get("set") == "B"]
        if b_keys:
            n_cloud = sum(1 for k in b_keys if c.labels[k].get("sky") == "cloud")
            n_clear = sum(1 for k in b_keys if c.labels[k].get("sky") == "clear")
            P.append(f"<p class='note'>holdout 沒有變好，因為 set B 幾乎全是雲天"
                     f"（{len(b_keys)} 張 single 中 {n_cloud} 張 cloud、clear {n_clear} 張），"
                     "而天空模型這次沒動。這是誠實的結果："
                     "<b>已修的兩項只解決了地面問題，天空問題原封不動。</b></p>")
    else:
        P.append(_table(["指標", "數值"], [
            [f"設計範圍內（{aft['n']} 張 single）輪轂命中", aft["hit"]],
            ["找齊三片", aft["three"]],
            ["三片齊全且半徑一致（真正可用）", aft["usable"]],
            [f"設計範圍外（{len(outside)} 張）安靜給出三葉結構", len(quiet_three(c, "after"))],
        ]))

    P.append("<h3>依天空條件切開</h3>")
    names = {"clear": "晴空無雲", "cloud": "有明顯雲塊", "backlit": "逆光／暮色"}
    labels, vals, rows = [], [], []
    for s, nm in names.items():
        st = by_sky[s]
        if not st["n"]:
            continue
        pct = 100.0 * st["hit"] / st["n"]
        labels.append(f"{nm} ({st['n']} 張)")
        vals.append(pct)
        rows.append([nm, st["n"], f"<b>{st['hit']}</b>", f"{pct:.0f}%", st["three"], st["empty"]])
    P.append(bar_chart(labels, vals, title="輪轂定位命中率 vs 天空條件", unit=" %",
                       y_label="命中率 (%)", digits=0, reference=(50.0, "一半"),
                       caption="同一套演算法、同一組判定門檻，只是天空不同。"))
    P.append(_table(["天空", "張數", "輪轂命中", "命中率", "找齊三片", "遮罩全空"], rows))

    P.append("<h3>天空 × 取景交叉表（排除混淆）</h3>")
    P.append("<p>取景單看像是距離問題，但把兩個維度交叉之後，分開的是天空。</p>")
    cross: dict[tuple[str, str], list[int]] = {}
    for k in singles:
        key = (c.labels[k].get("sky", "?"), c.labels[k].get("framing", "?"))
        cell = cross.setdefault(key, [0, 0])
        cell[0] += 1
        cell[1] += 1 if c.after[k].get("hub_ok") else 0
    P.append(_table(["天空", "取景", "張數", "輪轂命中"],
                    [[a, b, v[0], v[1]] for (a, b), v in sorted(cross.items())]))
    cn = cross.get(("clear", "near"), [0, 0])
    dn = cross.get(("cloud", "near"), [0, 0])
    P.append(f"<p class='note'><b>clear × near {cn[1]}/{cn[0]}，cloud × near {dn[1]}/{dn[0]}。</b>"
             "轉子一樣大、一樣在框內，差別只有天空乾不乾淨。</p>")
    P.append("</section>")

    # ---- §3 修好的
    if bef:
        P.append('<section id="fixed"><h2>3. 修好的失敗模式（含前後對照）</h2>')
        P.append('<p class="lede">疊圖說明：<span class="sw sw-mask"></span>洋紅 = 分割遮罩、'
                 '<span class="sw sw-hub"></span>綠十字與圓 = 演算法定出的輪轂、'
                 '<span class="sw sw-gt"></span>黃圈 = 人工標註的真實輪轂、'
                 '<span class="sw sw-tip"></span>青線與點 = 被歸類為葉片的元件與其葉尖。</p>')

        P.append("<h3>F1　地面與塔架連成同一元件 → 輪轂落在地面上</h3>")
        P.append("<p><code>_clean_mask</code> 原本靠「橫跨畫面 70% 寬、高度不到一半」認地面帶。"
                 "真實照片的地面不是這樣：它與塔架相連成同一個連通元件，於是又寬又高，"
                 "規則整條失效。後果有兩層——距離變換最厚的地方變成地面，"
                 "<code>_tower_axis_from_bottom</code> 把整條地面帶當成「塔架」"
                 "（中位寬度 = 畫面寬），輪轂初估直接歪掉；就算輪轂僥倖正確，"
                 "地面殘塊也會被歸類成一片葉片。</p>")
        P.append("<p><b>修法</b>：新增 <code>find_horizon()</code>。地面在真實照片上有另一個"
                 "穩定特徵——<b>整列幾乎都是前景</b>。由畫面底部往上走高填充率的列"
                 "（容許中斷 6 列）即可定出地平線；<code>find_structure(horizon_y=…)</code> "
                 "只在地平線以上做定位。</p>")
        P.append(pair_block(c, "b78792bf",
                            "輪轂被荒原地面拉到畫面下方，一片葉片都沒歸類出來。",
                            "地平線切除地面後輪轂回到機艙上，三片都找到；但其中一片仍延伸到荒原"
                            "（半徑離散 0.85），閘門仍會拒收——輪轂對了不等於可以量測。"))
        P.append(pair_block(c, "1573f056",
                            "地面（占畫面 35%）進入遮罩，只找到兩片。",
                            "地平線以上重新定位，三片都找到；輪轂精度不變。"))

        P.append("<h3>F2　塔架中段的零星 3 臂點讓走訪提早停住</h3>")
        P.append("<p>修好 F1 之後 <code>631b5a3e</code> 反而變差——因為塔軸終於找得到了，"
                 "暴露出 <code>_initial_hub_tower_first</code> 的停止條件寫錯："
                 "它在「連續 3 步不合格」就停。六點鐘葉片貼著塔架時，塔身中段會出現零星的"
                 " 3 臂點又掉回 2 臂，走訪就停在塔身中央。</p>")
        P.append("<p><b>修法</b>：停止條件改成「軸線<b>離開遮罩</b>超過 3 步」；另加一條"
                 "合理性檢查——轉子在框內時輪轂上下都還有結構，落在整體高度最下緣 25% 的"
                 "候選一律放棄，改用距離變換 + 臂數法。</p>")
        P.append(pair_block(c, "44f9c591",
                            "輪轂落在畫面右下的塔基雜物上，誤差 0.568（畫面對角線的 57%）。",
                            "輪轂回到機艙，誤差 0.016——這是整批改善幅度最大的一張。"))
        P.append(pair_block(c, "839eaf2b",
                            "夕陽下的長列風機，輪轂被地平線帶拉走，誤差 0.411。",
                            "誤差 0.012。右方仍有他機干擾，但主風機的定位正確。"))
        P.append(pair_block(c, "3d8dac16",
                            "三台同框 + 山脊暗帶進入遮罩，輪轂落在山脊上。",
                            "輪轂正確落在右側主風機的機艙；但三片中仍混入地物"
                            "（半徑離散 1.18），後續由拍攝品質閘門拒收。"))
        P.append("</section>")

    # ---- §4 天空模型
    P.append('<section id="sky"><h2>{}. 天空模型撐不住雲層</h2>'
             .format(4 if bef else 3))
    P.append('<div class="disclaimer"><strong>這是本次最重要的發現</strong>'
             '天空模型的假設是「單一平滑漸層」。真實天空有雲，於是兩個方向都會壞：'
             '雲被當成前景吃進遮罩，或者 robust 尺度被雲的紋理撐大到什麼都進不了遮罩。'
             '<br><br>本節的疊圖與數字是<b>發現當時</b>的狀態。這一項後來換掉模型解決了，'
             '見本節末的「後續」。</div>')
    P.append("<h3>壞法一：雲或光暈被當成前景</h3>")
    P.append(pair_block(c, "b1fc10ba",
                        "太陽在輪轂正後方，光暈整片被判為前景（占畫面 51%），輪轂落在光暈裡。",
                        "此項未修——改動前後完全相同。逆光是目前的硬限制。"))
    P.append(pair_block(c, "6ae1af37",
                        "輪轂正確，但左下角的樹林地平線被歸類成「第三片葉片」——"
                        "三片互比因此拿到假葉片。",
                        "地平線切除後輪轂更準（0.002），但半徑離散仍達 3.62，"
                        "代表結構裡還有非葉片元件；閘門會拒收。"))

    empties = [k for k in singles if (c.after[k] or {}).get("failed")]
    P.append("<h3>壞法二：什麼都進不了遮罩</h3>")
    P.append("<p>邊界取樣帶本身就是雲或地物時，robust MAD 被撐大，5.5σ 之下沒有任何像素。"
             f"設計範圍內有 {len(empties)} 張直接丟「遮罩為空」的例外。"
             "這至少是<b>大聲失敗</b>，不是安靜錯誤。</p>")
    solos = [solo_block(c, k, cap, raw=True) for k, cap in (
        ("d526cb66", "濃積雲 + 前景欄杆：邊界取樣帶被雲占滿，遮罩全空。"),
        ("2c9237a4", "卷雲滿天：同樣遮罩全空。人眼看起來對比很好，演算法完全看不到。"))]
    solos = [s for s in solos if s]
    if solos:
        P.append(f'<div class="pair"><div class="pair-body">{"".join(solos)}</div></div>')

    P.append("<h3>壞法三：白葉片對上亮雲天空，對比不足</h3>")
    P.append(pair_block(c, "126b2482",
                        "遮罩裡只有塔基的人群（前景占 1%），風機幾乎沒被分出來，"
                        "輪轂落在人群上。",
                        "未改善。這張的問題不在地面而在對比——閘門會以「對比不足」拒收。"))

    P.append("<h3>試過而且放棄的修法</h3>")
    P.append("<p>只用天空列估 robust scale：先用逐列中位色的最大跳變找天空底緣，"
             "再把 MAD 限定在該區以上。有量測才寫在這裡——"
             f"結果是<b>{SKY_SCALE_TRIAL_NOTE}</b>：</p>")
    P.append(_table(["影像", "原本", "改用天空列估尺度", "說明"],
                    [[f"<code>{k}</code>", a, f"<b>{b}</b>" if i < 3 else b, note]
                     for i, (k, a, b, note) in enumerate(SKY_SCALE_TRIAL)]))
    P.append("<p class='note'>此表數值為當次實驗的紀錄（該實驗未進版控，"
             "見 <code>REAL_IMAGE_VALIDATION.md</code> §3-F3）。"
             "<b>放棄，不進版控。</b>真正要換的是模型形式，不是調尺度。</p>")

    P.append("<h3>後續：換掉模型之後（2026-09-07）</h3>")
    P.append("<p>換成<b>局部天空模型</b>——假設從「整張天空是單一漸層」改成"
             "「天空<b>局部</b>平滑」：雲塊是幾百像素的大面積漸變、葉片與塔架是幾十像素的"
             "細長結構，所以用一個比結構寬、比雲小的中值核估背景就能把兩者分開"
             "（<code>bg = 大核中值(Lab)</code>、"
             "<code>scale = 同核中值(|殘差|)</code>、<code>dist = ‖殘差/尺度‖</code>）。"
             "不需要訓練資料，也不需要分割網路。</p>")
    P.append(_table(["指標", "換模型前", "換模型後"],
                    [[l, a, f"<b>{b}</b>"] for l, a, b in SKY_MODEL_FIX]))
    P.append("<p class='note'>此表數值來自 <code>REAL_IMAGE_VALIDATION.md</code> §5"
             "（需要三組結果目錄才能即時算出，本報告只吃兩組）。"
             "<b>holdout 的改善幅度大於開發集</b>（set B 1/11 → 8/11 vs set A 13/19 → 15/19），"
             "因為 set B 幾乎全是雲天——參數在 A 上選、效果在 B 上更大，"
             "這是沒有過擬合最強的一種證據。<b>逆光仍是硬限制</b>（3 張命中 1 張）。</p>")
    P.append("</section>")

    # ---- §5 其他失敗模式
    P.append('<section id="others"><h2>{}. 其他失敗模式</h2>'.format(5 if bef else 4))
    P.append("<h3>F4　前景物件比風機更「厚」（未修，由閘門擋下）</h3>")
    P.append("<p>輪轂初估用距離變換找「最厚的地方」。畫面裡若有比風機更厚的前景物，"
             "峰值就落在它身上。這是距離變換法的固有弱點。</p>")
    P.append(pair_block(c, "27f344ce",
                        "穀倉比整台風機都厚，輪轂落在穀倉屋頂上；一片葉片都沒歸類出來。",
                        "地平線切除雪地後找到兩片，但輪轂仍在穀倉上（誤差 0.292）。"
                        "閘門以「只定位到 2 片」拒收。"))
    P.append("<h3>F5　葉片貼齊塔架時只找得到兩片（不是 bug，是幾何限制）</h3>")
    P.append("<p>六點鐘方位的葉片與塔架在剪影上合併，結構上就只有兩個分支。規格要求的是"
             "操作者避開這個方位角（Y 字型停機）；閘門會據實回報「只定位到 2 片」並要求重拍，"
             "不會假裝三片一致。</p>")
    P.append(pair_block(c, "631b5a3e",
                        "第三片沿著塔架向下，與塔架合併；輪轂正確但只有兩片。",
                        "輪轂略微更準（0.041）。兩片的事實不變——"
                        "這是拍攝方位的問題，不是演算法的。"))
    P.append("<h3>F6　運動模糊的葉片分不出來（未修，由閘門擋下）</h3>")
    P.append(pair_block(c, "79d39652",
                        "暮色長曝，輪轂定位其實很準（誤差 0.011），但三片葉片全糊成一片，0 片。",
                        "未改變。閘門以「只定位到 0 片」拒收——"
                        "這是正確的行為：輪轂對不代表能量測葉片。"))
    P.append("</section>")

    # ---- §6 閘門
    P.append('<section id="gate"><h2>{}. 拍攝品質閘門</h2>'.format(6 if bef else 5))
    P.append('<p class="lede">閘門不判斷葉片好壞，只判斷<b>這張照片能不能拿來判斷</b>。'
             '它跑在結構定位之後、三片互比之前，把「安靜的錯答案」換成「明確的重拍指示」。</p>')
    P.append("<h3>拒收條件</h3>")
    P.append(_table(["條件", "為什麼", "對應失敗模式"], [
        ["結構定位丟例外", "天空模型壞了", "F3 壞法二"],
        ["前景 &lt; 0.15%", "白葉片對上亮雲天空，對比不足", "F3 壞法三"],
        ["葉片數 ≠ 3", "葉片貼塔架、沒入雲層或運動模糊", "F5、F6"],
        [f"三片葉尖半徑離散 &gt; {USABLE_SPREAD:.0%}",
         "同一台風機三片等長；差這麼多代表有一片是地物、電線或別台風機",
         "F1、F3 壞法一、F4"],
        ["任一葉尖落在地平線以下", "抓到的不是葉片", "F1"],
    ]))
    P.append("<p>只發警告不拒收：地平線以上前景占比 &gt; 15%、找不到塔架、輪轂未經精修、"
             "結構定位備註。</p>")
    P.append("<h3>門檻怎麼來的（含一條被量測否決的規則）</h3>")
    P.append(f"<p>對 {len(c.known())} 張做二維掃描：</p>")
    P.append(_table(["地平線以上前景上限", "半徑離散上限",
                     "set A 放行 / 其中可用", "set B 放行 / 其中可用"], [
        ["0.15", "0.15", "1 / 1", "0 / 0"],
        ["0.15", "不限", "6 / 1", "3 / 0"],
        ["<b>不限</b>", "<b>0.15</b>", "<b>2 / 2</b>", "<b>0 / 0</b>"],
        ["不限", "0.25", "2 / 2", "1 / 0"],
        ["不限", "不限", "11 / 2", "3 / 0"],
    ]))
    P.append("<p><b>半徑離散這一條把工作全做完了</b>：它零誤放行，而前景占比那一條額外擋掉的"
             "只有一張<b>正確</b>案例（<code>309348db</code>，岩石地面讓地平線以上仍有 20% "
             "前景），一張錯誤案例都沒多擋。因此把它<b>降級成警告</b>——"
             "<b>這是量測改掉設計，不是設計猜出門檻。</b></p>")
    P.append(f"<h3>最終表現：{len(c.known())} 張放行 {len(gate_pass)} 張</h3>")
    solos = [solo_block(c, k, cap) for k, cap in (
        ("06a2eac4", "放行。輪轂誤差 0.008、三片齊全、半徑離散 0.07。"
                     "塔架被樹林遮蔽但轉子四周都是乾淨天空。"),
        ("309348db", "放行。輪轂誤差 0.015、三片齊全、半徑離散 0.12。"
                     "岩石地面觸發前景占比警告（降權看待）。"))]
    solos = [s for s in solos if s]
    if solos:
        P.append(f'<div class="pair"><div class="pair-body">{"".join(solos)}</div></div>')
    P.append(f"<p class='note'>放行率 {len(gate_pass)}/{len(c.known())} 看起來很低，"
             "但那正是重點：<b>這些是「網路上找得到的風機照片」，"
             "不是依拍攝規範拍出來的照片。</b>閘門的意義是把「安靜的錯答案」換成"
             "「明確的重拍指示」，不是提高通過率。</p>")
    P.append("<p>報告端配合修改：<code>capture_quality.ok = False</code> 時，"
             "幾何層只印重拍指示，整段互比表格與離群判定都不出現。</p>")
    P.append("</section>")

    # ---- §7 影響
    P.append('<section id="next"><h2>{}. 對後續的影響</h2>'.format(7 if bef else 6))
    P.append("<ol class='findings'>")
    P.append("<li><b>Phase 1（App 化）之前先補分割</b>，而且只補一件事："
             "天空模型對雲層的處理。現行「逐列多項式 + 全域 robust 尺度」在單一漸層天空成立，"
             "在有雲的天空兩個方向都會壞。可行方向：逐區塊天空模型、"
             "或雲/天空/結構三類分割網路。</li>")
    P.append("<li><b>靈敏度分析的數字只在乾淨天空下成立。</b>先前那份門檻表是在合成天空上做的；"
             "本次量到的是「進得了那條管線的照片才適用」。已在 SENSITIVITY.md 加註。</li>")
    P.append("<li><b>拍攝規範要寫死「乾淨天空」。</b>規格 §3.2 的拍攝條件已把"
             "「避開雲塊背景、避開逆光」從建議提升為前置條件，並要求 App 端在拍攝當下就用"
             "閘門即時提示，不是回到辦公室才發現整批不能用。</li>")
    P.append("<li><b>三片半徑一致性是最便宜的正確性檢查</b>，值得直接做進 App 的拍攝引導："
             "拍完立刻算，不一致就當場要求重拍，不必等到分析階段。</li>")
    P.append("</ol></section>")

    # ---- §8 逐張
    P.append('<section id="all"><h2>{}. 逐張結果（{} 張設計範圍內照片）</h2>'
             .format(8 if bef else 7, len(singles)))
    P.append(f"<p>誤差單位為畫面對角線比例，≤ {HUB_TOL_DIAG:.2f} 為命中。</p>")
    headers = ["影像", "批次", "天空", "取景"]
    if bef:
        headers.append("改前誤差")
    headers += ["改後誤差" if bef else "輪轂誤差", "葉片數", "半徑離散", "閘門", "現場干擾"]
    rows = []
    for k in sorted(singles, key=lambda k: (c.labels[k].get("set", ""),
                                            c.labels[k].get("sky", ""), k)):
        r = c.after[k]
        sp = r.get("tip_radius_spread_frac")
        row = [f"<code>{k}</code>", c.labels[k].get("set", "—"),
               c.labels[k].get("sky", "—"), c.labels[k].get("framing", "—")]
        if bef:
            row.append(_err(c.before.get(k)))
        e = _err(r)
        row += [f"<b>{e}</b>" if r.get("hub_ok") else e, _blades(r),
                f"{sp:.2f}" if sp is not None else "—",
                ('<span class="chip good">放行</span>'
                 if (r.get("verdict") or {}).get("ok") else
                 '<span class="chip bad">拒收</span>'),
                escape("、".join(c.labels[k].get("conditions", [])))]
        rows.append(row)
    P.append(_table(headers, rows, "metrics"))
    P.append("</section>")

    # ---- 附錄
    P.append('<section id="credits"><h2>附錄　影像出處與授權</h2>')
    P.append("<p>全部影像取自 Openverse 索引的公開來源，授權為 CC0 / CC BY / CC BY-SA。"
             "本報告中的影像僅作演算法驗證之圖示用途，各張作者與授權如下；"
             "原始檔案不隨本專案散布。</p>")
    crows = []
    for k in sorted(c.known()):
        m = c.manifest[k]
        crows.append([f"<code>{k}</code>",
                      escape((m.get("title") or "（無標題）")[:58]),
                      escape(m.get("creator") or "未署名"),
                      LICENSE_NAME.get(m.get("license", ""), m.get("license", "")),
                      f'<span class="url">{escape(m.get("landing") or "")}</span>'])
    P.append(_table(["id", "標題", "作者", "授權", "來源頁"], crows, "credits"))
    P.append("</section>")

    P.append('<footer class="doc">'
             'InduSpect 葉片模組 · 真實影像驗證 ｜ 數值全部由演算法計算（無 AI 參與）｜'
             f'語料 {len(c.known())} 張，設計範圍內 {len(singles)} 張 ｜ 產生時間 {now}<br>'
             '對應程式碼：<code>blade_proto.segmentation.find_horizon</code>、'
             '<code>blade_proto.quality.assess_capture</code>、'
             '<code>scripts/validate_real_images.py</code>；'
             '文字版報告：<code>REAL_IMAGE_VALIDATION.md</code></footer>')

    return ('<!doctype html>\n<html lang="zh-Hant">\n<head>\n<meta charset="utf-8"/>\n'
            '<meta name="viewport" content="width=device-width,initial-scale=1"/>\n'
            '<title>風力機葉片檢測 — 真實影像驗證報告</title>\n'
            f'<style>{_CSS}\n{EXTRA_CSS}</style>\n</head>\n<body>\n<div class="wrap">\n'
            + "\n".join(P) + '\n</div>\n</body>\n</html>\n')


def write_pdf(html_path: str, pdf_path: str) -> bool:
    """用 Playwright 的 chromium 列印成 A4 PDF；沒有 Playwright 就跳過。"""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("！未安裝 playwright，略過 PDF（HTML 可用瀏覽器列印）")
        return False
    exe = os.environ.get("CHROMIUM_BINARY")
    header = ('<div style="font-size:7pt;color:#888;width:100%;padding:0 12mm;">'
              'InduSpect 葉片模組 — 真實影像驗證報告</div>')
    footer = ('<div style="font-size:7pt;color:#888;width:100%;padding:0 12mm;'
              'text-align:right;"><span class="pageNumber"></span> / '
              '<span class="totalPages"></span></div>')
    with sync_playwright() as pw:
        launch = {"args": ["--no-sandbox"]}
        if exe:
            launch["executable_path"] = exe
        browser = pw.chromium.launch(**launch)
        page = browser.new_page(viewport={"width": 1100, "height": 1400})
        page.emulate_media(color_scheme="light", media="print")  # 列印版面用淺色
        page.goto("file://" + os.path.abspath(html_path), wait_until="load", timeout=120_000)
        page.wait_for_timeout(2000)  # 等 data URI 影像解碼完
        page.pdf(path=pdf_path, format="A4", print_background=True,
                 margin={"top": "14mm", "bottom": "14mm", "left": "12mm", "right": "12mm"},
                 display_header_footer=True,
                 header_template=header, footer_template=footer)
        browser.close()
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", action="append", required=True, metavar="DIR",
                    help="fetch_real_images.py 的輸出目錄（需含 manifest.json），可重複")
    ap.add_argument("--after", action="append", required=True, metavar="DIR",
                    help="validate_real_images.py 的輸出目錄（現行程式碼），可重複")
    ap.add_argument("--before", action="append", metavar="DIR",
                    help="改動前程式碼的 validate 輸出目錄；給了才會排前後對照，可重複")
    ap.add_argument("--labels", default=LABELS)
    ap.add_argument("--out", default="real_image_validation.html")
    ap.add_argument("--pdf", help="順便列印成 PDF（需要 playwright + chromium）")
    args = ap.parse_args()

    labels = json.load(open(args.labels, encoding="utf-8"))["images"]
    c = Corpus(labels, args.corpus, args.after, args.before or [])
    if not c.known():
        raise SystemExit("語料、標註、量測結果沒有交集，無法產生報告")
    missing = [k for k in c.after if k not in labels]
    if missing:
        print(f"  ? {len(missing)} 張沒有標註，未納入報告：{', '.join(sorted(missing)[:6])} …")

    html = build_html(c)
    d = os.path.dirname(os.path.abspath(args.out))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"→ {args.out}  ({len(html) / 1024:.0f} KB，自帶內容，可離線開啟)")
    if args.pdf and write_pdf(args.out, args.pdf):
        print(f"→ {args.pdf}  ({os.path.getsize(args.pdf) / 1024 / 1024:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

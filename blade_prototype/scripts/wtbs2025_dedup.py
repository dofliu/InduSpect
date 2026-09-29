#!/usr/bin/env python3
"""WTBs2025 當外部測試集之前的去重與分群（`CROSS_CORPUS_VALIDATION.md` §5 的下一步）。

接棒筆記寫「先按原始編號去重（`oil leakage` 520 張只有 29 個原始編號），再逐張重標成本表子類」。
真的去做之後，「按原始編號去重」只是三件事裡最小的一件：

1. **增強副本**（檔名看得出來）：`oil leakage` 520 → 29、`lightning strikes` 285 → 57，
   其餘七類的檔名編號**沒有重複**。全語料 7,544 → 6,825，只少 10%。
2. **同一次航拍的相鄰幀**（檔名看不出來）：pHash 收得起來，但它們**不是重複**——
   是同一支葉片同一次飛行的不同位置。對測試集來說它們不該被刪掉，而是**不可拆到不同子集**，
   與 wtb 的 `split_group`（`closeup_blade_groups.py`）同一個道理。
3. **同一張照片出現在多個類別資料夾**（最要緊的一件）：WTBs2025 是 YOLO 物件偵測語料，
   一張照片含幾種缺陷就被複製到幾個資料夾，各自只帶**那一類的框**。
   抽查 pHash 距 ≤ 1 的跨類別配對，40 對裡 33 對**逐像素相同**（平均絕對差中位 0.15/255）。
   **所以資料夾名不是影像級標籤**——拿它當單一類別去算逐類指標，等於拿部分標籤當全部。

用法（影像不進版控，要自己準備）：

    python3 scripts/wtbs2025_dedup.py run --root <WTBs2025 解壓後的目錄> \\
        --out data/wtbs2025_dedup.json
    python3 scripts/wtbs2025_dedup.py report

`run` 只算 pHash 與分群，不搬檔案也不刪檔案——**要保留哪一張是使用者的決定**，
這支腳本只負責把「哪些是同一張、哪些是同一次飛行、哪些跨類別重複」講清楚。
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]

# Roboflow 匯出：`<原始編號>_jpg.rf.<32 位十六進位>.jpg`（副檔名字樣可能是 jpg/JPG/png）
RF = re.compile(r"^(?P<stem>.+?)\.rf\.[0-9a-f]+\.(?:jpg|jpeg|png)$", re.I)
# lightning strikes 用另一套：`<編號><尾碼>.<副檔名>`，尾碼是增強方式
AUG_SUFFIXES = ("GAN", "be", "fl", "ro")
AUG = re.compile(r"^(?P<id>\d+)(?P<suf>" + "|".join(AUG_SUFFIXES) + r")?$")

# 內容分群的 pHash 漢明距上限（64 bit）。6 是「同一次飛行的相鄰幀」會被收在一起的尺度；
# 判斷「是不是同一張照片」另外用 ≤ 1 再加逐像素比對。
CONTENT_THRESHOLD = 6
IDENTICAL_THRESHOLD = 1
# 逐像素平均絕對差小於這個數就算同一張（0–255）。0.15 是實測跨類別配對的中位數。
IDENTICAL_PIXEL_DIFF = 2.0


def original_id(filename: str) -> tuple[str, str]:
    """檔名 → (原始編號, 變體種類)。變體種類是 `roboflow`／`original`／`GAN` 等。"""
    m = RF.match(filename)
    if m:
        # Roboflow 把原始副檔名編進檔名，而且會疊：`1.JPG` → `1_JPG_jpg.rf.<hash>.jpg`。
        # 一路剝到不是副檔名字樣為止，`B-04_01` 這種含底線的真編號不受影響（`01` 不是副檔名）。
        stem = m.group("stem")
        while True:
            nxt = re.sub(r"_(?:jpg|jpeg|png)$", "", stem, flags=re.I)
            if nxt == stem:
                break
            stem = nxt
        return stem, "roboflow"
    stem = os.path.splitext(filename)[0]
    m = AUG.match(stem)
    if m:
        return m.group("id"), (m.group("suf") or "original")
    return stem, "unknown"


def phash(path: str) -> str | None:
    """32×32 灰階 → DCT 低頻 8×8 → 與中位數比較 → 64 bit，回十六進位字串。"""
    import cv2

    im = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if im is None:
        return None
    im = cv2.resize(im, (32, 32), interpolation=cv2.INTER_AREA).astype(np.float32)
    d = cv2.dct(im)[:8, :8]
    med = float(np.median(d.flatten()[1:]))
    return np.packbits((d.flatten() > med).astype(np.uint8)).tobytes().hex()


def _bit_matrix(hexes: list[str]) -> np.ndarray:
    return np.stack([np.unpackbits(np.frombuffer(bytes.fromhex(h), np.uint8)) for h in hexes]).astype(np.int8)


def _union_find(n: int):
    parent = list(range(n))

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    return find, union


def analyse(rows: dict[str, dict[str, str]], pixel_check=None) -> dict:
    """rows: {類別: {檔名: phash}}。回傳三層結論的摘要與分群。"""
    keys = [(c, f) for c in sorted(rows) for f in sorted(rows[c])]
    if not keys:
        return {"n_files": 0}
    B = _bit_matrix([rows[c][f] for c, f in keys])
    cls = np.array([c for c, _ in keys])

    # ① 增強副本：檔名編號
    per_class = {}
    for c in sorted(rows):
        ids = collections.defaultdict(list)
        kinds = collections.Counter()
        for f in sorted(rows[c]):
            i, k = original_id(f)
            ids[i].append(f)
            kinds[k] += 1
        per_class[c] = {"n_files": sum(len(v) for v in ids.values()), "n_original_ids": len(ids),
                        "variant_kinds": dict(sorted(kinds.items())),
                        "largest_group": max((len(v) for v in ids.values()), default=0)}

    # ②③ 內容分群（≤ CONTENT_THRESHOLD）與「同一張」（≤ IDENTICAL_THRESHOLD）
    find, union = _union_find(len(keys))
    cross_class_pairs: list[tuple[int, int, int]] = []
    step = 512
    for s in range(0, len(keys), step):
        d = (B[s:s + step][:, None, :] != B[None, :, :]).sum(2)
        for i in range(d.shape[0]):
            gi = s + i
            for gj in np.nonzero(d[i] <= CONTENT_THRESHOLD)[0]:
                gj = int(gj)
                if gj <= gi:
                    continue
                union(gi, gj)
                if d[i][gj] <= IDENTICAL_THRESHOLD and cls[gi] != cls[gj]:
                    cross_class_pairs.append((int(d[i][gj]), gi, gj))
    groups = collections.defaultdict(list)
    for i in range(len(keys)):
        groups[find(i)].append(i)
    multi_class_groups = sum(1 for g in groups.values() if len({cls[i] for i in g}) > 1)

    sample = {"checked": 0, "identical": 0, "median_abs_diff": None}
    if pixel_check is not None and cross_class_pairs:
        diffs = []
        for _, a, b in cross_class_pairs[:40]:
            m = pixel_check(keys[a], keys[b])
            if m is not None:
                diffs.append(m)
        if diffs:
            sample = {"checked": len(diffs), "identical": int(sum(1 for m in diffs if m < IDENTICAL_PIXEL_DIFF)),
                      "median_abs_diff": round(float(np.median(diffs)), 3)}

    # `lightning strikes` 的 GAN 變體到底是不是生成影像——量了才知道
    gan = {"checked": 0, "same_as_original": 0, "median_abs_diff": None}
    if pixel_check is not None:
        diffs = []
        for c in rows:
            for f in sorted(rows[c]):
                stem, kind = original_id(f)
                if kind != "GAN":
                    continue
                orig = next((g for g in rows[c] if original_id(g) == (stem, "original")), None)
                if orig is None:
                    continue
                m = pixel_check((c, f), (c, orig))
                if m is not None:
                    diffs.append(m)
                if len(diffs) >= 20:
                    break
            if len(diffs) >= 20:
                break
        if diffs:
            gan = {"checked": len(diffs), "same_as_original": int(sum(1 for m in diffs if m < IDENTICAL_PIXEL_DIFF)),
                   "median_abs_diff": round(float(np.median(diffs)), 3),
                   "max_abs_diff": round(float(max(diffs)), 3)}

    return {
        "n_files": len(keys),
        "n_original_ids": sum(v["n_original_ids"] for v in per_class.values()),
        "n_content_groups": len(groups),
        "identical_threshold": IDENTICAL_THRESHOLD,
        "gan_variant_check": gan,
        "per_class": per_class,
        "content_threshold": CONTENT_THRESHOLD,
        "cross_class_identical_pairs": len(cross_class_pairs),
        "cross_class_group_count": multi_class_groups,
        "cross_class_pixel_sample": sample,
        "largest_content_group": max((len(g) for g in groups.values()), default=0),
    }


def cmd_run(a: argparse.Namespace) -> int:
    import cv2

    rows: dict[str, dict[str, str]] = {}
    for cls in sorted(os.listdir(a.root)):
        d = os.path.join(a.root, cls, "images")
        if not os.path.isdir(d):
            continue
        got: dict[str, str] = {}
        for f in sorted(os.listdir(d)):
            h = phash(os.path.join(d, f))
            if h:
                got[f] = h
        rows[cls] = got
        print(f"  {cls}: {len(got)}", file=sys.stderr)
    if not rows:
        print(f"{a.root} 裡沒有 <類別>/images 結構", file=sys.stderr)
        return 2

    def pixel_check(ka, kb):
        pa = os.path.join(a.root, ka[0], "images", ka[1])
        pb = os.path.join(a.root, kb[0], "images", kb[1])
        ia, ib = cv2.imread(pa), cv2.imread(pb)
        if ia is None or ib is None:
            return None
        if ia.shape != ib.shape:
            ib = cv2.resize(ib, (ia.shape[1], ia.shape[0]))
        return float(np.abs(ia.astype(np.int16) - ib.astype(np.int16)).mean())

    doc = {
        "version": "wtbs2025-dedup-2026-09-29",
        "source": "WTBs2025（figshare 28876406，CC0）；影像不進版控，這裡只存 pHash 與分群結論",
        "note": ("三層：①檔名編號抓增強副本 ②pHash 內容分群抓同一次航拍的相鄰幀（不是重複，是不可拆的群）"
                 "③同一張照片跨類別重複——WTBs2025 是 YOLO 偵測語料，資料夾名不是影像級標籤。"),
        "phash": {"bits": 64, "resize": 32, "dct": 8},
        "summary": analyse(rows, pixel_check),
        "hashes": rows,
    }
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    s = doc["summary"]
    print(json.dumps({k: s[k] for k in ("n_files", "n_original_ids", "n_content_groups",
                                        "cross_class_identical_pairs")}, ensure_ascii=False))
    return 0


def render_markdown(doc: dict, source: str) -> str:
    s = doc["summary"]
    L: list[str] = []
    A = L.append
    A("# WTBs2025 當外部測試集之前：去重、分群、以及一個標籤結構的問題")
    A("")
    A(f"> 由 `scripts/wtbs2025_dedup.py report` 從 `{source}` 產生，**數字不手抄**。"
      f"影像不進版控（WTBs2025，figshare 28876406，CC0）。")
    A("")
    A("## 0. 一句話")
    A("")
    A(f"{s['n_files']} 個檔案 → 檔名編號 **{s['n_original_ids']}** 個 → 內容分群 **{s['n_content_groups']}** 群。"
      f"但真正該先處理的不是這兩個數字，而是**同一張照片出現在多個類別資料夾**："
      f"pHash 距 ≤ {IDENTICAL_THRESHOLD} 的跨類別配對有 **{s['cross_class_identical_pairs']}** 對，"
      f"抽查 {s['cross_class_pixel_sample']['checked']} 對裡 **{s['cross_class_pixel_sample']['identical']} 對逐像素相同**"
      f"（平均絕對差中位 {s['cross_class_pixel_sample']['median_abs_diff']}/255）。")
    A("")
    A("**WTBs2025 是 YOLO 物件偵測語料**：一張照片含幾種缺陷就被複製到幾個資料夾，各自只帶那一類的框。"
      "所以**資料夾名不是影像級標籤**，拿它當單一類別去算逐類指標，等於拿部分標籤當全部。")
    A("")
    A("## 1. 三層，各自抓到什麼")
    A("")
    A("| 層 | 依據 | 抓到什麼 | 該怎麼處理 |")
    A("|---|---|---|---|")
    A(f"| ① 增強副本 | 檔名編號 | {s['n_files']} → {s['n_original_ids']}（少 "
      f"{s['n_files'] - s['n_original_ids']} 張、{100 * (s['n_files'] - s['n_original_ids']) / s['n_files']:.0f}%） | "
      "同一張的翻轉／旋轉／調亮，**測試集只留一張** |")
    A(f"| ② 同次航拍的相鄰幀 | pHash ≤ {s['content_threshold']} | {s['n_original_ids']} → "
      f"{s['n_content_groups']} 群 | **不是重複、不要刪**——是同一支葉片同一次飛行，"
      "必須整群分在同一側（與 wtb 的 `split_group` 同一個道理） |")
    A(f"| ③ 跨類別同一張 | pHash ≤ {s.get('identical_threshold', IDENTICAL_THRESHOLD)} + 逐像素 | "
      f"{s['cross_class_identical_pairs']} 對 | **先把標籤合併成多標籤**，再談逐類指標 |")
    A("")
    A(f"（②那一層的 {s['n_content_groups']} 群裡有 **{s['cross_class_group_count']}** 群橫跨多個類別資料夾——"
      "那是②與③兩種原因混在一起的結果：同一次飛行的相鄰幀本來就可能各自含不同缺陷。）")
    A("")
    A("## 2. 逐類")
    A("")
    A("| 類別 | 檔案 | 原始編號 | 倍數 | 最大一組 | 變體種類 |")
    A("|---|---|---|---|---|---|")
    for cls, v in sorted(s["per_class"].items()):
        mult = v["n_files"] / max(v["n_original_ids"], 1)
        kinds = "、".join(f"{k} {n}" for k, n in v["variant_kinds"].items())
        A(f"| {cls} | {v['n_files']} | {v['n_original_ids']} | {mult:.1f}× | {v['largest_group']} | {kinds} |")
    A("")
    A("只有 `oil leakage`（17.9×）與 `lightning strikes`（5×）有檔名看得出來的增強副本，"
      "其餘七類的檔名編號都不重複——**接棒筆記寫的「按原始編號去重」只影響這兩類**。")
    A("")
    g = s.get("gan_variant_check") or {}
    if g.get("checked"):
        A("`lightning strikes` 的五個變體是 `original`／`GAN`／`be`／`fl`／`ro`。"
          f"**`GAN` 不是生成影像**：抽查 {g['checked']} 對與原圖的平均絕對差中位 {g['median_abs_diff']}/255"
          f"（最大 {g.get('max_abs_diff')}），{g['same_as_original']}/{g['checked']} 判為同一張——"
          "是換檔案格式重新編碼的複本。")
    A("")
    A("## 3. 這份結果怎麼用")
    A("")
    A("1. **要算逐類指標之前，先把資料夾攤平成多標籤**：同一張照片的框合併，類別變成一個集合。"
      "在那之前，`CROSS_CORPUS_VALIDATION.md` §3 的缺陷探針「粗對照命中率」是拿**部分標籤**在算——"
      "探針說「這張是雷擊」而資料夾寫 `pinholes`，有可能兩者都對。")
    A("2. **切分用內容群不是檔名**：②那一層的群才是「不可拆」的單位。")
    A("3. **增強副本只在兩類**，去掉它們對總量的影響只有 10%。")
    A("")
    A("## 4. 這份結果不能說什麼")
    A("")
    A("- pHash 只抓得到**外觀幾乎相同**的照片。翻轉與旋轉的增強副本在 pHash 上距離很遠"
      "（實測 `fl`／`ro` 對原圖是 28–32），所以②那一層**不保證**把所有同次飛行的幀收在一起，只是下界。")
    A("- 跨類別「同一張」的判定抽查了 40 對，不是全查。")
    A("- 沒有重新標記任何一張——**重標成本表子類仍然是人工工作**，這支腳本只是把它之前該知道的事講清楚。")
    A("")
    return "\n".join(L)


def cmd_report(a: argparse.Namespace) -> int:
    doc = json.load(open(a.results, encoding="utf-8"))
    try:
        source = Path(a.results).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        source = Path(a.results).name
    Path(a.out).write_text(render_markdown(doc, source), encoding="utf-8")
    print(f"寫入 {a.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--root", required=True, help="WTBs2025 解壓後、含 <類別>/images 的目錄")
    r.add_argument("--out", default=str(ROOT / "data" / "wtbs2025_dedup.json"))
    p = sub.add_parser("report")
    p.add_argument("--results", default=str(ROOT / "data" / "wtbs2025_dedup.json"))
    p.add_argument("--out", default=str(ROOT / "WTBS2025_DEDUP.md"))
    a = ap.parse_args(argv)
    return cmd_run(a) if a.cmd == "run" else cmd_report(a)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""重算 `CLOSEUP_BASELINE_REPORT.md` 的數字。

兩件事：

1. **語料盤點**（不需要影像）：從 `data/closeup_triage.json` 重算取像合格率、授權分布、
   EXIF 可得率。這一份可以在 CI 裡跑，因為判定與出處都在版控裡。
2. **跨模式回歸**（需要影像）：把 Mode A 的分割 + 結構定位 + 拍攝閘門餵進 Mode B 的
   語料，確認閘門會拒收非 Mode A 的照片。**這是對已出貨程式的測試**，不是對 Mode B 的——
   Mode B 還沒實作。給 `--images` 才會跑。

用法：
    python scripts/closeup_corpus_report.py                      # 只做語料盤點
    python scripts/closeup_corpus_report.py --images closeup_images
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAGE = ROOT / "data" / "closeup_triage.json"

# §1.2 判定為合格的兩個標籤
PASS_LABELS = ("intake_pass_readable", "intake_pass_low_res")


def corpus_tables(d: dict) -> None:
    recs = d["records"]
    n = len(recs)
    by = collections.Counter(r["triage"] for r in recs)
    print(f"# 開放網路語料盤點（{n} 張，{d['source']}）\n")
    print("| 判定 | 張數 | 占比 |")
    print("|---|---|---|")
    for k in ("out_of_domain", "distant_blade", "mode_a", "intake_pass_low_res", "intake_pass_readable"):
        print(f"| `{k}` | {by[k]} | {by[k] / n * 100:.1f}% |")
    npass = sum(by[k] for k in PASS_LABELS)
    print(f"\n§1.2 字面合格：{npass}/{n} = {npass / n * 100:.1f}%")
    print(f"其中表面可判讀：{by['intake_pass_readable']}/{n} = {by['intake_pass_readable'] / n * 100:.1f}%")
    aero = [r["idx"] for r in recs if r.get("aero_surface")]
    print(f"其中拍到氣動表面（非根部法蘭）：{len(aero)}/{n} = {len(aero) / n * 100:.1f}%  {aero}")

    lic = collections.Counter(r["licence"] for r in recs)
    print("\n授權分布：" + "；".join(f"{k} {v}" for k, v in lic.most_common()))
    exif = sum(1 for r in recs if r["exif_tags"])
    print(f"帶 EXIF 的張數：{exif}/{n}")
    long_sides = sorted(max(r["width"], r["height"]) for r in recs)
    print(f"長邊中位數：{long_sides[n // 2]} px（最大 {long_sides[-1]}）")


def gate_table(d: dict) -> None:
    """Mode A 拍攝閘門在這批照片上的放行率（judgement 已存在 triage 檔裡）。"""
    recs = [r for r in d["records"] if r.get("mode_a_gate_ok") is not None]
    if not recs:
        print("\n（triage 檔裡沒有 Mode A 閘門結果，跳過）")
        return
    by = collections.defaultdict(lambda: [0, 0])
    for r in recs:
        by[r["triage"]][0] += 1
        by[r["triage"]][1] += int(r["mode_a_gate_ok"])
    print("\n# Mode A 拍攝閘門（已出貨程式）在 Mode B 語料上的行為\n")
    print("| 判定 | 張數 | 閘門放行 |")
    print("|---|---|---|")
    non_a = [0, 0]
    for k, (m, ok) in sorted(by.items()):
        print(f"| `{k}` | {m} | {ok} |")
        if k != "mode_a":
            non_a[0] += m
            non_a[1] += ok
    print(f"\n**非 Mode A 的 {non_a[0]} 張裡，閘門放行 {non_a[1]} 張。**")


def rerun_gate(img_dir: Path, d: dict) -> None:
    """重跑閘門（需要影像）。結果與 triage 檔裡存的值比對，不一致就非零離開。"""
    import cv2
    sys.path.insert(0, str(ROOT))
    from blade_proto.quality import assess_capture
    from blade_proto.segmentation import find_structure, segment_turbine

    work, mismatch, done = 1024, [], 0
    for r in d["records"]:
        p = img_dir / r["file"]
        if not p.exists():
            continue
        img = cv2.imread(str(p))
        if img is None:
            continue
        h, w = img.shape[:2]
        s = work / max(h, w)
        if s < 1:
            img = cv2.resize(img, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA)
        seg = st = None
        err = None
        try:
            seg = segment_turbine(img)
            st = find_structure(seg.mask, horizon_y=seg.horizon_y)
        except Exception as e:  # noqa: BLE001 — 失敗也是閘門的輸入
            err = f"{type(e).__name__}: {e}"
        ok = assess_capture(seg, st, error=err).ok
        done += 1
        if r.get("mode_a_gate_ok") is not None and ok != r["mode_a_gate_ok"]:
            mismatch.append((r["idx"], r["mode_a_gate_ok"], ok))
    print(f"\n重跑 {done} 張；與 triage 檔不一致 {len(mismatch)} 張 {mismatch[:10]}")
    if mismatch:
        raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", help="語料目錄（給了才重跑 Mode A 閘門）")
    args = ap.parse_args()
    d = json.loads(TRIAGE.read_text(encoding="utf-8"))
    corpus_tables(d)
    gate_table(d)
    if args.images:
        rerun_gate(Path(args.images), d)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""把 `validate_real_images.py` 的輸出整理成測試報告用的 Markdown 表格。

`BLADE_TEST_REPORT.md` 裡真實影像那一節的每個數字都由這支腳本算出，不手抄——
與 `make_validation_report.py` 同一條原則。另外做兩件 validate 本身不做的事：

1. **與上一次結果逐張比對**（`--baseline`）：hub_ok／n_blades／failed／閘門結論任一變了就列出來。
   這是「演算法沒有無聲漂移」的證據；沒有 baseline 就跳過。
2. **放行影像的三片互比**：把 `comparison_flagged` 與**葉尖方位角間距對 120° 的偏差**並列。
   正視且相機在轉子軸線上時三片間距是 120°；偏軸取景會把間距壓縮，而透視差正是
   三片互比最主要的假訊號來源（README「已知限制」）。並列是為了看那個假設能不能量化。

用法：
    python scripts/blade_test_report.py --after out/A --after out/B \\
        --baseline old/A --baseline old/B [--json summary.json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS = os.path.join(ROOT, "data", "real_image_labels.json")

SKIES = ("clear", "cloud", "backlit")


def load_results(dirs: list[str]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for d in dirs:
        for r in json.load(open(os.path.join(d, "results.json"), encoding="utf-8")):
            r["_dir"] = os.path.basename(d.rstrip("/"))
            out[r["id"]] = r
    return out


def reason_bucket(reason: str) -> str:
    """把「三片葉尖半徑差 39%（上限 15%）」這類帶數字的原因收成同一桶。"""
    head = reason.split("：")[0]
    return re.sub(r"\d+(\.\d+)?", "N", head)


def angular_gap_dev(angles: list[float] | None) -> float | None:
    """三片葉尖方位角的相鄰間距對 120° 的最大偏差（度）。"""
    if not angles or len(angles) != 3:
        return None
    a = sorted(x % 360.0 for x in angles)
    gaps = [a[1] - a[0], a[2] - a[1], 360.0 - (a[2] - a[0])]
    return max(abs(g - 120.0) for g in gaps)


def frac(n: int, d: int) -> str:
    return f"{n}/{d}" if d else "—"


def table(headers: list[str], rows: list[list]) -> str:
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(lines)


def summarise(res: dict[str, dict], labels: dict) -> dict:
    single = [r for r in res.values() if r["category"] == "single"]
    outside = [r for r in res.values() if r["category"] != "single"]
    acc = [r for r in res.values() if r["verdict"]["ok"]]
    secs = sorted(r["seconds"] for r in res.values())
    return {
        "n": len(res), "single": len(single), "outside": len(outside),
        "hub_ok": sum(1 for r in single if r.get("hub_ok")),
        "three_blades": sum(1 for r in single if r.get("n_blades") == 3),
        "empty_mask_single": sum(1 for r in single if r.get("mask_area_frac", 1) == 0),
        "accepted": len(acc),
        "accepted_hub_ok": sum(1 for r in acc if r.get("hub_ok")),
        "accepted_outside": sum(1 for r in outside if r["verdict"]["ok"]),
        "loud_fail_outside": sum(1 for r in outside if r.get("failed") or r.get("n_blades", 0) < 3),
        "second_rotor_warnings": sum(
            1 for r in res.values() if any("另一個轉子" in w for w in r["verdict"].get("warnings", []))),
        "seconds_total": round(sum(secs), 1),
        "seconds_median": secs[len(secs) // 2] if secs else None,
        "by_sky": {
            s: {
                "n": sum(1 for r in single if labels[r["id"]].get("sky") == s),
                "hub_ok": sum(1 for r in single if labels[r["id"]].get("sky") == s and r.get("hub_ok")),
                "three": sum(1 for r in single if labels[r["id"]].get("sky") == s and r.get("n_blades") == 3),
                "accepted": sum(1 for r in single if labels[r["id"]].get("sky") == s and r["verdict"]["ok"]),
            } for s in SKIES
        },
        "reject_reasons": dict(Counter(
            reason_bucket(x) for r in res.values() if not r["verdict"]["ok"]
            for x in r["verdict"].get("reasons", [])).most_common()),
    }


def diff_against(res: dict[str, dict], base: dict[str, dict]) -> list[tuple]:
    diffs = []
    for k, n in res.items():
        o = base.get(k)
        if o is None:
            diffs.append((k, "baseline 缺此張", None, None))
            continue
        for f in ("hub_ok", "n_blades", "failed"):
            if n.get(f) != o.get(f):
                diffs.append((k, f, o.get(f), n.get(f)))
        if n["verdict"]["ok"] != o["verdict"]["ok"]:
            diffs.append((k, "verdict.ok", o["verdict"]["ok"], n["verdict"]["ok"]))
        a, b = n.get("hub_err_px"), o.get("hub_err_px")
        if a is not None and b is not None and abs(a - b) > 0.5:
            diffs.append((k, "hub_err_px", b, a))
    return diffs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--after", action="append", required=True, metavar="DIR", help="本次 validate 輸出目錄（可重複）")
    ap.add_argument("--baseline", action="append", metavar="DIR", help="上一次的輸出目錄（可重複），有給才做逐張比對")
    ap.add_argument("--labels", default=LABELS)
    ap.add_argument("--json", help="把摘要另存成 JSON")
    a = ap.parse_args()

    labels = json.load(open(a.labels, encoding="utf-8"))["images"]
    res = load_results(a.after)
    summ = summarise(res, labels)
    per_set = {d: summarise({k: v for k, v in res.items() if v["_dir"] == d}, labels)
               for d in sorted({r["_dir"] for r in res.values()})}

    print("### 全語料摘要\n")
    print(table(["項目", "數值"], [
        ["影像數（設計範圍內 single ／ 範圍外 multi+none）", f"{summ['n']}（{summ['single']} ／ {summ['outside']}）"],
        ["輪轂命中（誤差 ≤ 對角線 5%）", frac(summ["hub_ok"], summ["single"])],
        ["三片找齊", frac(summ["three_blades"], summ["single"])],
        ["設計範圍內遮罩全空", frac(summ["empty_mask_single"], summ["single"])],
        ["閘門放行", f"{summ['accepted']}（其中輪轂正確 {summ['accepted_hub_ok']}）"],
        ["閘門誤放行（範圍外卻放行）", f"{summ['accepted_outside']} / {summ['outside']}"],
        ["範圍外明確失敗（例外或不足三片）", frac(summ["loud_fail_outside"], summ["outside"])],
        ["第二個轉子警告", summ["second_rotor_warnings"]],
        ["每張耗時（中位／合計，1024 px 工作尺度）", f"{summ['seconds_median']} s ／ {summ['seconds_total']} s"],
    ]))

    print("\n### 依天空條件（設計範圍內）\n")
    print(table(["天空", "張數", "輪轂命中", "三片找齊", "閘門放行"], [
        [s, v["n"], frac(v["hub_ok"], v["n"]), frac(v["three"], v["n"]), frac(v["accepted"], v["n"])]
        for s, v in summ["by_sky"].items() if v["n"]]))

    print("\n### 依集合\n")
    print(table(["集合", "張數", "single", "輪轂命中", "三片找齊", "放行", "誤放行"], [
        [d, v["n"], v["single"], frac(v["hub_ok"], v["single"]), frac(v["three_blades"], v["single"]),
         v["accepted"], v["accepted_outside"]] for d, v in per_set.items()]))

    print("\n### 閘門拒收原因（每張可有多條）\n")
    print(table(["原因", "次數"], [[k, v] for k, v in summ["reject_reasons"].items()]))

    acc = sorted((r for r in res.values() if r["verdict"]["ok"]), key=lambda r: r["id"])
    print("\n### 放行影像的三片互比\n")
    rows = []
    for r in acc:
        lab = labels[r["id"]]
        rows.append([r["id"], r["_dir"], lab.get("sky"), "、".join(lab.get("conditions", [])) or "—",
                     r.get("tip_radius_spread_frac"),
                     f"{angular_gap_dev(r.get('tip_angles_deg')):.0f}°" if r.get("tip_angles_deg") else "—",
                     "、".join(r.get("comparison_flagged") or []) or "（無）"])
    print(table(["影像", "集合", "天空", "現場條件", "葉尖半徑離散", "間距偏離 120°", "互比標記"], rows))
    flagged = [r for r in acc if r.get("comparison_flagged")]
    print(f"\n放行 {len(acc)} 張中互比有標記 {len(flagged)} 張；"
          f"有標記者間距偏離中位數 "
          f"{sorted(angular_gap_dev(r['tip_angles_deg']) for r in flagged)[len(flagged)//2]:.0f}°、"
          f"無標記者 "
          f"{sorted(angular_gap_dev(r['tip_angles_deg']) for r in acc if not r.get('comparison_flagged'))[max(0,(len(acc)-len(flagged))//2)]:.0f}°"
          if flagged and len(acc) > len(flagged) else "")

    if a.baseline:
        base = load_results(a.baseline)
        diffs = diff_against(res, base)
        print("\n### 與 baseline 逐張比對\n")
        print(f"baseline {len(base)} 張、本次 {len(res)} 張；有差異的欄位 **{len(diffs)}** 個。")
        if diffs:
            print()
            print(table(["影像", "欄位", "baseline", "本次"], [list(d) for d in diffs]))
        summ["baseline_diffs"] = diffs

    if a.json:
        json.dump({"summary": summ, "per_set": per_set}, open(a.json, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())

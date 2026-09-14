#!/usr/bin/env python3
"""在真實照片上跑分割 + 結構定位，量測成功率與失敗模式。

驗的兩件事：
1. **設計範圍內**（`category=single`：單台主風機、整個轉子在框內）→ 輪轂要定位正確、
   三片葉片要找齊。輪轂誤差以人工標註為準，門檻為畫面對角線的 5%。
2. **設計範圍外**（`multi` / `none`）→ 重點不是定位正確，而是**要明確失敗**。
   安靜地回傳一組看起來合理的三葉結構，比丟例外危險得多——現場操作者遲早會拍到
   這種照片，而報告不會告訴他那是錯的。

用法：
    python scripts/fetch_real_images.py --out real_images
    python scripts/validate_real_images.py --dir real_images --out real_images/_out
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import traceback

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from blade_proto.geometry import compare_blades, profiles_from_structure  # noqa: E402
from blade_proto.quality import assess_capture  # noqa: E402
from blade_proto.segmentation import find_structure, segment_turbine  # noqa: E402

LABELS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "data", "real_image_labels.json")

HUB_TOL_DIAG = 0.05  # 輪轂誤差門檻：畫面對角線的 5%


def _draw_overlay(img: np.ndarray, mask: np.ndarray, st, gt_hub=None) -> np.ndarray:
    """遮罩用洋紅疊色、輪轂用綠十字、人工標註用黃圈、葉尖用青點。"""
    out = img.copy()
    tint = out.copy()
    tint[mask > 0] = (255, 0, 255)
    out = cv2.addWeighted(out, 0.62, tint, 0.38, 0)
    h, w = out.shape[:2]
    if st is not None:
        hx, hy = int(round(st.hub[0])), int(round(st.hub[1]))
        cv2.circle(out, (hx, hy), max(6, int(st.hub_radius_px)), (0, 255, 0), 2)
        cv2.drawMarker(out, (hx, hy), (0, 255, 0), cv2.MARKER_CROSS, 26, 2)
        for i, b in enumerate(st.blades):
            tx, ty = int(round(b.tip_xy[0])), int(round(b.tip_xy[1]))
            cv2.line(out, (hx, hy), (tx, ty), (255, 255, 0), 1)
            cv2.circle(out, (tx, ty), 7, (255, 255, 0), 2)
            cv2.putText(out, "ABC"[i % 3], (tx + 9, ty - 6), cv2.FONT_HERSHEY_SIMPLEX,
                        0.7, (255, 255, 0), 2)
    if gt_hub is not None:
        gx, gy = int(round(gt_hub[0] * w)), int(round(gt_hub[1] * h))
        cv2.circle(out, (gx, gy), 16, (0, 220, 255), 2)
    return out


def analyse(path: str, gt_hub, max_side: int) -> dict:
    img = cv2.imread(path)
    if img is None:
        return {"error": "讀檔失敗"}
    h, w = img.shape[:2]
    if max(h, w) > max_side:  # 統一縮到相近尺度，讓不同來源的解析度不影響比較
        s = max_side / max(h, w)
        img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
        h, w = img.shape[:2]
    diag = math.hypot(w, h)
    rec: dict = {"size": [w, h]}
    t0 = time.time()
    try:
        seg = segment_turbine(img)
        rec["mask_area_frac"] = float((seg.mask > 0).mean())
        rec["horizon_y"] = seg.horizon_y
        st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    except Exception as exc:  # noqa: BLE001 — 這裡就是要記錄「演算法有沒有明確失敗」
        rec["failed"] = True
        rec["error"] = f"{type(exc).__name__}: {exc}"
        rec["verdict"] = assess_capture(locals().get("seg"), None, exc).to_dict()
        rec["trace"] = traceback.format_exc(limit=2).splitlines()[-1]
        rec["seconds"] = round(time.time() - t0, 2)
        return rec | {"_img": img, "_mask": locals().get("seg").mask if "seg" in locals() else None,
                      "_st": None}
    rec["seconds"] = round(time.time() - t0, 2)
    rec["failed"] = False
    rec["verdict"] = assess_capture(seg, st).to_dict()
    rec["n_blades"] = len(st.blades)
    rec["hub"] = [round(st.hub[0], 1), round(st.hub[1], 1)]
    rec["hub_norm"] = [round(st.hub[0] / w, 3), round(st.hub[1] / h, 3)]
    rec["hub_radius_px"] = round(st.hub_radius_px, 1)
    rec["hub_refined"] = st.hub_refined
    rec["tower_found"] = st.tower_found
    rec["tower_roll_deg"] = round(st.tower_angle_deg, 2)
    rec["notes"] = list(st.notes)
    rec["tip_radii_px"] = [round(b.tip_radius_px, 1) for b in st.blades]
    rec["tip_angles_deg"] = [round(b.tip_angle_deg, 1) for b in st.blades]
    if gt_hub is not None:
        err = math.hypot(st.hub[0] - gt_hub[0] * w, st.hub[1] - gt_hub[1] * h)
        rec["hub_err_px"] = round(err, 1)
        rec["hub_err_diag"] = round(err / diag, 4)
        rec["hub_ok"] = bool(err / diag <= HUB_TOL_DIAG)
    # 幾何互比只有三片都在時才有意義；記錄它「敢不敢下結論」
    if rec["verdict"]["metrics"].get("view") == "side":
        rec["side_view"] = True
        rec["comparison_flagged"] = []  # 側視不做三片互比（quality.detect_side_view）
    elif len(st.blades) >= 2:
        try:
            profs = profiles_from_structure(st)
            cmp_ = compare_blades(profs, noise_floor_px=1.5)
            rec["comparison_flagged"] = sorted(
                {c["metric"] for c in cmp_.get("comparisons", []) if c.get("flagged")})
            rec["tip_radius_spread_frac"] = (
                round(float(np.ptp(rec["tip_radii_px"]) / max(np.median(rec["tip_radii_px"]), 1e-6)), 3))
        except Exception as exc:  # noqa: BLE001
            rec["comparison_error"] = f"{type(exc).__name__}: {exc}"
    return rec | {"_img": img, "_mask": seg.mask, "_st": st}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="real_images", help="fetch_real_images.py 的輸出目錄")
    ap.add_argument("--out", default=None, help="疊圖與結果輸出目錄（預設 <dir>/_out）")
    ap.add_argument("--max-side", type=int, default=1024, help="統一縮放長邊")
    ap.add_argument("--labels", default=LABELS)
    args = ap.parse_args()

    out_dir = args.out or os.path.join(args.dir, "_out")
    os.makedirs(out_dir, exist_ok=True)
    labels = json.load(open(args.labels, encoding="utf-8"))["images"]
    manifest = json.load(open(os.path.join(args.dir, "manifest.json"), encoding="utf-8"))

    results = []
    for m in manifest:
        key = m["id"][:8]
        lab = labels.get(key)
        if lab is None:
            print(f"  ? 沒有標註，略過 {key}")
            continue
        gt = lab.get("hub")
        rec = analyse(os.path.join(args.dir, m["file"]), gt, args.max_side)
        img, mask, st = rec.pop("_img", None), rec.pop("_mask", None), rec.pop("_st", None)
        if img is not None and mask is not None:
            cv2.imwrite(os.path.join(out_dir, f"{key}_overlay.jpg"),
                        _draw_overlay(img, mask, st, gt), [cv2.IMWRITE_JPEG_QUALITY, 88])
        rec |= {"id": key, "category": lab["category"], "conditions": lab.get("conditions", []),
                "title": m.get("title", ""), "license": m.get("license", ""),
                "creator": m.get("creator", ""), "landing": m.get("landing", "")}
        results.append(rec)
        flag = "FAIL" if rec.get("failed") else ("ok" if rec.get("hub_ok", True) else "MISS")
        print(f"  {key} [{lab['category']:6}] {flag:4} blades={rec.get('n_blades','-')} "
              f"hub_err={rec.get('hub_err_diag','-')} {rec.get('error','')}")

    with open(os.path.join(out_dir, "results.json"), "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)

    single = [r for r in results if r["category"] == "single"]
    hub_ok = [r for r in single if r.get("hub_ok")]
    three = [r for r in single if r.get("n_blades") == 3]
    outside = [r for r in results if r["category"] != "single"]
    loud = [r for r in outside if r.get("failed") or r.get("n_blades", 0) < 3]
    print("\n--- 摘要 ---")
    print(f"設計範圍內 single: {len(single)} 張；輪轂命中 {len(hub_ok)}；找齊三片 {len(three)}")
    print(f"設計範圍外 multi/none: {len(outside)} 張；明確失敗（例外或不足三片）{len(loud)}"
          f"；安靜給出三葉結構 {len(outside) - len(loud)}")
    print(f"→ {out_dir}/results.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

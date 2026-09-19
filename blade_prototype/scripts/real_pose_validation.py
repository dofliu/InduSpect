#!/usr/bin/env python3
"""Commons 真實整機照上的姿態估計與透視補償——SPEC §13-11 第一次在**真實照片**上驗。

`OFFAXIS_SENSITIVITY.md` 的補償只在合成影像上驗過；既有 75 張真實照片全是 Flickr `_b` 尺寸，
EXIF 被剝掉、也不知道機型，姿態估計沒有輸入。`fetch_commons_turbines.py` 抓的是**帶 35 mm 等效焦距、
且分類在機型分類頁下**的 Commons 照片，所以這裡第一次同時有：焦距（→ 距離 → 仰角）、型錄轉子直徑
（→ cm/px）、輪轂高度（多半是該機型的典型值，不是那一台的）。

每張做的事與 App 端 `runGeometryPipeline` 同一條：縮到 1024 → 分割 → 結構定位 → 拍攝閘門 →
（正視放行）三片互比（原始）→ `estimate_pose`（焦距法）→ `compensate_comparison`。
另外做兩件 App 不做、但驗證要的事：

1. **輪轂高度 ±20% 靈敏度**：154/158 張的輪轂高度是機型典型值。把它乘 0.8／1.2 再跑一次姿態與補償，
   看補償結論會不會翻——翻得多，就表示「典型值」這個輸入不夠好，得要使用者填。
2. **沒有真值的判讀原則**：這些是營運中、被路人拍下的風機，先驗上沒有一台葉尖偏了兩公尺。所以
   原始互比的標記幾乎都是假警報，「補償後還剩幾個標記」就是補償在真實照片上的成績；補償**新**冒出
   的標記則是它的代價。這不是缺陷偵測的召回率——這裡量不到那個。

用法：
    python scripts/real_pose_validation.py run --manifest data/commons_turbines_manifest.json \\
        --dir <scratch>/commons_turbines --out data/commons_pose_results.json [--overlays <scratch>/overlays]
    python scripts/real_pose_validation.py report --results data/commons_pose_results.json --out REAL_POSE_VALIDATION.md
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from blade_proto import pose as P  # noqa: E402
from blade_proto.geometry import compare_blades, profiles_from_structure, side_view_summary  # noqa: E402
from blade_proto.quality import assess_capture  # noqa: E402
from blade_proto.segmentation import find_structure, segment_turbine  # noqa: E402

VERSION = "commons-pose-2026-09-19"
MAX_SIDE = 1024
NOISE_FLOOR_PX = 1.5
HUB_SENSITIVITY = (0.8, 1.2)
DEFL = "tip_deflection_px"
RAD = "radius_px"


# ---------------------------------------------------------------- 逐張分析


def _resize_to(img: np.ndarray, max_side: int) -> np.ndarray:
    import cv2

    h, w = img.shape[:2]
    if max(h, w) <= max_side:
        return img
    s = max_side / max(h, w)
    return cv2.resize(img, (int(round(w * s)), int(round(h * s))), interpolation=cv2.INTER_AREA)


def _cmp_rows(cmp_doc: dict, cm_per_px: float | None) -> list[dict]:
    rows = []
    for c in cmp_doc.get("comparisons", []):
        dev = c.get("outlier_deviation")
        rows.append({
            "metric": c["metric"],
            "flagged": bool(c["flagged"]),
            "outlier_index": int(c["outlier_index"]),
            "outlier_deviation": None if dev is None else round(float(dev), 2),
            "outlier_deviation_cm": (None if dev is None or not cm_per_px else round(float(dev) * cm_per_px, 1)),
            "z": round(float(c["z"]), 2),
            "values": [round(float(v), 2) for v in c.get("values", [])],
        })
    return rows


def _flagged(rows: list[dict]) -> list[str]:
    return sorted(r["metric"] for r in rows if r["flagged"])


def _pose_and_comp(st, profiles, *, hub_height_m, rotor_radius_m, long_side_px, focal_35mm) -> tuple[dict, dict | None]:
    pose = P.estimate_pose(st, hub_height_m=hub_height_m, rotor_radius_m=rotor_radius_m,
                           image_long_side_px=long_side_px, focal_35mm=focal_35mm)
    pose_d = pose.to_dict()
    pose_d["usable"] = bool(pose.usable)
    comp = P.compensate_comparison(profiles, pose, rotor_radius_m, noise_floor_px=NOISE_FLOOR_PX)
    if comp is None:
        return pose_d, None
    rows = _cmp_rows(comp, comp.get("cm_per_px"))
    out = {
        "prebend_fit_m": round(float(comp["prebend_fit_m"]), 2),
        "prebend_fit_ok": bool(comp["prebend_fit_ok"]),
        "deflection_compensated": bool(comp["deflection_compensated"]),
        "radius_compensated": bool(comp["radius_compensated"]),
        "tip_deflection_raw_px": [round(float(v), 2) for v in comp["tip_deflection_raw_px"]],
        "tip_deflection_compensated_px": [round(float(v), 2) for v in comp["tip_deflection_compensated_px"]],
        "radius_raw_px": [round(float(v), 1) for v in comp["radius_raw_px"]],
        "radius_compensated_px": [round(float(v), 1) for v in comp["radius_compensated_px"]],
        "blades_near_tower": list(comp.get("blades_near_tower", [])),
        "comparisons": rows,
        "flagged": _flagged(rows),
        "cm_per_px": round(float(comp["cm_per_px"]), 3) if comp.get("cm_per_px") else None,
    }
    if comp.get("note"):
        out["note"] = comp["note"]
    return pose_d, out


def analyse_image(img_bgr: np.ndarray, *, focal_35mm: float | None, hub_height_m: float | None,
                  rotor_radius_m: float | None, max_side: int = MAX_SIDE,
                  hub_sensitivity: tuple[float, ...] = HUB_SENSITIVITY) -> dict:
    """一張照片從分割到補償的完整紀錄。任何一步丟例外都收成 `failed`，不往外丟。

    回傳的 dict 可直接 JSON 化；`_internals` 只給疊圖用（呼叫端要自己 pop 掉）。"""
    img = _resize_to(img_bgr, max_side)
    h, w = img.shape[:2]
    rec: dict = {"size": [w, h], "focal_35mm": focal_35mm, "hub_height_m": hub_height_m,
                 "rotor_radius_m": rotor_radius_m}
    t0 = time.time()
    seg = st = None
    try:
        seg = segment_turbine(img)
        st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    except Exception as exc:  # noqa: BLE001  真實照片會把分割撐出各種例外，這裡就是要記錄
        rec["failed"] = True
        rec["error"] = f"{type(exc).__name__}: {exc}"[:200]
        rec["verdict"] = assess_capture(seg, None, exc).to_dict()
        rec["seconds"] = round(time.time() - t0, 2)
        rec["_internals"] = {"img": img, "seg": seg, "st": None, "profiles": None}
        return rec
    rec["failed"] = False
    verdict = assess_capture(seg, st)
    rec["verdict"] = verdict.to_dict()
    rec["n_blades"] = len(st.blades)
    rec["tower_found"] = bool(st.tower_found)
    rec["hub"] = [round(float(st.hub[0]), 1), round(float(st.hub[1]), 1)]
    rec["tip_radii_px"] = [round(float(b.tip_radius_px), 1) for b in st.blades]
    rec["tip_angles_deg"] = [round(float(b.tip_angle_deg), 1) for b in st.blades]
    if rec["tip_radii_px"]:
        rec["radius_spread"] = round(float(np.ptp(rec["tip_radii_px"]) / max(np.median(rec["tip_radii_px"]), 1e-6)), 3)
    rec["view"] = verdict.metrics.get("view")
    profiles = None
    if verdict.ok and len(st.blades) >= 2:
        try:
            profiles = profiles_from_structure(st)
        except Exception as exc:  # noqa: BLE001
            rec["comparison_error"] = f"{type(exc).__name__}: {exc}"[:200]
    if profiles is not None and rec["view"] == "side":
        hang = verdict.metrics.get("hanging_blade_index")
        if hang is not None:
            sv = side_view_summary(profiles, int(hang), rotor_radius_m=rotor_radius_m)
            rec["side_view"] = {k: sv["hanging_blade"].get(k) for k in
                                ("label", "tip_deflection_px", "tip_deflection_cm", "radius_px")}
    elif profiles is not None and len(profiles) == 3:
        raw = compare_blades(profiles, noise_floor_px=NOISE_FLOOR_PX, rotor_radius_m=rotor_radius_m)
        raw_rows = _cmp_rows(raw, raw.get("cm_per_px"))
        rec["raw"] = {"cm_per_px": round(float(raw["cm_per_px"]), 3) if raw.get("cm_per_px") else None,
                      "comparisons": raw_rows, "flagged": _flagged(raw_rows)}
        pose_d, comp = _pose_and_comp(st, profiles, hub_height_m=hub_height_m, rotor_radius_m=rotor_radius_m,
                                      long_side_px=max(w, h), focal_35mm=focal_35mm)
        rec["pose"] = pose_d
        rec["comp"] = comp
        if comp is not None and hub_height_m:
            sens = {}
            for f in hub_sensitivity:
                p2, c2 = _pose_and_comp(st, profiles, hub_height_m=hub_height_m * f, rotor_radius_m=rotor_radius_m,
                                        long_side_px=max(w, h), focal_35mm=focal_35mm)
                sens[f"{f:.1f}"] = {
                    "hub_height_m": round(hub_height_m * f, 1),
                    "elevation_deg": p2.get("elevation_deg"),
                    "prebend_fit_m": None if c2 is None else c2["prebend_fit_m"],
                    "flagged": None if c2 is None else c2["flagged"],
                    "same_flags": None if c2 is None else (c2["flagged"] == comp["flagged"]),
                }
            rec["hub_sensitivity"] = sens
    rec["seconds"] = round(time.time() - t0, 2)
    rec["_internals"] = {"img": img, "seg": seg, "st": st, "profiles": profiles}
    return rec


# ---------------------------------------------------------------- 疊圖（只給人看，不進版控）


def draw_overlay(rec: dict, internals: dict) -> np.ndarray | None:
    import cv2

    img = internals.get("img")
    if img is None:
        return None
    out = img.copy()
    seg, st = internals.get("seg"), internals.get("st")
    if seg is not None:
        cnts, _ = cv2.findContours((seg.mask > 0).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(out, cnts, -1, (0, 255, 255), 1)
    if st is not None:
        hx, hy = int(round(st.hub[0])), int(round(st.hub[1]))
        cv2.circle(out, (hx, hy), max(3, int(st.hub_radius_px)), (0, 0, 255), 2)
        for b in st.blades:
            cv2.line(out, (hx, hy), (int(round(b.tip_xy[0])), int(round(b.tip_xy[1]))), (255, 0, 0), 2)
        if st.tower_x_at_hub_px is not None:
            tx = int(round(st.tower_x_at_hub_px))
            cv2.line(out, (tx, hy - 40), (tx, hy + 40), (0, 165, 255), 2)
    lines = [f"{rec.get('id', '')} {rec.get('model', '')} f35={rec.get('focal_35mm')}"]
    v = rec.get("verdict", {})
    lines.append(("OK " if v.get("ok") else "REJECT ") + (rec.get("view") or "") + " " +
                 ("; ".join(v.get("reasons", []))[:60]))
    if rec.get("pose"):
        p = rec["pose"]
        lines.append(f"el={p.get('elevation_deg')} yaw={p.get('yaw_deg')} dist={p.get('distance_m')}")
    if rec.get("raw"):
        lines.append(f"raw flags={rec['raw']['flagged']}")
    if rec.get("comp"):
        c = rec["comp"]
        lines.append(f"comp flags={c['flagged']} prebend={c['prebend_fit_m']} near_tower={c['blades_near_tower']}")
    y = 18
    for ln in lines:
        cv2.putText(out, ln, (6, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(out, ln, (6, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
        y += 18
    return out


# ---------------------------------------------------------------- 聚合


def reason_bucket(reason: str) -> str:
    """「三片葉尖半徑差 39%（上限 15%）：請等轉子轉開」→「三片葉尖半徑差 N%（…）」。
    括號裡是數字或例外訊息，逐張都不同，收進同一桶才數得出來。"""
    head = reason.split("：")[0]
    head = re.sub(r"\d+(\.\d+)?", "N", head)
    return re.sub(r"（[^）]*）", "（…）", head)


def _median(xs: list[float]) -> float | None:
    return None if not xs else round(float(np.median(xs)), 2)


def _rng(xs: list[float]) -> list[float] | None:
    return None if not xs else [round(float(min(xs)), 2), round(float(max(xs)), 2)]


def _dev_cm(rows: list[dict], metric: str) -> float | None:
    for r in rows:
        if r["metric"] == metric:
            return r.get("outlier_deviation_cm")
    return None


def summarise(rows: list[dict]) -> dict:
    n = len(rows)
    failed = [r for r in rows if r.get("failed")]
    ok = [r for r in rows if not r.get("failed") and r["verdict"]["ok"]]
    front = [r for r in ok if r.get("view") == "front" and r.get("raw")]
    side = [r for r in ok if r.get("view") == "side"]
    rejected = [r for r in rows if not r.get("failed") and not r["verdict"]["ok"]]
    posed = [r for r in front if r.get("pose", {}).get("usable")]
    comped = [r for r in front if r.get("comp")]

    def transitions(metric: str) -> dict:
        t = Counter()
        for r in comped:
            a = metric in r["raw"]["flagged"]
            b = metric in r["comp"]["flagged"]
            t["raw_flagged"] += a
            t["comp_flagged"] += b
            t["cleared"] += a and not b
            t["kept"] += a and b
            t["new"] += (not a) and b
        return dict(t)

    sens_changed = sum(1 for r in comped if r.get("hub_sensitivity") and
                       any(v.get("same_flags") is False for v in r["hub_sensitivity"].values()))
    sens_n = sum(1 for r in comped if r.get("hub_sensitivity"))
    el_delta = []
    for r in comped:
        hs = r.get("hub_sensitivity") or {}
        e0 = r["pose"].get("elevation_deg")
        for v in hs.values():
            if e0 is not None and v.get("elevation_deg") is not None:
                el_delta.append(abs(v["elevation_deg"] - e0))
    per_model: dict[str, dict] = {}
    for r in rows:
        m = per_model.setdefault(r.get("model", "?"), Counter())
        m["n"] += 1
        m["accepted"] += (not r.get("failed")) and r["verdict"]["ok"]
        m["front"] += bool(r.get("raw"))
        m["pose_usable"] += bool(r.get("pose", {}).get("usable"))
        m["raw_defl_flagged"] += bool(r.get("raw")) and DEFL in r["raw"]["flagged"]
        m["comp_defl_flagged"] += bool(r.get("comp")) and DEFL in r["comp"]["flagged"]
    return {
        "n": n, "failed": len(failed), "accepted": len(ok), "accepted_front": len(front),
        "accepted_side": len(side), "rejected": len(rejected),
        "reject_reasons": dict(Counter(reason_bucket(x) for r in rejected + failed
                                       for x in r["verdict"].get("reasons", [])).most_common()),
        "second_rotor_warnings": sum(1 for r in ok if any("另一個轉子" in w for w in r["verdict"].get("warnings", []))),
        "pose_usable": len(posed),
        "pose_unusable_notes": dict(Counter(x for r in front if not r.get("pose", {}).get("usable")
                                            for x in r.get("pose", {}).get("notes", [])).most_common()),
        "elevation_deg": {"median": _median([r["pose"]["elevation_deg"] for r in posed]),
                          "range": _rng([r["pose"]["elevation_deg"] for r in posed])},
        "yaw_deg": {"median_abs": _median([abs(r["pose"]["yaw_deg"]) for r in posed]),
                    "range": _rng([r["pose"]["yaw_deg"] for r in posed])},
        "distance_m": {"median": _median([r["pose"]["distance_m"] for r in posed]),
                       "range": _rng([r["pose"]["distance_m"] for r in posed])},
        "compensated": len(comped),
        "prebend_fit_m": {"ok": sum(1 for r in comped if r["comp"]["prebend_fit_ok"]),
                          "median_ok": _median([r["comp"]["prebend_fit_m"] for r in comped if r["comp"]["prebend_fit_ok"]]),
                          "range_all": _rng([r["comp"]["prebend_fit_m"] for r in comped])},
        "radius_compensated": sum(1 for r in comped if r["comp"]["radius_compensated"]),
        "near_tower": sum(1 for r in comped if r["comp"]["blades_near_tower"]),
        "tip_deflection": transitions(DEFL),
        "radius": transitions(RAD),
        "raw_defl_cm_median": _median([abs(d) for r in front if (d := _dev_cm(r["raw"]["comparisons"], DEFL)) is not None]),
        "comp_defl_cm_median": _median([abs(d) for r in comped if (d := _dev_cm(r["comp"]["comparisons"], DEFL)) is not None]),
        "raw_any_flagged": sum(1 for r in front if r["raw"]["flagged"]),
        "comp_any_flagged": sum(1 for r in comped if r["comp"]["flagged"]),
        "hub_sensitivity": {"n": sens_n, "flags_changed": sens_changed,
                            "elevation_delta_deg_median": _median(el_delta), "factors": list(HUB_SENSITIVITY)},
        "hub_height_source": dict(Counter(r.get("hub_height_source", "?") for r in rows)),
        "per_model": {k: dict(v) for k, v in sorted(per_model.items())},
        "seconds_median": _median([r["seconds"] for r in rows if r.get("seconds") is not None]),
    }


# ---------------------------------------------------------------- 報告


def _table(headers: list[str], body: list[list]) -> str:
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    lines += ["| " + " | ".join("—" if c is None else str(c) for c in row) + " |" for row in body]
    return "\n".join(lines)


def _fmt(x, nd=1):
    if x is None:
        return "—"
    return f"{x:.{nd}f}" if isinstance(x, (int, float)) else str(x)


def _flag_cell(rows: list[dict], metric: str) -> str:
    for r in rows:
        if r["metric"] == metric:
            cm = r.get("outlier_deviation_cm")
            s = f"{cm:+.0f} cm" if cm is not None else f"{r['outlier_deviation']:+.1f} px"
            return f"**{s} ⚑**" if r["flagged"] else s
    return "—"


def render_markdown(doc: dict) -> str:
    s = doc["summary"]
    rows = doc["images"]
    front = [r for r in rows if r.get("raw")]
    L: list[str] = []
    L.append("# 真實整機照上的姿態估計與透視補償（Commons）\n")
    L.append(f"> 版本 `{doc['version']}`。由 `scripts/real_pose_validation.py report` 從 `data/commons_pose_results.json` "
             "產生，**數字不手抄**；照片本體不進版控（CC BY／BY-SA，來源列在 §6），重跑用 "
             "`fetch_commons_turbines.py download` 抓同一份 manifest。\n")
    L.append("## 0. 一句話\n")
    td, rd = s["tip_deflection"], s["radius"]
    L.append(f"{s['n']} 張帶 EXIF 焦距、分類在機型頁下的 Commons 整機照：閘門放行 **{s['accepted']}**（正視 {s['accepted_front']}、"
             f"側視 {s['accepted_side']}），姿態可用 **{s['pose_usable']}/{s['accepted_front']}**。正視放行照片的三片互比原始標記"
             f"葉尖偏移 **{td.get('raw_flagged', 0)}** 張，補償後剩 **{td.get('comp_flagged', 0)}**（消掉 {td.get('cleared', 0)}、"
             f"留下 {td.get('kept', 0)}、新增 {td.get('new', 0)}）；半徑原始 {rd.get('raw_flagged', 0)} → 補償後 {rd.get('comp_flagged', 0)}。"
             f"預彎擬合落在合理範圍 {s['prebend_fit_m']['ok']}/{s['compensated']}（中位 {_fmt(s['prebend_fit_m']['median_ok'])} m）。"
             f"輪轂高度 ±20% 會翻掉補償結論的有 {s['hub_sensitivity']['flags_changed']}/{s['hub_sensitivity']['n']} 張。\n")
    L.append("這些是營運中的風機被路人拍下，先驅上沒有一台葉尖偏了兩公尺——所以原始標記幾乎都是假警報，"
             "「補償後剩幾個」是補償的成績、「新增幾個」是代價。**這裡量不到缺陷召回率**，那要有已知缺陷的照片。\n")
    L.append("## 1. 輸入\n")
    L.append(_table(["項目", "值"], [
        ["照片來源", "Wikimedia Commons 機型分類頁（`fetch_commons_turbines.py search`），篩 CC／PD 授權 + EXIF `FocalLengthIn35mmFilm` + 寬 ≥ 1600"],
        ["分析尺度", f"長邊 {MAX_SIDE} px（與 App 相同）；焦距換 px 用縮放後的長邊，所以縮圖不影響"],
        ["轉子半徑", "機型型錄直徑 ÷ 2（manifest `specs`）"],
        ["輪轂高度", "、".join(f"{k} {v}" for k, v in s["hub_height_source"].items()) + "（`typical` = 機型常見值，不是那一台的）"],
        ["相機高度", f"{P.DEFAULT_CAMERA_HEIGHT_M} m（假設手持站立；Commons 照片有些從高處或無人機拍，這時仰角會高估）"],
        ["機艙 overhang", f"{P.DEFAULT_NACELLE_OVERHANG_M} m 預設（yaw 粗估）"],
        ["雜訊底", f"{NOISE_FLOOR_PX} px（與 `SENSITIVITY.md` 相同）"],
        ["每張耗時中位", f"{_fmt(s['seconds_median'], 2)} s"],
    ]))
    L.append("")
    L.append("## 2. 閘門\n")
    L.append(_table(["結果", "張數"], [
        ["放行（正視）", s["accepted_front"]], ["放行（側視）", s["accepted_side"]],
        ["拒收", s["rejected"]], ["結構定位丟例外", s["failed"]],
        ["放行但警告畫面裡有第二個轉子", s["second_rotor_warnings"]],
    ]))
    L.append("")
    if s["reject_reasons"]:
        L.append("拒收原因（同一張可能多條）：\n")
        L.append(_table(["原因", "次數"], [[k, v] for k, v in s["reject_reasons"].items()]))
        L.append("")
    L.append("## 3. 姿態估計\n")
    L.append(_table(["量", "中位", "範圍"], [
        ["仰角（°）", _fmt(s["elevation_deg"]["median"]), _fmt(s["elevation_deg"]["range"])],
        ["|yaw|（°）", _fmt(s["yaw_deg"]["median_abs"]), _fmt(s["yaw_deg"]["range"])],
        ["距離（m）", _fmt(s["distance_m"]["median"]), _fmt(s["distance_m"]["range"])],
    ]))
    L.append("")
    if s["pose_unusable_notes"]:
        L.append("姿態不可用的原因：\n")
        L.append(_table(["原因", "次數"], [[k, v] for k, v in s["pose_unusable_notes"].items()]))
        L.append("")
    L.append("## 4. 補償前後\n")
    L.append(_table(["指標", "原始標記", "補償後標記", "消掉", "留下", "新增"], [
        ["葉尖偏移", td.get("raw_flagged", 0), td.get("comp_flagged", 0), td.get("cleared", 0), td.get("kept", 0), td.get("new", 0)],
        ["半徑", rd.get("raw_flagged", 0), rd.get("comp_flagged", 0), rd.get("cleared", 0), rd.get("kept", 0), rd.get("new", 0)],
    ]))
    L.append("")
    L.append(f"- 葉尖偏移離群量中位：原始 {_fmt(s['raw_defl_cm_median'], 0)} cm → 補償後 {_fmt(s['comp_defl_cm_median'], 0)} cm。")
    L.append(f"- 預彎擬合在 {P.PREBEND_FIT_RANGE_M[0]:.0f}–{P.PREBEND_FIT_RANGE_M[1]:.0f} m 內：{s['prebend_fit_m']['ok']}/{s['compensated']}，"
             f"全部範圍 {_fmt(s['prebend_fit_m']['range_all'])} m。")
    L.append(f"- 半徑有補償（|yaw| ≤ {P.RADIUS_COMP_MAX_YAW_DEG:.0f}°）：{s['radius_compensated']}/{s['compensated']}。")
    L.append(f"- 有葉片落在六點鐘 ±{P.NEAR_TOWER_DEG:.0f}° 而被點名：{s['near_tower']}/{s['compensated']}。")
    hs = s["hub_sensitivity"]
    L.append(f"- 輪轂高度 ×{hs['factors'][0]}／×{hs['factors'][1]}：補償標記集合改變 {hs['flags_changed']}/{hs['n']} 張，"
             f"仰角變動中位 {_fmt(hs['elevation_delta_deg_median'])}°。\n")
    L.append("### 4.1 逐張（正視放行）\n")
    body = []
    for r in sorted(front, key=lambda r: (r.get("model", ""), r["id"])):
        p, c = r.get("pose") or {}, r.get("comp")
        body.append([
            f"[{r['id']}]({r.get('page_url', '')})", r.get("model"), _fmt(r.get("focal_35mm"), 0),
            f"{r['hub_height_m']}{'*' if r.get('hub_height_source') == 'typical' else ''}",
            _fmt(p.get("elevation_deg")), _fmt(p.get("yaw_deg")), _fmt(p.get("distance_m"), 0),
            _flag_cell(r["raw"]["comparisons"], DEFL),
            "—" if c is None else _flag_cell(c["comparisons"], DEFL),
            "—" if c is None else (f"{c['prebend_fit_m']:.1f}" + ("" if c["prebend_fit_ok"] else " ✗")),
            _flag_cell(r["raw"]["comparisons"], RAD),
            "—" if c is None else _flag_cell(c["comparisons"], RAD),
            "—" if c is None else ("、".join("ABC"[i] for i in c["blades_near_tower"]) or "—"),
            "—" if not r.get("hub_sensitivity") else ("穩" if all(v.get("same_flags") for v in r["hub_sensitivity"].values()) else "翻"),
        ])
    L.append(_table(["照片", "機型", "f35", "輪轂高 m", "仰角°", "yaw°", "距離 m", "葉尖偏移 原始", "補償後", "預彎 m",
                     "半徑 原始", "補償後", "近塔", "±20%"], body))
    L.append("\n`*` 輪轂高度是機型典型值。⚑ = 三片互比標記（z ≥ 3 且另兩片一致）。「翻」= 輪轂高度 ±20% 時補償後的標記集合會變。\n")
    L.append("## 5. 每機型\n")
    L.append(_table(["機型", "張數", "放行", "正視互比", "姿態可用", "葉尖偏移原始標記", "補償後"],
                    [[k, v["n"], v["accepted"], v["front"], v["pose_usable"], v["raw_defl_flagged"], v["comp_defl_flagged"]]
                     for k, v in s["per_model"].items()]))
    L.append("")
    L.append("## 6. 來源與授權\n")
    L.append("照片不進版控。逐張：\n")
    L.append(_table(["檔案", "作者", "授權", "相機", "寬×高（原檔）"],
                    [[f"[{r['id']}]({r.get('page_url', '')}) {r.get('title', '')[:60]}", (r.get("artist") or "")[:40],
                      r.get("license"), r.get("camera_model") or "—",
                      f"{r.get('orig_width')}×{r.get('orig_height')}"] for r in sorted(rows, key=lambda r: r["id"])]))
    L.append("")
    return "\n".join(L)


# ---------------------------------------------------------------- CLI


def cmd_run(a: argparse.Namespace) -> int:
    import cv2

    man = json.load(open(a.manifest, encoding="utf-8"))
    # 下載器把檔名寫回 manifest 是在整批結束時；中途要看就直接對目錄找 c<pageid>.jpg
    cands = []
    for c in man["candidates"]:
        if not c.get("selected"):
            continue
        fname = c.get("file") or f"c{c['pageid']}.jpg"
        if os.path.exists(os.path.join(a.dir, fname)) and os.path.getsize(os.path.join(a.dir, fname)) > 20_000:
            cands.append({**c, "file": fname})
    if a.limit:
        cands = cands[: a.limit]
    if not cands:
        print("目錄裡沒有已下載的照片（先跑 fetch_commons_turbines.py download）", file=sys.stderr)
        return 2
    if a.overlays:
        os.makedirs(a.overlays, exist_ok=True)
    out_rows = []
    for k, c in enumerate(cands):
        path = os.path.join(a.dir, c["file"])
        img = cv2.imread(path)
        rid = f"c{c['pageid']}"
        if img is None:
            print(f"  讀不到 {path}", file=sys.stderr)
            continue
        rr = float(c["rotor_diameter_m"]) / 2.0 if c.get("rotor_diameter_m") else None
        rec = analyse_image(img, focal_35mm=c.get("focal_35mm"), hub_height_m=c.get("hub_height_m"), rotor_radius_m=rr)
        internals = rec.pop("_internals")
        rec = {"id": rid, "title": c["title"], "page_url": c.get("page_url"), "model": c.get("model"),
               "license": c.get("license"), "artist": c.get("artist"), "camera_model": c.get("camera_model"),
               "hub_height_source": c.get("hub_height_source"), "orig_width": c.get("width"),
               "orig_height": c.get("height"), "date": c.get("date"), **rec}
        out_rows.append(rec)
        if a.overlays:
            ov = draw_overlay(rec, internals)
            if ov is not None:
                cv2.imwrite(os.path.join(a.overlays, f"{rid}.jpg"), ov, [cv2.IMWRITE_JPEG_QUALITY, 80])
        v = rec["verdict"]
        tag = "OK" if v["ok"] else "REJ"
        extra = ""
        if rec.get("comp"):
            extra = f" raw={rec['raw']['flagged']} comp={rec['comp']['flagged']} el={rec['pose'].get('elevation_deg')}"
        print(f"  [{k + 1}/{len(cands)}] {rid} {c['model']} {tag} {rec.get('view') or ''}{extra}", file=sys.stderr)
    doc = {"version": VERSION, "manifest": os.path.basename(a.manifest), "max_side": MAX_SIDE,
           "noise_floor_px": NOISE_FLOOR_PX, "summary": summarise(out_rows), "images": out_rows}
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({k: doc["summary"][k] for k in ("n", "accepted", "accepted_front", "pose_usable", "compensated",
                                                       "tip_deflection", "radius")}, ensure_ascii=False))
    return 0


def cmd_report(a: argparse.Namespace) -> int:
    doc = json.load(open(a.results, encoding="utf-8"))
    doc["summary"] = summarise(doc["images"])  # 報告一律由逐張結果重算，不信檔裡存的
    Path(a.out).write_text(render_markdown(doc), encoding="utf-8")
    print(f"寫入 {a.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--manifest", default=str(ROOT / "data" / "commons_turbines_manifest.json"))
    r.add_argument("--dir", required=True)
    r.add_argument("--out", default=str(ROOT / "data" / "commons_pose_results.json"))
    r.add_argument("--overlays", default=None)
    r.add_argument("--limit", type=int, default=0)
    r.set_defaults(func=cmd_run)
    p = sub.add_parser("report")
    p.add_argument("--results", default=str(ROOT / "data" / "commons_pose_results.json"))
    p.add_argument("--out", default=str(ROOT / "REAL_POSE_VALIDATION.md"))
    p.set_defaults(func=cmd_report)
    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())

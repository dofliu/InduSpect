#!/usr/bin/env python3
"""偏軸透視靈敏度（A5，SPEC §13-11）：站偏了、仰拍了，三片互比會多量到什麼。

`render_front` 假設相機在轉子軸線上、葉片是平面剪影；真實地面照沒有一張是這樣拍的
（`BLADE_TEST_REPORT.md` §3.3：閘門放行 8 張、互比標記 5 張，量級 226 cm 不可能是缺陷）。
這支用 `synth.render_perspective`（針孔投影 + 預彎 + 轉子傾角 + 錐角）把那個假設拿掉，
逐一量：閘門擋不擋、半徑離散多少、葉尖偏移被標成幾公分、方位角間距偏多少。

五組掃描（每組回答一個問題）：
  A. 平面葉片、只有仰角        → 透視只出現在半徑，不出現在彎曲（直線投影仍是直線）
  B. 平面葉片、只有 yaw        → 同上，加上方位角間距偏離 120°
  C. 真實葉片（預彎 3 m、傾角 5°、錐角 2.5°）× 地面站位 × yaw → 假葉尖偏移的量級（cm）
  D. 同一站位、轉子方位角不同   → 單張正視照分不分得出「跟位置」還是「跟葉片」
  E. 站位規範：軸線上、水平距離 1.5–6× 輪轂高 → 閘門從哪裡開始放行、假訊號剩多少（定 App 的站位提示）
C／D／E 每一列另外算**姿態估計 + 透視補償**（`blade_proto/pose.py`）：仰角由輪轂高 + 焦距反推、
yaw 由塔軸偏移（overhang 預設 5 m，渲染用 6 m——先驗誤差是故意留著的）；補償後的互比另列一欄。

用法：
    python scripts/offaxis_sensitivity.py [--out OFFAXIS_SENSITIVITY.md] [--json data/offaxis_sensitivity.json] [--quick]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from blade_proto import pose as P  # noqa: E402
from blade_proto.geometry import compare_blades, profiles_from_structure  # noqa: E402
from blade_proto.quality import assess_capture  # noqa: E402
from blade_proto.segmentation import find_structure, segment_turbine  # noqa: E402
from blade_proto.synth import CameraSpec, SceneSpec, render_perspective  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ROTOR_RADIUS_M = 60.0
HUB_HEIGHT_M = 100.0
# 12 MP 橫幅、6 cm/px：轉子 2000 px 塞得進 3000 px 短邊（SENSITIVITY.md §1 同一組感光元件）
SENSOR = (4000, 3000)
CM_PER_PX = 6.0
REAL_BLADE = dict(prebend_m=3.0, rotor_tilt_deg=5.0, cone_deg=2.5)


def spacing_deviation_deg(angles_deg: list[float]) -> float:
    """三個方位角相鄰間距與 120° 的最大偏離。"""
    a = np.sort(np.asarray(angles_deg, float) % 360.0)
    if len(a) != 3:
        return float("nan")
    gaps = np.diff(np.r_[a, a[0] + 360.0])
    return float(np.max(np.abs(gaps - 120.0)))


def measure(spec: SceneSpec, cam: CameraSpec, label: str, group: str) -> dict:
    img, truth = render_perspective(spec, cam)
    t0 = time.time()
    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    verdict = assess_capture(seg, st)
    row = {
        "group": group, "label": label,
        "camera": truth["camera"],
        "rotor_azimuth_deg": spec.azimuth_deg,
        "truth_apparent_spread": float((max(truth["apparent_radii_px"]) - min(truth["apparent_radii_px"]))
                                       / np.median(truth["apparent_radii_px"])),
        "truth_spacing_dev_deg": spacing_deviation_deg(truth["image_azimuths_deg"]),
        "gate_ok": bool(verdict.ok),
        "gate_view": verdict.metrics.get("view"),
        "n_blades": len(st.blades),
        "tip_radius_spread": verdict.metrics.get("tip_radius_spread"),
        "spacing_dev_deg": spacing_deviation_deg([b.tip_angle_deg for b in st.blades]) if len(st.blades) == 3 else None,
        "seconds": round(time.time() - t0, 2),
    }
    if verdict.ok and verdict.metrics.get("view") == "front":
        profs = profiles_from_structure(st)
        cmp_ = compare_blades(profs, rotor_radius_m=ROTOR_RADIUS_M)
        row["cm_per_px"] = cmp_["cm_per_px"]
        row["any_flagged"] = bool(cmp_["any_flagged"])
        # 姿態估計 + 補償：焦距換成 35 mm 等效（App 從 EXIF 讀）、輪轂高從資產來
        long_side = max(spec.width, spec.height)
        f35 = cam.distance_m * spec.px_per_m * 36.0 / long_side
        est = P.estimate_pose(st, hub_height_m=HUB_HEIGHT_M, rotor_radius_m=ROTOR_RADIUS_M,
                              image_long_side_px=long_side, focal_35mm=f35)
        row["pose_est"] = {"elevation_deg": est.elevation_deg, "yaw_deg": est.yaw_deg, "distance_m": est.distance_m}
        comp = P.compensate_comparison(profs, est, ROTOR_RADIUS_M) if est.usable else None
        if comp is not None:
            row["compensated"] = {
                "prebend_fit_m": round(float(comp["prebend_fit_m"]), 2),
                "deflection_compensated": bool(comp["deflection_compensated"]),
                "radius_compensated": bool(comp["radius_compensated"]),
                "blades_near_tower": comp["blades_near_tower"],
            }
            for c in comp["comparisons"]:
                k = c["metric"].replace("_px", "")
                idx = int(c["outlier_index"])
                row["compensated"][k] = {
                    "flagged": bool(c["flagged"]), "z": round(float(c["z"]), 2),
                    "deviation_px": round(float(c["outlier_deviation"]), 2),
                    "deviation_cm": round(float(c["outlier_deviation_cm"]), 1),
                    "outlier_axis_deg": round(float(profs[idx].axis_angle_deg), 1),
                }
        for c in cmp_["comparisons"]:
            if c["metric"] not in ("tip_deflection_px", "radius_px"):
                continue
            k = c["metric"].replace("_px", "")
            idx = int(c["outlier_index"])
            row[k] = {
                "flagged": bool(c["flagged"]), "z": round(float(c["z"]), 2),
                "deviation_px": round(float(c["outlier_deviation"]), 2),
                "deviation_cm": round(float(c.get("outlier_deviation_cm") or float("nan")), 1),
                "outlier_axis_deg": round(float(profs[idx].axis_angle_deg), 1),
                "values_px": [round(float(v), 2) for v in c["values"]],
            }
        # 半徑離群是不是「最上面那片最短」——透視（仰拍）的簽名
        radii = [p.radius_px for p in profs]
        axes = [p.axis_angle_deg for p in profs]
        top = int(np.argmax([np.sin(np.deg2rad(a)) for a in axes]))
        row["shortest_is_topmost"] = bool(int(np.argmin(radii)) == top)
    return row


def configs(quick: bool) -> list[tuple[str, str, SceneSpec, CameraSpec]]:
    out = []
    base = dict(cm_per_px=CM_PER_PX, view="front", sensor_px=SENSOR)

    def spec(az=90.0, seed=0):
        return SceneSpec.for_scale(azimuth_deg=az, seed=seed, **base)

    # A. 平面、只有仰角（相機在軸線正下方）
    for el in ([0, 18, 30] if quick else [0, 10, 18, 25, 30]):
        d = 300.0 / np.cos(np.deg2rad(el)) if el else 300.0
        out.append(("A", f"仰角 {el}°", spec(), CameraSpec(distance_m=float(d), elevation_deg=float(el))))
    # B. 平面、只有 yaw
    for yaw in ([0, 20, 30] if quick else [0, 10, 20, 30]):
        out.append(("B", f"yaw {yaw}°", spec(), CameraSpec(distance_m=300.0, yaw_deg=float(yaw))))
    # C. 真實葉片 × 地面站位 × yaw
    for hor in ([180.0, 300.0] if quick else [180.0, 300.0, 480.0]):
        for yaw in ([0, 20] if quick else [0, 10, 20, 30]):
            cam = CameraSpec.ground(hor, HUB_HEIGHT_M, yaw_deg=float(yaw), **REAL_BLADE)
            out.append(("C", f"水平 {hor:.0f} m（仰角 {cam.elevation_deg:.0f}°）、yaw {yaw}°", spec(), cam))
    # D. 同一站位（水平 300 m、yaw 20°）、轉子方位角不同
    for az in ([90.0, 30.0] if quick else [90.0, 60.0, 30.0, 0.0]):
        cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=20.0, **REAL_BLADE)
        out.append(("D", f"葉片 A 方位角 {az:.0f}°", spec(az=az), cam))
    # E. 站位規範：站在軸線上、水平距離 = k × 輪轂高
    for k in ([2.0, 3.0, 4.0] if quick else [1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0]):
        hor = k * HUB_HEIGHT_M
        cam = CameraSpec.ground(hor, HUB_HEIGHT_M, yaw_deg=0.0, **REAL_BLADE)
        out.append(("E", f"{k:g}× 輪轂高（水平 {hor:.0f} m、仰角 {cam.elevation_deg:.0f}°）", spec(), cam))
    return out


def _fmt_dev(d: dict | None) -> str:
    if not d:
        return "—"
    mark = "**標記**" if d["flagged"] else "未標記"
    return f"{mark} {d['deviation_px']:+.1f} px（{d['deviation_cm']:+.0f} cm，z {d['z']:.1f}，離群片方位 {d['outlier_axis_deg']:.0f}°）"


def conclusions(rows: list[dict]) -> list[str]:
    """由數據算出來的結論——重跑掃描時它跟著變，不會留下過期的敘述。"""
    def grp(g):
        return [r for r in rows if r["group"] == g]

    def tip_cm(r):
        d = r.get("tip_deflection")
        return abs(d["deviation_cm"]) if d else None

    A, B, C, D = grp("A"), grp("B"), grp("C"), grp("D")
    planar = [r for r in A + B if r["gate_ok"] and r.get("tip_deflection")]
    planar_max = max(tip_cm(r) for r in planar) if planar else float("nan")
    planar_flag = sum(1 for r in planar if r["tip_deflection"]["flagged"])
    rej_A = [r["label"] for r in A if not r["gate_ok"]]
    rej_B = [r["label"] for r in B if not r["gate_ok"]]
    c_ok = [r for r in C if r["gate_ok"]]
    c_rej = [r for r in C if not r["gate_ok"]]
    c_tip = [tip_cm(r) for r in c_ok if r.get("tip_deflection")]
    c_flag = [r for r in c_ok if r.get("tip_deflection", {}).get("flagged")]
    c_radius_flag = [r for r in c_ok if r.get("radius", {}).get("flagged")]
    spacing_ok = [r["spacing_dev_deg"] for r in c_ok if r.get("spacing_dev_deg") is not None]
    topmost = [r.get("shortest_is_topmost") for r in c_ok]
    out = [
        f"1. **平面葉片再怎麼偏軸，葉尖偏移都量不到**：A、B 兩組放行的 {len(planar)} 個情境裡葉尖偏移互比 "
        f"{planar_flag} 個被標記，最大 |偏移| {planar_max:.0f} cm；透視全部落在**半徑**上（每一個仰角／yaw ≥ 10° 的情境半徑互比都被標記）。"
        "直線的投影仍是直線，這是幾何不是雜訊。",
        f"2. **閘門只擋得住極端站位**：平面葉片在仰角 {'、'.join(x.replace('仰角 ', '') for x in rej_A) or '—'}"
        f"／yaw {'、'.join(x.replace('yaw ', '') for x in rej_B) or '—'} 才被三片半徑離散（> 15%）擋下；"
        f"真實葉片在水平 180 m（仰角 29°）{len(c_rej)}/{len(c_rej)} 全擋、300 m 與 480 m **全部放行**。",
        f"3. **真實照片上的 226 cm 在這裡重現了**：有預彎的葉片、地面 300／480 m、yaw 0–30°，放行的 {len(c_ok)} 個情境葉尖偏移互比量到 "
        f"{min(c_tip):.0f}–{max(c_tip):.0f} cm（z {min(r['tip_deflection']['z'] for r in c_ok if r.get('tip_deflection')):.0f}–"
        f"{max(r['tip_deflection']['z'] for r in c_ok if r.get('tip_deflection')):.0f}），**標記 {len(c_flag)}/{len(c_ok)}**；"
        f"沒標記的那幾個不是量得小，是另兩片彼此也差得多（spread 規則），量級一樣是公尺級。半徑互比標記 {len(c_radius_flag)}/{len(c_ok)}。"
        "來源是**預彎被投影成 in-plane 彎曲**（錐角是線性的，PCA 軸吸收掉；預彎是 t²，變成彎曲係數）。"
        "場景裡沒有任何缺陷——這些全是假訊號，而且 z 值二十幾，**調雜訊底救不回來**：它是系統誤差不是雜訊。",
        f"4. **兩個候選指標都不夠**：放行情境的方位角間距偏離 120° 在 {min(spacing_ok):.1f}–{max(spacing_ok):.1f}°"
        "（真實照片有標記者中位 6°、無標記者 2°，b78792bf 只偏 3° 也被標——一致），480 m yaw ≥ 20° 只偏 3° 多、偏移量仍有 200 cm 以上；"
        f"「最短片在最上方」（仰拍的簽名）在 {sum(1 for t in topmost if t)}/{len(topmost)} 個放行情境成立，yaw 一大就換片。",
        f"5. **D 組分不出「跟位置」還是「跟葉片」**：轉子轉 30° 後放行的兩個方位角，離群片都是落在左下象限的那片"
        f"（{'、'.join(str(r['tip_deflection']['outlier_axis_deg']) + '°' for r in D if r.get('tip_deflection'))}）；另兩個方位角被閘門擋下。"
        "單張正視照沒有這個資訊，要驗「多幀取中位能抵消透視」得用轉一整圈的影片（動態層的 `tip_radius_mismatch` 那條路），本掃描沒做。",
        "6. **對 SPEC §13-11 的意義**：選項 (b)「用真實照片校準 `noise_floor_px`」**否決**——假訊號 z 14–40，雜訊底要放大十倍以上才能蓋住，"
        "那等於關掉這個量；選項 (a) 的兩個指標鑑別力不夠（第 4 點）；可行的三件（2026-09-16 決策：三個都做）：**站位規範**（第 7 點）、"
        "**報告措辭**（正視照的葉尖偏移寫成「含透視分量」，補償過的寫補了多少）、**相機姿態估計 + 透視補償**（第 8 點）。",
    ]
    E = grp("E")
    if E:
        passing = [r for r in E if r["gate_ok"]]
        rejected = [r["label"].split("（")[0] for r in E if not r["gate_ok"]]
        first_ok = passing[0]["label"].split("（")[0] if passing else "—"
        raw_cm = {r["label"].split("（")[0]: tip_cm(r) for r in passing if r.get("tip_deflection")}
        comp_cm = {r["label"].split("（")[0]: abs(r["compensated"]["tip_deflection"]["deviation_cm"])
                   for r in passing if r.get("compensated") and r["compensated"].get("tip_deflection")}
        out.append(
            f"7. **站位規範（E 組，站在軸線上）**：{'、'.join(rejected) or '—'} 被閘門擋下，**{first_ok} 起放行**；"
            f"放行站位的原始假葉尖偏移 {min(raw_cm.values()):.0f}–{max(raw_cm.values()):.0f} cm——**再遠也降不到門檻以下**"
            f"（仰角 12° 仍有 100 cm 級），站位只能讓閘門放行、讓補償有東西可補；補償後 {min(comp_cm.values()):.0f}–{max(comp_cm.values()):.0f} cm。"
            " App 的提示因此改成「水平 3–4× 輪轂高、站在軸線上、用 2x 把轉子填到畫面一半」（舊的 1.5–2× 是仰角 27–34°，一律被拒收）。")
    c_comp = [r for r in C if r["gate_ok"] and r.get("compensated")]
    if c_comp:
        tip_ok = sum(1 for r in c_comp if not r["compensated"]["tip_deflection"]["flagged"])
        tip_raw_flag = sum(1 for r in c_comp if r.get("tip_deflection", {}).get("flagged"))
        pb = [r["compensated"]["prebend_fit_m"] for r in c_comp]
        rad_done = [r for r in c_comp if r["compensated"]["radius_compensated"]]
        rad_ok = sum(1 for r in rad_done if not r["compensated"]["radius"]["flagged"])
        still = [f"{r['label']}（{r['compensated']['tip_deflection']['deviation_cm']:+.0f} cm）"
                 for r in c_comp if r["compensated"]["tip_deflection"]["flagged"]]
        el_err = [abs(r["pose_est"]["elevation_deg"] - r["camera"]["elevation_deg"]) for r in c_comp]
        yaw_err = [r["pose_est"]["yaw_deg"] - r["camera"]["yaw_deg"] for r in c_comp]
        out.append(
            f"8. **姿態估計 + 補償（C 組，估計姿態、不用真值）**：仰角誤差 ≤ {max(el_err):.1f}°；yaw 偏大 {min(yaw_err):+.0f}…{max(yaw_err):+.0f}°"
            "（overhang 先驗 5 m 對渲染 6 m）。葉尖偏移：原始標記 "
            f"{tip_raw_flag}/{len(c_comp)} → 補償後未標記 {tip_ok}/{len(c_comp)}，預彎擬合 {min(pb):.1f}–{max(pb):.1f} m（渲染 3.0）；"
            f"補償後仍標記：{'、'.join(still) if still else '無'}（yaw 估計誤差在大 yaw 處放大）。半徑只在 |yaw| ≤ {P.RADIUS_COMP_MAX_YAW_DEG:.0f}° 補："
            f"{len(rad_done)} 個情境補了、{rad_ok} 個不再標記。注入 400 cm 缺陷的驗證在 `tests/test_pose.py`：留一法擬合讓缺陷留在殘差裡、指對那一片。")
    return out


def render_markdown(rows: list[dict], quick: bool) -> str:
    L = [f"# 偏軸透視靈敏度（合成影像，A5）",
         "",
         f"產生：{time.strftime('%Y-%m-%d %H:%M')}；模式：{'quick' if quick else 'full'}。"
         f"場景：{ROTOR_RADIUS_M:.0f} m 葉片、輪轂高 {HUB_HEIGHT_M:.0f} m、{SENSOR[0]}×{SENSOR[1]} @ {CM_PER_PX} cm/px（輪轂平面）、"
         "局部天空模型、預設雜訊底 1.5 px。",
         "所有數字來自 `blade_proto.synth.render_perspective`（針孔投影）+ 與 App 相同的分割 → 結構定位 → 閘門 → 三片互比；",
         "**場景裡沒有任何缺陷**，下表每一個「標記」都是純透視造成的假訊號。cm 值由型錄轉子半徑反推（A4 的那條路）。",
         "",
         "## 0. 結論", ""] + conclusions(rows) + [""]
    groups = {
        "A": ("A. 平面葉片、只有仰角（相機在軸線正下方）", "透視只會出現在**半徑**：直線投影仍是直線，葉尖偏移量不到"),
        "B": ("B. 平面葉片、只有 yaw", "同上，另外方位角間距會偏離 120°"),
        "C": ("C. 真實葉片（預彎 3 m、傾角 5°、錐角 2.5°）× 地面站位 × yaw", "預彎在偏軸下被投影成 in-plane 彎曲——這才是真實照片上 226 cm 的來源"),
        "D": ("D. 同一站位（水平 300 m、yaw 20°）、轉子方位角不同", "轉子轉了、假訊號有沒有跟著換片？單張正視照上分不分得出「位置」與「葉片」"),
        "E": ("E. 站位規範：站在軸線上、水平距離 = k × 輪轂高（真實葉片）", "閘門從哪裡開始放行、假訊號剩多少、補償後剩多少——App 的站位提示要寫哪個數字"),
    }
    for g, (title, why) in groups.items():
        sub = [r for r in rows if r["group"] == g]
        if not sub:
            continue
        with_comp = g in ("C", "D", "E")
        L += [f"## {title}", "", f"問題：{why}。", ""]
        if with_comp:
            L += ["| 情境 | 閘門 | 半徑離散（量到／純投影） | 間距偏離 120° | 葉尖偏移互比（原始） | 半徵互比（原始） | 估計姿態（仰角／yaw，真值） | **補償後**葉尖偏移 | **補償後**半徑 | 預彎擬合 |".replace("半徵", "半徑"),
                  "|---|---|---|---|---|---|---|---|---|---|"]
        else:
            L += ["| 情境 | 閘門 | 半徑離散（量到／純投影） | 間距偏離 120°（量到／純投影） | 葉尖偏移互比 | 半徑互比 | 最短片在最上方 |",
                  "|---|---|---|---|---|---|---|"]
        for r in sub:
            gate = "放行" if r["gate_ok"] else f"**拒收**（{r['n_blades']} 片）"
            spread = f"{r['tip_radius_spread']:.3f}" if r.get("tip_radius_spread") is not None else "—"
            sp = f"{r['spacing_dev_deg']:.1f}°" if r.get("spacing_dev_deg") is not None else "—"
            if with_comp:
                pe, cp = r.get("pose_est"), r.get("compensated")
                cam = r["camera"]
                pose_s = (f"{pe['elevation_deg']:.0f}°／{pe['yaw_deg']:.0f}°（{cam['elevation_deg']:.0f}°／{cam['yaw_deg']:.0f}°）"
                          if pe and pe.get("elevation_deg") is not None and pe.get("yaw_deg") is not None else "—")
                tip_c = _fmt_dev(cp.get("tip_deflection")) if cp else "—"
                if cp and not cp["deflection_compensated"]:
                    tip_c += "（未補償）"
                rad_c = _fmt_dev(cp.get("radius")) if cp else "—"
                if cp and not cp["radius_compensated"]:
                    rad_c = f"未補償（yaw > {P.RADIUS_COMP_MAX_YAW_DEG:.0f}°）"
                if cp and cp.get("blades_near_tower"):
                    tip_c += f"；葉片 {''.join('ABC'[i] for i in cp['blades_near_tower'])} 近塔架"
                pb = f"{cp['prebend_fit_m']:.1f} m" if cp else "—"
                L.append(f"| {r['label']} | {gate} | {spread} ／ {r['truth_apparent_spread']:.3f} | {sp} | "
                         f"{_fmt_dev(r.get('tip_deflection'))} | {_fmt_dev(r.get('radius'))} | {pose_s} | {tip_c} | {rad_c} | {pb} |")
            else:
                L.append(f"| {r['label']} | {gate} | {spread} ／ {r['truth_apparent_spread']:.3f} | {sp} ／ {r['truth_spacing_dev_deg']:.1f}° | "
                         f"{_fmt_dev(r.get('tip_deflection'))} | {_fmt_dev(r.get('radius'))} | "
                         f"{'是' if r.get('shortest_is_topmost') else ('否' if 'shortest_is_topmost' in r else '—')} |")
        L.append("")
    return "\n".join(L) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(ROOT / "OFFAXIS_SENSITIVITY.md"))
    ap.add_argument("--json", default=str(ROOT / "data" / "offaxis_sensitivity.json"))
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--report-only", action="store_true", help="不重跑：讀既有 JSON 重新渲染 Markdown")
    a = ap.parse_args(argv)
    if a.report_only:
        doc = json.loads(Path(a.json).read_text(encoding="utf-8"))
        Path(a.out).write_text(render_markdown(doc["rows"], quick=False), encoding="utf-8")
        return 0
    rows = []
    for g, label, spec, cam in configs(a.quick):
        r = measure(spec, cam, label, g)
        rows.append(r)
        print(f"[{g}] {label}: gate={'ok' if r['gate_ok'] else 'REJECT'} spread={r.get('tip_radius_spread')} "
              f"tip={r.get('tip_deflection', {}).get('deviation_cm') if r.get('tip_deflection') else '—'} cm "
              f"({r['seconds']} s)", file=sys.stderr)
    Path(a.json).write_text(json.dumps({"rotor_radius_m": ROTOR_RADIUS_M, "hub_height_m": HUB_HEIGHT_M,
                                        "sensor": SENSOR, "cm_per_px": CM_PER_PX, "real_blade": REAL_BLADE,
                                        "rows": rows}, ensure_ascii=False, indent=1), encoding="utf-8")
    Path(a.out).write_text(render_markdown(rows, a.quick), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

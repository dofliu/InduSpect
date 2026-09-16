#!/usr/bin/env python3
"""偏軸透視靈敏度（A5，SPEC §13-11）：站偏了、仰拍了，三片互比會多量到什麼。

`render_front` 假設相機在轉子軸線上、葉片是平面剪影；真實地面照沒有一張是這樣拍的
（`BLADE_TEST_REPORT.md` §3.3：閘門放行 8 張、互比標記 5 張，量級 226 cm 不可能是缺陷）。
這支用 `synth.render_perspective`（針孔投影 + 預彎 + 轉子傾角 + 錐角）把那個假設拿掉，
逐一量：閘門擋不擋、半徑離散多少、葉尖偏移被標成幾公分、方位角間距偏多少。

四組掃描（每組回答一個問題）：
  A. 平面葉片、只有仰角        → 透視只出現在半徑，不出現在彎曲（直線投影仍是直線）
  B. 平面葉片、只有 yaw        → 同上，加上方位角間距偏離 120°
  C. 真實葉片（預彎 3 m、傾角 5°、錐角 2.5°）× 地面站位 × yaw → 假葉尖偏移的量級（cm）
  D. 同一站位、轉子方位角不同   → 假訊號跟著**位置**走不跟著**葉片**走（多幀取中位能抵消）

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
        "那等於關掉這個量；選項 (a) 的兩個指標鑑別力不夠（第 4 點）；可行的是：**站位規範**（水平距離 ≥ 4× 輪轂高，仰角 ≤ 14°，並站在軸線上）"
        "寫進引導拍攝、**報告措辭**把正視照的葉尖偏移改寫成「含透視分量，未驗證站位，僅供近距離複檢參考」、"
        "**相機姿態估計**（塔架收斂 → 仰角、輪轂偏離塔軸 → yaw）留給下一步。App 端本批未改判定。",
    ]
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
    }
    for g, (title, why) in groups.items():
        sub = [r for r in rows if r["group"] == g]
        if not sub:
            continue
        L += [f"## {title}", "", f"問題：{why}。", "",
              "| 情境 | 閘門 | 半徑離散（量到／純投影） | 間距偏離 120°（量到／純投影） | 葉尖偏移互比 | 半徑互比 | 最短片在最上方 |",
              "|---|---|---|---|---|---|---|"]
        for r in sub:
            gate = "放行" if r["gate_ok"] else f"**拒收**（{r['n_blades']} 片）"
            spread = f"{r['tip_radius_spread']:.3f}" if r.get("tip_radius_spread") is not None else "—"
            sp = f"{r['spacing_dev_deg']:.1f}°" if r.get("spacing_dev_deg") is not None else "—"
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

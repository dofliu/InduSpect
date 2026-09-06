"""命令列介面。

    python -m blade_proto analyze-still  IMG   [--cm-per-px X | --rotor-radius-m 60] [--hub x,y] [--out r.json] [--overlay o.png]
    python -m blade_proto analyze-edge   IMG   [--cm-per-px X] [--le top|bottom] [--out r.json] [--overlay o.png]
    python -m blade_proto analyze-video  VIDEO [--step N] [--max-side 960] [--out r.json] [--frames-dir DIR]
    python -m blade_proto synth-still    --view front|side [--cm-per-px 12] [--deflection-cm 50,0,0] [--erosion IDX:AMP:S:E] --out img.png
    python -m blade_proto synth-segment  [--cm-per-px 0.4] [--erosion-cm 5] --out seg.png
    python -m blade_proto synth-video    [--rpm 12] [--fps 30] [--seconds 5] [--shake 6] --out video.mp4
    python -m blade_proto sensitivity    [--quick] [--out SENSITIVITY.md]

外業回來後的用法見 README.md。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import cv2
import numpy as np

from . import synth
from .segmentation import segment_turbine, find_structure
from .geometry import profiles_from_structure, compare_blades
from .surface import analyze_blade_edges
from .dynamics import analyze_frames, analyze_video, video_frames, video_fps


def _read(path: str) -> np.ndarray:
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        sys.exit(f"讀不到影像：{path}")
    return img


def _dump(obj, path: str | None) -> None:
    text = json.dumps(obj, ensure_ascii=False, indent=2, default=_json_default)
    if path:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"→ {path}")
    else:
        print(text)


def _json_default(o):
    if isinstance(o, (np.floating, np.integer)):
        return o.item()
    if isinstance(o, np.ndarray):
        return o.tolist()
    return str(o)


def _parse_xy(s: str | None):
    if not s:
        return None
    x, y = s.split(",")
    return (float(x), float(y))


# ---------------------------------------------------------------- analyze-still


def cmd_analyze_still(a) -> None:
    img = _read(a.image)
    t0 = time.time()
    seg = segment_turbine(img, dist_thresh=a.dist_thresh)
    st = find_structure(seg.mask, hub_hint=_parse_xy(a.hub))
    profs = profiles_from_structure(st)
    cmp_ = compare_blades(profs, noise_floor_px=a.noise_floor_px, cm_per_px=a.cm_per_px,
                          rotor_radius_m=a.rotor_radius_m)
    out = {
        "image": a.image,
        "size": [img.shape[1], img.shape[0]],
        "segmentation": {"threshold_sigma": seg.threshold, "mask_area_frac": float((seg.mask > 0).mean())},
        "structure": {
            "hub": st.hub, "hub_radius_px": st.hub_radius_px, "hub_refined": st.hub_refined,
            "tower_found": st.tower_found, "tower_roll_deg": st.tower_angle_deg, "tower_width_px": st.tower_width_px,
            "n_blades": len(st.blades), "notes": st.notes,
        },
        "blades": [p.to_dict() for p in profs],
        "comparison": cmp_,
        "elapsed_s": round(time.time() - t0, 2),
    }
    _dump(out, a.out)
    if a.overlay:
        cv2.imwrite(a.overlay, draw_still_overlay(img, seg.mask, st, profs, cmp_))
        print(f"→ {a.overlay}")


def draw_still_overlay(img, mask, st, profs, cmp_) -> np.ndarray:
    vis = img.copy()
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(vis, contours, -1, (0, 200, 255), 2)
    hx, hy = int(round(st.hub[0])), int(round(st.hub[1]))
    cv2.circle(vis, (hx, hy), max(4, int(st.hub_radius_px)), (0, 0, 255), 2)
    flagged = {c["outlier_index"] for c in cmp_.get("comparisons", []) if c["flagged"]}
    scale = max(1.0, max(img.shape[:2]) / 1500.0)
    for p in profs:
        color = (0, 0, 255) if p.index in flagged else (0, 255, 0)
        tx, ty = int(round(p.tip_xy[0])), int(round(p.tip_xy[1]))
        cv2.line(vis, (hx, hy), (tx, ty), color, max(1, int(scale)))
        cv2.putText(vis, f"B{p.index} defl={p.tip_deflection_px:+.1f}px", (tx + 5, ty),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6 * scale, color, max(1, int(scale)), cv2.LINE_AA)
    return vis


# ---------------------------------------------------------------- analyze-edge


def cmd_analyze_edge(a) -> None:
    img = _read(a.image)
    res = analyze_blade_edges(img, cm_per_px=a.cm_per_px, leading_edge=a.le)
    _dump({"image": a.image, **res.to_dict()}, a.out)
    if a.overlay:
        vis = img.copy()
        cv2.putText(vis, f"top rms={res.top.rms_px:.2f}px pits={res.top.pit_count}  bottom rms={res.bottom.rms_px:.2f}px",
                    (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA)
        cv2.imwrite(a.overlay, vis)
        print(f"→ {a.overlay}")


# ---------------------------------------------------------------- analyze-video


def cmd_analyze_video(a) -> None:
    t0 = time.time()
    res = analyze_video(a.video, step=a.step, max_side=a.max_side, six_tol_deg=a.six_tol_deg, view=a.view)
    out = res.to_dict()
    out["video"] = a.video
    out["elapsed_s"] = round(time.time() - t0, 1)
    _dump(out, a.out)
    if a.frames_dir:
        os.makedirs(a.frames_dir, exist_ok=True)
        wanted = {}
        for b, idxs in enumerate(res.six_oclock_frames):
            for k in idxs:
                wanted.setdefault(k, []).append(b)
        for k, frame in enumerate(video_frames(a.video, a.step)):
            if k in wanted:
                for b in wanted[k]:
                    path = os.path.join(a.frames_dir, f"blade{b}_frame{k:05d}.png")
                    cv2.imwrite(path, frame)
        print(f"→ {a.frames_dir}/ ({sum(len(v) for v in wanted.values())} 張六點鐘幀)")


# ---------------------------------------------------------------- synth


def _parse_erosion(items):
    er = {}
    for s in items or []:
        idx, amp, st, en = s.split(":")
        er[int(idx)] = (float(amp), float(st), float(en))
    return er


def cmd_synth_still(a) -> None:
    defl = tuple(float(x) for x in a.deflection_cm.split(","))
    az = a.azimuth if a.azimuth is not None else (270.0 if a.view == "side" else 90.0)
    spec = synth.SceneSpec(cm_per_px=a.cm_per_px, azimuth_deg=az, tip_deflection_cm=defl,
                           erosion=_parse_erosion(a.erosion), seed=a.seed)
    if a.width and a.height:
        spec.width, spec.height = a.width, a.height
    img, truth = (synth.render_front if a.view == "front" else synth.render_side)(spec)
    cv2.imwrite(a.out, img)
    truth.pop("mask")
    print(f"→ {a.out}")
    if a.truth:
        _dump(truth, a.truth)


def cmd_synth_segment(a) -> None:
    img, truth = synth.render_blade_segment(cm_per_px=a.cm_per_px, erosion_amp_cm=a.erosion_cm, seed=a.seed)
    cv2.imwrite(a.out, img)
    print(f"→ {a.out}")


def cmd_synth_video(a) -> None:
    spec = synth.SceneSpec(width=a.width, height=a.height, cm_per_px=a.cm_per_px, azimuth_deg=a.azimuth, seed=a.seed,
                           hub_frac=(0.5, 0.42) if a.view == "front" else (0.5, 0.3))
    n = int(a.seconds * a.fps)
    writer = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), a.fps, (spec.width, spec.height))
    if not writer.isOpened():
        sys.exit("此 OpenCV 無 mp4v 編碼器；請改輸出 .avi 或用 synth-still 逐幀")
    for img, _ in synth.render_video_frames(spec, n, a.fps, a.rpm, view=a.view, shake_px=a.shake):
        writer.write(img)
    writer.release()
    print(f"→ {a.out} ({n} 幀 @ {a.fps} fps, {a.rpm} rpm)")


# ---------------------------------------------------------------- sensitivity


def _front_deviation(cm_per_px: float, sensor, defl_cm: float, seed: int) -> float:
    spec = synth.SceneSpec.for_scale(cm_per_px, "front", sensor, tip_deflection_cm=(defl_cm, 0, 0), seed=seed)
    img, _ = synth.render_front(spec)
    st = find_structure(segment_turbine(img).mask)
    profs = profiles_from_structure(st)
    if len(profs) < 3:
        return float("nan")
    # 葉片 0 是被偏移的那片（方位角 90° = 正上方）
    b0 = min(profs, key=lambda p: abs(((p.axis_angle_deg - 90.0) + 180) % 360 - 180))
    others = [p.tip_deflection_px for p in profs if p is not b0]
    return b0.tip_deflection_px - float(np.mean(others))


def _side_bend(cm_per_px: float, sensor, defl_cm: float, seed: int) -> float:
    spec = synth.SceneSpec.for_scale(cm_per_px, "side", sensor, tip_deflection_cm=(defl_cm, 0, 0), seed=seed)
    img, _ = synth.render_side(spec)
    st = find_structure(segment_turbine(img).mask)
    profs = profiles_from_structure(st)
    hang = [p for p in profs if abs(((p.axis_angle_deg - 270.0) + 180) % 360 - 180) < 20]
    return hang[0].tip_deflection_px if hang else float("nan")


def _edge_metrics(cm_per_px: float, amp_cm: float, seed: int):
    img, _ = synth.render_blade_segment(cm_per_px=cm_per_px, chord_m=2.0, erosion_amp_cm=amp_cm, seed=seed)
    d = analyze_blade_edges(img, cm_per_px=cm_per_px, leading_edge="top").to_dict()
    return d["le_over_te_rms_ratio"], d["top"]["inward_p95_px"], d["top"]["pit_count"]


def cmd_sensitivity(a) -> None:
    quick = a.quick
    seeds_clean = 3 if quick else 5  # 雜訊底要靠多個乾淨場景的 std，quick 也至少 3 個
    seeds = 1 if quick else 2
    noise_floor_min = 0.5  # px；少量 seed 的 std 會低估，給下限
    lines = ["# 靈敏度分析（合成影像）", "",
             f"產生時間：{time.strftime('%Y-%m-%d %H:%M')}；模式：{'quick' if quick else 'full'}。",
             "所有數字來自 `blade_proto.synth` 合成場景（60 m 葉片、4 m 根弦、天空漸層 + 雲層 + 模糊 σ0.9 + 雜訊 σ2.5）。",
             f"雜訊底 = {seeds_clean} 個乾淨場景量測值的 std（下限 {noise_floor_min} px）；quick 模式每個偏移量只跑 {seeds} 個 seed。",
             "**這是演算法在理想分割下的上限，不是外業結果**；外業誤差來源（手持、風擺、地面雜物）見 README。", ""]

    # 1. 正視三片互比：葉尖 in-plane 偏移
    lines += ["## 1. 正視三片互比：葉尖偏移可偵測門檻", "",
              "判準：偏移葉片相對另兩片的量測差 ≥ 3 × 乾淨場景雜訊底（std）。", "",
              "| 感光元件 | cm/px | 雜訊底 (px) | " + " | ".join(f"{d} cm" for d in a.deflections) + " |",
              "|---|---|---|" + "---|" * len(a.deflections)]
    for sensor, scales in ((( 4000, 3000), [4.8, 6.0, 8.0]), ((8000, 6000), [2.4, 3.0])):
        if quick and sensor[0] > 4000:
            continue
        for s in scales:
            clean = [_front_deviation(s, sensor, 0.0, k) for k in range(seeds_clean)]
            noise = max(float(np.nanstd(clean)), noise_floor_min)
            cells = []
            for d in a.deflections:
                meas = [_front_deviation(s, sensor, d, 10 + k) for k in range(seeds)]
                m = float(np.nanmean(meas))
                truth_px = d / s
                ok = "✅" if abs(m) >= 3 * noise else "❌"
                cells.append(f"{ok} {m:+.1f}px (真值 {truth_px:.1f})")
            lines.append(f"| {sensor[0]}×{sensor[1]} | {s} | {noise:.2f} | " + " | ".join(cells) + " |")
            print(f"front {sensor} {s} cm/px done", file=sys.stderr)
    lines.append("")

    # 2. 側視：垂掛葉片 flapwise 彎曲
    lines += ["## 2. 側視垂掛葉片：flapwise 彎曲量測精度", "",
              "單幀量測的彎曲係數（含 2 m 預彎）。跨幀/跨片比較時，可分辨的差異約為 3 × 雜訊底。", "",
              "| 感光元件 | cm/px | 雜訊底 (px) | 預彎真值 (px) | 量測 (px, 0 cm) | +25 cm 量測差 | +50 cm 量測差 |",
              "|---|---|---|---|---|---|---|"]
    for sensor, scales in (((3000, 4000), [2.5, 3.5]),):
        for s in scales:
            clean = [_side_bend(s, sensor, 0.0, k) for k in range(seeds_clean)]
            noise = max(float(np.nanstd(clean)), noise_floor_min)
            base = float(np.nanmean(clean))
            # 側視每格至少 2 個 seed：單一 seed 遇到雲塊黏在葉片上會整格失真
            d25 = float(np.nanmean([_side_bend(s, sensor, 25.0, 10 + k) for k in range(max(2, seeds))])) - base
            d50 = float(np.nanmean([_side_bend(s, sensor, 50.0, 20 + k) for k in range(max(2, seeds))])) - base
            prebend_px = 200.0 / s
            lines.append(f"| {sensor[0]}×{sensor[1]} | {s} | {noise:.2f} | {prebend_px:.1f} | {base:+.1f} | "
                         f"{'✅' if abs(d25) >= 3 * noise else '❌'} {d25:+.1f} (真值 {25 / s:.1f}) | "
                         f"{'✅' if abs(d50) >= 3 * noise else '❌'} {d50:+.1f} (真值 {50 / s:.1f}) |")
            print(f"side {s} cm/px done", file=sys.stderr)
    lines.append("")

    # 3. 前緣侵蝕
    lines += ["## 3. 長焦分區段照：前緣侵蝕可偵測門檻", "",
              "判準：前緣/後緣 rms 比 ≥ 2 且 往內凹 p95 ≥ 3 × 乾淨值。侵蝕以「平滑隨機凹坑、最大深度 = 振幅」模擬，凹坑寬度約 3 px。", "",
              "| cm/px（對應） | 乾淨 p95 (px) | " + " | ".join(f"{c} cm" for c in a.erosions) + " |",
              "|---|---|" + "---|" * len(a.erosions)]
    labels = {0.37: "5x@50m", 0.75: "5x@100m", 1.85: "2x@100m", 3.7: "1x@100m"}
    for s in [0.37, 0.75, 1.85, 3.7]:
        clean = [_edge_metrics(s, 0.0, k) for k in range(seeds_clean)]
        p95_clean = max(float(np.mean([c[1] for c in clean])), 0.05)
        cells = []
        for amp in a.erosions:
            ms = [_edge_metrics(s, amp, 10 + k) for k in range(seeds)]
            ratio = float(np.mean([m[0] for m in ms]))
            p95 = float(np.mean([m[1] for m in ms]))
            ok = "✅" if (ratio >= 2.0 and p95 >= 3 * p95_clean) else "❌"
            cells.append(f"{ok} 比 {ratio:.1f} / p95 {p95:.2f}px")
        lines.append(f"| {s} ({labels[s]}) | {p95_clean:.2f} | " + " | ".join(cells) + " |")
        print(f"edge {s} cm/px done", file=sys.stderr)
    lines.append("")
    lines += ["## 解讀", "",
              "- 正視整轉子幾何：12 MP 橫幅在 ~130 m（4.8 cm/px）可分辨 50 cm 級的葉尖偏移（≈10 px，雜訊底 1–2 px）；25 cm 不行。",
              "  **整轉子幾何靠主鏡頭高像素模式，不靠長焦**——長焦塞不進整個轉子；48 MP 全解析（2.4 cm/px）可把門檻壓到 25 cm。",
              "- 側視垂掛葉片：直幅 12 MP 在 2.5–3.5 cm/px，單幀彎曲量測雜訊約 1 px；50 cm 可分辨、25 cm 邊緣。",
              "  主要風險是雲塊黏在葉片邊緣把中心線拉歪（`n_contaminated_bins` > 0 時該幀應降權或重拍）。",
              "- 前緣侵蝕：5x 長焦在 50 m（0.37 cm/px）約 1 cm 深的凹坑就能分辨；5x 在 100 m 要 2 cm；1x 在 100 m 要 10 cm 級。",
              "- 以上皆為理想分割 + 靜止葉片的上限；外業第一件事是量實際雜訊底（同一片葉片連拍 5 張的量測 std）。"]
    text = "\n".join(lines)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print(f"→ {a.out}")


# ---------------------------------------------------------------- main


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="blade_proto", description="風力機葉片地面目視檢測原型")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("analyze-still", help="全機靜態照：分割、結構、三片互比")
    s.add_argument("image")
    s.add_argument("--cm-per-px", type=float)
    s.add_argument("--rotor-radius-m", type=float, help="未知 cm/px 時以葉片長度推算尺度")
    s.add_argument("--hub", help="手動指定輪轂 x,y（分割失敗時）")
    s.add_argument("--dist-thresh", type=float, help="天空距離門檻（robust σ），預設 5.5")
    s.add_argument("--noise-floor-px", type=float, default=1.5)
    s.add_argument("--out")
    s.add_argument("--overlay")
    s.set_defaults(fn=cmd_analyze_still)

    s = sub.add_parser("analyze-edge", help="長焦分區段照：前緣粗糙度")
    s.add_argument("image")
    s.add_argument("--cm-per-px", type=float)
    s.add_argument("--le", choices=["top", "bottom"], help="哪一側是前緣")
    s.add_argument("--out")
    s.add_argument("--overlay")
    s.set_defaults(fn=cmd_analyze_edge)

    s = sub.add_parser("analyze-video", help="轉動影片：轉速、葉尖軌跡、六點鐘取幀")
    s.add_argument("video")
    s.add_argument("--step", type=int, default=1, help="每 N 幀取 1 幀")
    s.add_argument("--max-side", type=int, default=960)
    s.add_argument("--six-tol-deg", type=float, default=4.0)
    s.add_argument("--view", choices=["front", "side"], default="front",
                   help="front：角度追蹤；side：轉子面邊視，以向下葉片投影長度找六點鐘")
    s.add_argument("--out")
    s.add_argument("--frames-dir", help="輸出六點鐘幀 PNG 的資料夾")
    s.set_defaults(fn=cmd_analyze_video)

    s = sub.add_parser("synth-still", help="合成全機照")
    s.add_argument("--view", choices=["front", "side"], default="front")
    s.add_argument("--cm-per-px", type=float, default=12.0)
    s.add_argument("--width", type=int)
    s.add_argument("--height", type=int)
    s.add_argument("--azimuth", type=float, help="葉片 A 方位角；預設正視 90、側視 270")
    s.add_argument("--deflection-cm", default="0,0,0")
    s.add_argument("--erosion", action="append", help="IDX:AMP_CM:START:END，可重複")
    s.add_argument("--seed", type=int, default=0)
    s.add_argument("--out", required=True)
    s.add_argument("--truth")
    s.set_defaults(fn=cmd_synth_still)

    s = sub.add_parser("synth-segment", help="合成長焦分區段照")
    s.add_argument("--cm-per-px", type=float, default=0.4)
    s.add_argument("--erosion-cm", type=float, default=0.0)
    s.add_argument("--seed", type=int, default=0)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_synth_segment)

    s = sub.add_parser("synth-video", help="合成轉動影片")
    s.add_argument("--view", choices=["front", "side"], default="front")
    s.add_argument("--width", type=int, default=960)
    s.add_argument("--height", type=int, default=1280)
    s.add_argument("--cm-per-px", type=float, default=15.0)
    s.add_argument("--azimuth", type=float, default=100.0)
    s.add_argument("--rpm", type=float, default=12.0)
    s.add_argument("--fps", type=float, default=30.0)
    s.add_argument("--seconds", type=float, default=5.0)
    s.add_argument("--shake", type=float, default=6.0)
    s.add_argument("--seed", type=int, default=0)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_synth_video)

    s = sub.add_parser("sensitivity", help="產生靈敏度分析 Markdown")
    s.add_argument("--quick", action="store_true")
    s.add_argument("--deflections", type=float, nargs="+", default=[10, 25, 50, 100])
    s.add_argument("--erosions", type=float, nargs="+", default=[0.5, 1, 2, 5, 10])
    s.add_argument("--out", default="SENSITIVITY.md")
    s.set_defaults(fn=cmd_sensitivity)
    return p


def main(argv=None) -> None:
    a = build_parser().parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()

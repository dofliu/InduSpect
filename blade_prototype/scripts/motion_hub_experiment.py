"""運動分割 vs 天空模型：在真實地面影片上對照輪轂定位。

用法：
    python scripts/motion_hub_experiment.py <影片目錄> <輸出目錄> [--frames 120]

對每段影片：
  1. 等距抽 N 幀、長邊縮到 1024（與 App 幾何層 workSide 一致）→ `motion_hub.locate_hub`。
  2. 對照組：同樣的幀裡取 8 幀跑既有 `segment_turbine` + `find_structure`（顏色／天空模型），
     記每幀的輪轂估計、離散度（對中位數的中位距離）、與運動法結果的距離。
  3. 自我一致性：奇偶幀各算一次運動法，兩個獨立子集的中心差幾 px。
  4. 疊圖：左 = 時間中位數背景（轉子應該消失），右 = 中間幀 + 運動遮罩聯集（黃）
     + 運動法輪轂與半徑（綠）+ 顏色法每幀輪轂（洋紅 ×）。

沒有人工標註。這一輪的證據強度是：「兩個獨立子集算出同一個中心」＋「疊圖肉眼可核」。
語料：Wikimedia Commons 上 CC0 / CC BY / CC BY-SA 授權的地面影片（見 INNOVATION_REVIEW.md）。
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from blade_proto.motion_hub import background_edges, hub_from_lines, locate_hub, motion_masks  # noqa: E402
from blade_proto.segmentation import find_structure, segment_turbine  # noqa: E402

WORK_SIDE = 1024


def read_frames(path: str, n: int) -> tuple[list[np.ndarray], dict]:
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise RuntimeError(f"open failed: {path}")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frames = []
    for i in np.linspace(0, max(total - 1, 0), n).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(i))
        ok, f = cap.read()
        if not ok:
            continue
        h, w = f.shape[:2]
        s = WORK_SIDE / max(h, w)
        if s < 1:
            f = cv2.resize(f, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA)
        frames.append(f)
    cap.release()
    return frames, dict(fps=fps, total_frames=total, duration_s=total / fps if fps else None, used=len(frames),
                        work_size=list(frames[0].shape[1::-1]) if frames else None)


def colour_baseline(frames: list[np.ndarray], n: int = 8) -> list[dict]:
    out = []
    for i in np.linspace(0, len(frames) - 1, n).astype(int):
        rec: dict = dict(frame=int(i))
        try:
            seg = segment_turbine(frames[i])
            st = find_structure(seg.mask, horizon_y=seg.horizon_y)
            rec.update(hub=[float(st.hub[0]), float(st.hub[1])], blades=len(st.blades),
                       rotor_r=float(max((b.tip_radius_px for b in st.blades), default=0.0)))
        except Exception as e:  # noqa: BLE001 — 對照組失敗也是資料
            rec.update(error=f"{type(e).__name__}: {e}")
        out.append(rec)
    return out


def overlay(bg: np.ndarray, union: np.ndarray, motion, colour: list[dict], sample: np.ndarray) -> np.ndarray:
    vis = sample.copy()
    tint = np.zeros_like(vis)
    tint[union > 0] = (0, 200, 255)
    vis = cv2.addWeighted(vis, 1.0, tint, 0.35, 0)
    if motion.ok:
        cx, cy = motion.hub
        cv2.circle(vis, (round(cx), round(cy)), max(4, round(motion.rotor_r_px)), (0, 255, 0), 2)
        cv2.drawMarker(vis, (round(cx), round(cy)), (0, 255, 0), cv2.MARKER_CROSS, 40, 3)
    for c in colour:
        if "hub" in c:
            cv2.drawMarker(vis, (round(c["hub"][0]), round(c["hub"][1])), (255, 0, 255), cv2.MARKER_TILTED_CROSS, 24, 2)
    return np.hstack([cv2.cvtColor(bg, cv2.COLOR_GRAY2BGR), vis])


def run(path: Path, out_dir: Path, n_frames: int) -> dict:
    frames, info = read_frames(str(path), n_frames)
    if len(frames) < 8:
        return dict(video=path.name, error="too few decodable frames", **info)
    motion, st, bg = locate_hub(frames)
    _, masks, thr = motion_masks(st.frames, valid=st.valid)
    union = (masks.max(axis=0) * 255).astype(np.uint8)
    edges = background_edges(bg)
    a = hub_from_lines(masks[0::2], bg_edges=edges, valid=st.valid)
    b = hub_from_lines(masks[1::2], bg_edges=edges, valid=st.valid)
    consist = None
    if a.ok and b.ok:
        consist = dict(hub_diff_px=float(math.hypot(a.hub[0] - b.hub[0], a.hub[1] - b.hub[1])),
                       r_diff_px=abs(a.rotor_r_px - b.rotor_r_px))
    colour = colour_baseline(frames)
    ch = np.array([c["hub"] for c in colour if "hub" in c])
    colour_summary: dict = dict(n=len(colour), ok=int(len(ch)))
    if len(ch):
        med = np.median(ch, axis=0)
        colour_summary.update(median_hub=med.tolist(),
                              spread_px=float(np.median(np.hypot(ch[:, 0] - med[0], ch[:, 1] - med[1]))))
        if motion.ok:
            colour_summary["dist_to_motion_px"] = float(math.hypot(med[0] - motion.hub[0], med[1] - motion.hub[1]))
            colour_summary["frames_within_20px_of_motion"] = int(
                np.sum(np.hypot(ch[:, 0] - motion.hub[0], ch[:, 1] - motion.hub[1]) <= 20))
    vis = overlay(bg, union, motion, colour, st.frames[len(frames) // 2])
    cv2.imwrite(str(out_dir / f"{path.stem}_overlay.jpg"), vis, [cv2.IMWRITE_JPEG_QUALITY, 82])
    shifts_ok = [s for s in st.shifts_px if s == s]
    return dict(
        video=path.name, **info, diag_px=float(math.hypot(*frames[0].shape[1::-1])),
        stabilise=dict(median_shift_px=float(np.median(shifts_ok)) if shifts_ok else None,
                       max_shift_px=float(max(shifts_ok)) if shifts_ok else None,
                       failed=st.failed_frames, fallback=st.fallback_frames,
                       orb=st.methods.count("orb")),
        motion_thr=thr, union_frac=float(union.mean() / 255),
        motion=dict(ok=motion.ok, hub=list(motion.hub) if motion.hub else None, rotor_r_px=motion.rotor_r_px,
                    peak=motion.peak, peak_ratio=motion.peak_ratio if motion.ok else None,
                    n_lines=motion.n_lines, n_lines_through_hub=motion.n_lines_through_hub, notes=motion.notes),
        consistency=consist, colour=colour_summary, colour_per_frame=colour,
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("video_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--frames", type=int, default=120)
    args = ap.parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    vids = sorted(p for p in Path(args.video_dir).iterdir() if p.suffix.lower() in {".webm", ".ogv", ".mp4", ".mov"})
    results = []
    for v in vids:
        try:
            r = run(v, out_dir, args.frames)
        except Exception as e:  # noqa: BLE001
            r = dict(video=v.name, error=f"{type(e).__name__}: {e}")
        results.append(r)
        m, c, s = r.get("motion", {}), r.get("colour", {}), r.get("stabilise", {})
        hub = m.get("hub")
        print(f"{v.name[:44]:44s} shift={s.get('median_shift_px') or 0:.1f}/{s.get('max_shift_px') or 0:.1f}px "
              f"orb={s.get('orb')} fb={s.get('fallback')} fail={s.get('failed')} union={r.get('union_frac', 0):.2f} | "
              f"motion={'(%d,%d)' % tuple(hub) if hub else 'x'} r={m.get('rotor_r_px', 0):.0f} "
              f"ratio={m.get('peak_ratio') or 0:.1f} lines={m.get('n_lines_through_hub', 0)}/{m.get('n_lines', 0)} "
              f"consist={r.get('consistency')} | colour {c.get('ok')}/{c.get('n')} spread={c.get('spread_px', float('nan')):.0f} "
              f"dist={c.get('dist_to_motion_px', float('nan')):.0f} within20={c.get('frames_within_20px_of_motion')} "
              f"{r.get('error', '')}", flush=True)
    json.dump(results, open(out_dir / "summary.json", "w"), indent=1, default=float, ensure_ascii=False)


if __name__ == "__main__":
    main()

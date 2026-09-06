"""動態層（§5.4）：影片葉尖追蹤、轉速、六點鐘取幀、葉尖半徑一致性。

每幀：縮圖 → 用第一幀的天空模型分割 → 結構定位（輪轂、葉片元件）→ 每片葉尖 (角度, 半徑)。
追蹤：以角度連續性把偵測配到三條軌跡；缺測（如正視時葉片與塔架重疊）由角速度預測補。
轉速：展開角度對時間線性回歸。
六點鐘：每條軌跡 |角度 − 270°| 的局部極小且低於容差的幀。
手持晃動：所有量都相對每幀的輪轂，天然抵消平移。
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from itertools import permutations
from typing import Iterable, Iterator

import cv2
import numpy as np

from .segmentation import fit_sky_model, segment_turbine, find_structure, sky_distance, _otsu_threshold


@dataclass
class BladeTrack:
    angles_deg: list[float | None] = field(default_factory=list)  # 展開後的角度（None = 缺測且無法補）
    radii_px: list[float | None] = field(default_factory=list)
    detected: list[bool] = field(default_factory=list)


@dataclass
class DynamicsResult:
    fps: float
    n_frames: int
    rpm: float
    direction: str  # 'ccw' | 'cw'（數學慣例，正視影像）
    hub_track: list[tuple[float, float]]
    tracks: list[BladeTrack]
    six_oclock_frames: list[list[int]]  # 每片葉片的六點鐘幀索引
    radius_median_px: list[float]
    radius_outlier_index: int | None
    radius_deviation_px: float | None
    notes: list[str]

    def to_dict(self) -> dict:
        d = asdict(self)
        d["tracks"] = [{"detected_frac": float(np.mean(t.detected)) if t.detected else 0.0} for t in self.tracks]
        d["hub_track"] = [[round(x, 2), round(y, 2)] for x, y in self.hub_track]
        return d


def _wrap(a: np.ndarray | float) -> np.ndarray | float:
    return (a + 180.0) % 360.0 - 180.0


def video_frames(path: str, step: int = 1) -> Iterator[np.ndarray]:
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise IOError(f"無法開啟影片：{path}")
    k = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if k % step == 0:
            yield frame
        k += 1
    cap.release()


def video_fps(path: str) -> float:
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    cap.release()
    return float(fps)


def _tips_from_mask(mask: np.ndarray, hub_hint=None):
    try:
        st = find_structure(mask, hub_hint=hub_hint)
    except ValueError:
        return None, []
    tips = [(b.tip_angle_deg, b.tip_radius_px) for b in st.blades if b.tip_radius_px > 3.0 * st.hub_radius_px]
    return st.hub, tips


def detect_tips(frame_bgr: np.ndarray, sky_model, dist_thresh: float, max_side: int, hub_hint=None):
    """單幀：回傳 (hub_xy, [(angle_deg, radius_px), ...], scale, mask)，座標為縮圖尺度。"""
    h, w = frame_bgr.shape[:2]
    scale = min(1.0, max_side / max(h, w))
    small = frame_bgr if scale >= 1.0 else cv2.resize(frame_bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    seg = segment_turbine(small, sky_model=sky_model, dist_thresh=dist_thresh, full_res=True, max_side=max_side)
    hub, tips = _tips_from_mask(seg.mask, hub_hint)
    return hub, tips, scale, seg.mask


def _assign(pred: list[float | None], dets: list[tuple[float, float]], tol_deg: float) -> list[int | None]:
    """把偵測配到三條軌跡（角度最近、總距離最小的排列）。回傳每條軌跡對應的偵測索引。"""
    n_tr = len(pred)
    if not dets:
        return [None] * n_tr
    best, best_cost = None, np.inf
    slots = list(range(len(dets))) + [None] * n_tr
    for perm in set(permutations(slots, n_tr)):
        cost = 0.0
        used = set()
        ok = True
        for ti, di in enumerate(perm):
            if di is None:
                cost += tol_deg  # 缺測懲罰
                continue
            if di in used:
                ok = False
                break
            used.add(di)
            if pred[ti] is None:
                cost += tol_deg * 0.5
            else:
                dd = abs(_wrap(dets[di][0] - pred[ti]))
                if dd > tol_deg:
                    ok = False
                    break
                cost += dd
        if ok and cost < best_cost:
            best, best_cost = perm, cost
    return list(best) if best is not None else [None] * n_tr


def _filter_hub(hub, payload, mask, hub_hist: list, window: int, jump_px: float, redo):
    """線上輪轂濾波：以最近 window 幀已接受的輪轂中位數為參考，
    偏離 > max(jump_px, 3×MAD) 或本幀失敗 → 用參考當固定輪轂重算（redo(mask, hub_hint) → (hub, payload)）。
    暖機 3 幀後啟用。回傳 (hub, payload, 是否重算)。"""
    fixed = 0
    if len(hub_hist) >= 3:
        recent = np.array(hub_hist[-window:])
        ref = np.median(recent, axis=0)
        dev = np.linalg.norm(recent - ref, axis=1)
        tol = max(jump_px, 3.0 * float(np.median(dev)) * 1.4826)
        if hub is None or np.hypot(hub[0] - ref[0], hub[1] - ref[1]) > tol:
            hub, payload = redo(mask, (float(ref[0]), float(ref[1])))
            fixed = 1
    if hub is not None:
        hub_hist.append(hub)
    return hub, payload, fixed


def _down_length_from_mask(mask: np.ndarray, hub_hint=None):
    """側視單幀：回傳 (hub, 向下葉片投影長度 px 或 nan)。向下葉片 = 葉尖角度在 270°±25° 內、半徑最大者。"""
    try:
        st = find_structure(mask, hub_hint=hub_hint)
    except ValueError:
        return None, float("nan")
    down = [b.tip_radius_px for b in st.blades if abs(_wrap(b.tip_angle_deg - 270.0)) < 25.0]
    return st.hub, (max(down) if down else float("nan"))


def _analyze_side(frames, fps: float, max_side: int, hub_window: int, hub_jump_px: float) -> DynamicsResult:
    notes: list[str] = []
    sky_model = thresh = None
    hub_track: list[tuple[float, float]] = []
    hub_hist: list[tuple[float, float]] = []
    lengths: list[float] = []
    n_fixed = 0
    for frame in frames:
        h, w = frame.shape[:2]
        scale = min(1.0, max_side / max(h, w))
        small = frame if scale >= 1.0 else cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
        if sky_model is None:
            sky_model = fit_sky_model(small)
            thresh = max(_otsu_threshold(sky_distance(small, sky_model)), 4.0)
        mask = segment_turbine(small, sky_model=sky_model, dist_thresh=thresh, full_res=True, max_side=max_side).mask
        hub, length = _down_length_from_mask(mask)
        hub, length, fixed = _filter_hub(hub, length, mask, hub_hist, hub_window, hub_jump_px, _down_length_from_mask)
        n_fixed += fixed
        hub_track.append(hub if hub is not None else (float("nan"), float("nan")))
        lengths.append(length)
    n = len(lengths)
    if n < 5:
        raise ValueError("幀數太少")
    if n_fixed:
        notes.append(f"{n_fixed} 幀輪轂離群，以鄰近幀中位數固定重算")
    L = np.array(lengths, float)
    ok = np.isfinite(L)
    if ok.sum() < 5:
        raise ValueError("幾乎沒有幀找到向下的葉片")
    idx = np.arange(n)
    Lf = np.interp(idx, idx[ok], L[ok])
    Ls = np.convolve(np.pad(Lf, 2, mode="edge"), np.ones(5) / 5.0, mode="valid")
    # 局部極大：高於鄰近且高於 95% 的全域最大（排除葉片剛進入向下區間的小長度）
    peaks = [k for k in range(1, n - 1) if Ls[k] >= Ls[k - 1] and Ls[k] > Ls[k + 1] and Ls[k] > 0.95 * Ls.max()]
    # 合併相鄰峰（同一次通過）：餘弦平頂加手持晃動會在同一次通過產生多個局部極大
    min_gap = max(3, n // 12)
    merged: list[int] = []
    for k in peaks:
        if merged and k - merged[-1] < min_gap:
            if Ls[k] > Ls[merged[-1]]:
                merged[-1] = k
        else:
            merged.append(k)
    # 拋物線精修：在每個峰 ±win 幀內對平滑後長度擬合二次式，頂點為六點鐘時刻。
    # 窗必須對稱（片頭/片尾的峰把窗縮小），不然截斷的餘弦會把頂點推偏。
    six: list[int] = []
    peak_len: list[float] = []
    win_full = max(4, n // 10)
    for k in merged:
        win = min(win_full, k, n - 1 - k)
        if win >= 3:
            xs = np.arange(k - win, k + win + 1)
            ys = Ls[k - win: k + win + 1]
            a, b, c = np.polyfit(xs - k, ys, 2)
            if a < 0:
                v = -b / (2 * a)
                if abs(v) <= win:
                    k = int(round(k + v))
        k = int(np.clip(k, 0, n - 1))
        if six and abs(k - six[-1]) < min_gap:
            continue  # 兩個原始峰精修後收斂到同一頂點
        six.append(k)
        peak_len.append(float(Ls[k]))
    rpm = float("nan")
    if len(six) >= 2:
        dt = np.diff(six) / fps  # 相鄰兩片通過六點鐘 = 1/3 圈
        rpm = 60.0 / (3.0 * float(np.median(dt)))
    # 每次通過依序輪到 A/B/C：以循環標籤分組
    six_by_blade: list[list[int]] = [[], [], []]
    for i, k in enumerate(six):
        six_by_blade[i % 3].append(k)
    med = [float(np.median([peak_len[i] for i in range(len(peak_len)) if i % 3 == b])) if any(i % 3 == b for i in range(len(peak_len))) else float("nan") for b in range(3)]
    r_out, r_dev = None, None
    if all(np.isfinite(med)):
        m = np.array(med)
        dev = m - np.median(m)
        r_out = int(np.argmax(np.abs(dev)))
        r_dev = float(dev[r_out])
    notes.append("側視：葉片標籤 0/1/2 為通過六點鐘的先後順序（循環），非實際葉片編號")
    return DynamicsResult(
        fps=fps, n_frames=n, rpm=rpm, direction="n/a", hub_track=hub_track, tracks=[],
        six_oclock_frames=six_by_blade, radius_median_px=med, radius_outlier_index=r_out,
        radius_deviation_px=r_dev, notes=notes,
    )


def analyze_frames(
    frames: Iterable[np.ndarray],
    fps: float,
    max_side: int = 960,
    six_tol_deg: float = 4.0,
    assign_tol_deg: float = 30.0,
    n_blades: int = 3,
    hub_window: int = 15,
    hub_jump_px: float = 12.0,
    view: str = "front",
) -> DynamicsResult:
    """view="front"：角度追蹤（轉速、三片半徑、六點鐘 = 預測角度過 270°，葉片會被塔架遮住，為內插值）。
    view="side"：轉子面邊視、三葉尖共線，改追蹤「向下葉片的投影長度」，六點鐘 = 長度局部極大（拋物線精修）。
    """
    if view == "side":
        return _analyze_side(frames, fps, max_side, hub_window, hub_jump_px)
    notes: list[str] = []
    sky_model = None
    thresh = None
    hub_track: list[tuple[float, float]] = []
    hub_hist: list[tuple[float, float]] = []
    n_hub_fixed = 0
    raw: list[list[tuple[float, float]]] = []  # 每幀偵測 (angle, radius)
    for k, frame in enumerate(frames):
        if sky_model is None:
            h, w = frame.shape[:2]
            scale = min(1.0, max_side / max(h, w))
            small = frame if scale >= 1.0 else cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
            sky_model = fit_sky_model(small)
            thresh = max(_otsu_threshold(sky_distance(small, sky_model)), 4.0)
        hub, tips, _, mask = detect_tips(frame, sky_model, thresh, max_side)
        # 線上輪轂濾波：葉片與塔架重疊的幀，結構定位可能把輪轂拉到塔架上（差幾十 px）。
        # 以最近 N 幀已接受的輪轂中位數為參考，偏離 > max(hub_jump_px, 3×MAD) 就用該參考當固定輪轂重算。
        hub, tips, fixed = _filter_hub(hub, tips, mask, hub_hist, hub_window, hub_jump_px, _tips_from_mask)
        n_hub_fixed += fixed
        hub_track.append(hub if hub is not None else (float("nan"), float("nan")))
        raw.append(tips)
    n_frames = len(raw)
    if n_frames < 3:
        raise ValueError("幀數太少")
    if n_hub_fixed:
        notes.append(f"{n_hub_fixed} 幀輪轂離群，以鄰近幀中位數固定重算")

    # 追蹤
    tracks = [BladeTrack() for _ in range(n_blades)]
    last: list[float | None] = [None] * n_blades
    omega = 0.0  # deg/frame
    started = False
    for k, dets in enumerate(raw):
        if not started:
            if len(dets) >= n_blades:
                order = sorted(dets, key=lambda d: d[0])[:n_blades]
                for ti, (a, r) in enumerate(order):
                    tracks[ti].angles_deg.append(a)
                    tracks[ti].radii_px.append(r)
                    tracks[ti].detected.append(True)
                    last[ti] = a
                started = True
            else:
                for t in tracks:
                    t.angles_deg.append(None)
                    t.radii_px.append(None)
                    t.detected.append(False)
            continue
        pred = [None if a is None else a + omega for a in last]
        assign = _assign(pred, dets, assign_tol_deg)
        new_omegas = []
        for ti, di in enumerate(assign):
            if di is None:
                a = pred[ti]
                tracks[ti].angles_deg.append(a)
                tracks[ti].radii_px.append(None)
                tracks[ti].detected.append(False)
            else:
                a_det, r = dets[di]
                prev = last[ti]
                a = a_det if prev is None else prev + _wrap(a_det - prev)  # 展開
                if prev is not None:
                    new_omegas.append(a - prev)
                tracks[ti].angles_deg.append(a)
                tracks[ti].radii_px.append(r)
                tracks[ti].detected.append(True)
            last[ti] = tracks[ti].angles_deg[-1]
        if new_omegas:
            omega = 0.7 * omega + 0.3 * float(np.median(new_omegas)) if omega else float(np.median(new_omegas))
    if not started:
        raise ValueError("整段影片都找不到三片葉尖")

    # 轉速：所有軌跡展開角度對時間回歸（各自去掉常數項）
    slopes = []
    for t in tracks:
        a = np.array([np.nan if v is None else v for v in t.angles_deg], float)
        det = np.array(t.detected)
        ok = ~np.isnan(a) & det
        if ok.sum() >= 5:
            tt = np.flatnonzero(ok) / fps
            slopes.append(np.polyfit(tt, a[ok], 1)[0])
    if not slopes:
        raise ValueError("軌跡太短，無法估轉速")
    omega_deg_s = float(np.median(slopes))
    rpm = abs(omega_deg_s) / 360.0 * 60.0
    direction = "ccw" if omega_deg_s > 0 else "cw"

    # 六點鐘幀
    six: list[list[int]] = []
    for t in tracks:
        a = np.array([np.nan if v is None else v for v in t.angles_deg], float)
        err = np.abs(_wrap(a - 270.0))
        idx = []
        for k in range(1, n_frames - 1):
            if np.isnan(err[k]):
                continue
            left = err[k - 1] if not np.isnan(err[k - 1]) else np.inf
            right = err[k + 1] if not np.isnan(err[k + 1]) else np.inf
            if err[k] <= six_tol_deg and err[k] <= left and err[k] < right:
                idx.append(k)
        # 同一次通過可能因手持晃動產生多個局部極小：間隔 < 1/6 圈者只留誤差最小的
        min_gap = max(2, int(round((fps * 60.0 / max(rpm, 1e-6)) / 6.0)))
        merged: list[int] = []
        for k in idx:
            if merged and k - merged[-1] < min_gap:
                if err[k] < err[merged[-1]]:
                    merged[-1] = k
            else:
                merged.append(k)
        six.append(merged)

    # 半徑一致性（只用實際偵測到的幀）
    med = []
    for t in tracks:
        r = np.array([np.nan if v is None else v for v in t.radii_px], float)
        med.append(float(np.nanmedian(r)) if np.isfinite(r).any() else float("nan"))
    r_out, r_dev = None, None
    if all(np.isfinite(med)) and len(med) == 3:
        m = np.array(med)
        dev = m - np.median(m)
        r_out = int(np.argmax(np.abs(dev)))
        r_dev = float(dev[r_out])

    return DynamicsResult(
        fps=fps, n_frames=n_frames, rpm=rpm, direction=direction, hub_track=hub_track, tracks=tracks,
        six_oclock_frames=six, radius_median_px=med, radius_outlier_index=r_out, radius_deviation_px=r_dev,
        notes=notes,
    )


def analyze_video(path: str, step: int = 1, **kw) -> DynamicsResult:
    fps = video_fps(path) / step
    return analyze_frames(video_frames(path, step), fps, **kw)


def side_view_length_series(frames, fps: float, max_side: int = 960) -> list[float]:
    """除錯/繪圖用：側視每幀向下葉片投影長度。"""
    return [l for l in _side_lengths(frames, max_side)]


def _side_lengths(frames, max_side):
    sky_model = thresh = None
    for frame in frames:
        h, w = frame.shape[:2]
        scale = min(1.0, max_side / max(h, w))
        small = frame if scale >= 1.0 else cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
        if sky_model is None:
            sky_model = fit_sky_model(small)
            thresh = max(_otsu_threshold(sky_distance(small, sky_model)), 4.0)
        mask = segment_turbine(small, sky_model=sky_model, dist_thresh=thresh, full_res=True, max_side=max_side).mask
        yield _down_length_from_mask(mask)[1]

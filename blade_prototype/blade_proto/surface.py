"""表面層（§5.2）：前緣輪廓粗糙度與紋理。

輸入：長焦分區段照（一段葉片橫越畫面）。
1. 分割葉片、PCA 找葉片軸、把影像轉到軸水平
2. 每一欄取上下兩條邊緣，灰階半高交叉做 sub-pixel 精修
3. 對每條邊做低階多項式基線擬合，殘差 = 粗糙度訊號
   - rms、往內凹（材料流失）的 p95、凹坑數、高頻能量比
   - 分三個 zone（沿畫面 x）回報，對應根/中/尖的區段映射
4. 邊緣內側帶狀區域的局部灰階標準差 = 紋理指標

哪一側是前緣由呼叫端指定（top/bottom），演算法對兩側都算。
"""

from __future__ import annotations

from dataclasses import dataclass, asdict

import cv2
import numpy as np

from .segmentation import segment_turbine


@dataclass
class EdgeRoughness:
    edge: str  # 'top' | 'bottom'
    n_samples: int
    rms_px: float
    rms_cm: float | None
    inward_p95_px: float
    pit_count: int
    high_freq_ratio: float
    zone_rms_px: list[float]
    zone_texture_std: list[float]
    baseline_coeffs: list[float]

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class SurfaceAnalysis:
    axis_angle_deg: float
    median_thickness_px: float
    top: EdgeRoughness
    bottom: EdgeRoughness
    leading_edge: str | None

    def to_dict(self) -> dict:
        d = {"axis_angle_deg": self.axis_angle_deg, "median_thickness_px": self.median_thickness_px,
             "leading_edge": self.leading_edge, "top": self.top.to_dict(), "bottom": self.bottom.to_dict()}
        if self.leading_edge in ("top", "bottom"):
            le = self.top if self.leading_edge == "top" else self.bottom
            te = self.bottom if self.leading_edge == "top" else self.top
            d["le_over_te_rms_ratio"] = le.rms_px / max(te.rms_px, 1e-6)
        return d


def _largest_component(mask: np.ndarray) -> np.ndarray:
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if n <= 1:
        return mask
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    return np.where(lab == k, 255, 0).astype(np.uint8)


def _rotate_to_horizontal(gray: np.ndarray, mask: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    ys, xs = np.nonzero(mask)
    pts = np.stack([xs, ys], 1).astype(np.float64)
    c = pts.mean(0)
    _, _, vt = np.linalg.svd(pts - c, full_matrices=False)
    d = vt[0]
    ang = float(np.degrees(np.arctan2(d[1], d[0])))
    if ang > 90:
        ang -= 180
    if ang < -90:
        ang += 180
    h, w = mask.shape
    M = cv2.getRotationMatrix2D((w / 2, h / 2), ang, 1.0)
    g = cv2.warpAffine(gray, M, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    m = cv2.warpAffine(mask, M, (w, h), flags=cv2.INTER_NEAREST, borderValue=0)
    valid = cv2.warpAffine(np.full((h, w), 255, np.uint8), M, (w, h), flags=cv2.INTER_NEAREST, borderValue=0)
    m[valid == 0] = 0
    return g, m, valid, ang


def _subpixel_edge(gray_col: np.ndarray, row: int, direction: int) -> float:
    """在 row 附近沿欄向做半高交叉的 sub-pixel 邊緣位置。

    direction=+1：天空在上、葉片在下（top edge）；-1：葉片在上、天空在下。
    """
    h = len(gray_col)
    if direction > 0:
        sky = gray_col[max(0, row - 7): max(0, row - 3)]
        blade = gray_col[min(h, row + 3): min(h, row + 7)]
    else:
        sky = gray_col[min(h, row + 3): min(h, row + 7)]
        blade = gray_col[max(0, row - 7): max(0, row - 3)]
    if len(sky) == 0 or len(blade) == 0:
        return float(row)
    half = (float(np.median(sky)) + float(np.median(blade))) / 2.0
    lo, hi = max(0, row - 3), min(h - 1, row + 3)
    seg = gray_col[lo: hi + 1].astype(np.float64)
    # 找第一個跨過 half 的相鄰對（沿 direction 從天空側往葉片側）
    idx = range(len(seg) - 1) if direction > 0 else range(len(seg) - 1, 0, -1)
    for i in idx:
        a, b = (seg[i], seg[i + 1]) if direction > 0 else (seg[i], seg[i - 1])
        if (a - half) * (b - half) <= 0 and a != b:
            frac = (half - a) / (b - a)
            return float(lo + i + (frac if direction > 0 else -frac))
    return float(row)


def _edge_profiles(gray: np.ndarray, mask: np.ndarray, valid: np.ndarray, margin: int = 8):
    h, w = mask.shape
    xs, top, bot = [], [], []
    for x in range(w):
        col = mask[:, x]
        rows = np.flatnonzero(col)
        if len(rows) < 4:
            continue
        vrows = np.flatnonzero(valid[:, x])
        if len(vrows) == 0:
            continue
        v0, v1 = int(vrows[0]), int(vrows[-1])
        r0, r1 = int(rows[0]), int(rows[-1])
        if r0 <= v0 + margin or r1 >= v1 - margin:
            continue  # 葉片被畫面（或旋轉後的有效區）上下緣截斷
        g = gray[:, x]
        xs.append(x)
        top.append(_subpixel_edge(g, r0, +1))
        bot.append(_subpixel_edge(g, r1, -1))
    return np.array(xs, float), np.array(top, float), np.array(bot, float)


def _robust_polyfit(x: np.ndarray, y: np.ndarray, deg: int, iters: int = 2) -> tuple[np.ndarray, np.ndarray]:
    xn = (x - x.mean()) / max(np.ptp(x), 1.0) * 2.0
    keep = np.ones(len(x), bool)
    coeffs = np.polyfit(xn, y, deg)
    for _ in range(iters):
        resid = y - np.polyval(coeffs, xn)
        s = 1.4826 * np.median(np.abs(resid[keep] - np.median(resid[keep]))) + 1e-6
        keep = np.abs(resid) < 3.0 * s
        if keep.sum() < deg + 2:
            break
        coeffs = np.polyfit(xn[keep], y[keep], deg)
    return coeffs, y - np.polyval(coeffs, xn)


def _roughness(
    name: str, x: np.ndarray, y: np.ndarray, inward_sign: float, gray: np.ndarray, band_rows: np.ndarray,
    cm_per_px: float | None, poly_deg: int, hf_period_px: float, pit_sigma: float,
) -> EdgeRoughness:
    coeffs, resid = _robust_polyfit(x, y, poly_deg)
    inward = resid * inward_sign
    rms = float(np.sqrt(np.mean(resid**2)))
    sigma = 1.4826 * float(np.median(np.abs(inward - np.median(inward)))) + 1e-6
    hot = inward > pit_sigma * sigma
    # 連續 ≥2 個樣本才算一個凹坑
    pits, run = 0, 0
    for v in hot:
        run = run + 1 if v else 0
        if run == 2:
            pits += 1
    # 高頻能量比：以樣本間距 ≈1 px 估頻率
    spec = np.abs(np.fft.rfft(resid - resid.mean())) ** 2
    freqs = np.fft.rfftfreq(len(resid), d=float(np.median(np.diff(x))) if len(x) > 1 else 1.0)
    total = spec[1:].sum() + 1e-9
    hf = spec[1:][freqs[1:] > 1.0 / hf_period_px].sum()
    # zones
    zone_edges = np.linspace(x.min(), x.max(), 4)
    zone_rms, zone_tex = [], []
    tex = _local_std(gray)
    for i in range(3):
        sel = (x >= zone_edges[i]) & (x <= zone_edges[i + 1])
        zone_rms.append(float(np.sqrt(np.mean(resid[sel] ** 2))) if sel.any() else float("nan"))
        cols = x[sel].astype(int)
        rows = band_rows[sel].astype(int)
        vals = [tex[r, c] for r, c in zip(rows, cols) if 0 <= r < tex.shape[0]]
        zone_tex.append(float(np.mean(vals)) if vals else float("nan"))
    return EdgeRoughness(
        edge=name, n_samples=int(len(x)), rms_px=rms, rms_cm=(rms * cm_per_px if cm_per_px else None),
        inward_p95_px=float(np.percentile(inward, 95)), pit_count=int(pits),
        high_freq_ratio=float(hf / total), zone_rms_px=zone_rms, zone_texture_std=zone_tex,
        baseline_coeffs=[float(c) for c in coeffs],
    )


def _local_std(gray: np.ndarray, k: int = 7) -> np.ndarray:
    g = gray.astype(np.float32)
    m = cv2.blur(g, (k, k))
    m2 = cv2.blur(g * g, (k, k))
    return np.sqrt(np.maximum(m2 - m * m, 0.0))


def analyze_blade_edges(
    img_bgr: np.ndarray,
    mask: np.ndarray | None = None,
    cm_per_px: float | None = None,
    leading_edge: str | None = None,
    poly_deg: int = 3,
    hf_period_px: float = 20.0,
    pit_sigma: float = 2.5,
    band_offset_px: int = 3,
) -> SurfaceAnalysis:
    """分析一張長焦葉片分區段照的兩條邊緣粗糙度。"""
    if mask is None:
        mask = segment_turbine(img_bgr, border_frac=0.05, sky_mode="top_bottom", drop_wide_bands=False).mask
    mask = _largest_component(mask)
    if not mask.any():
        raise ValueError("分割不到葉片（畫面上下緣需為天空；可檢查曝光或改用 --dist-thresh）")
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    g, m, valid, ang = _rotate_to_horizontal(gray, mask)
    xs, top, bot = _edge_profiles(g, m, valid)
    if len(xs) < 20:
        raise ValueError("可用的邊緣樣本太少（葉片被截斷或分割失敗）")
    thickness = float(np.median(bot - top))
    band = max(3, int(0.12 * thickness))
    top_band_rows = np.round(top + band_offset_px + band / 2)
    bot_band_rows = np.round(bot - band_offset_px - band / 2)
    top_r = _roughness("top", xs, top, +1.0, g, top_band_rows, cm_per_px, poly_deg, hf_period_px, pit_sigma)
    bot_r = _roughness("bottom", xs, bot, -1.0, g, bot_band_rows, cm_per_px, poly_deg, hf_period_px, pit_sigma)
    return SurfaceAnalysis(axis_angle_deg=ang, median_thickness_px=thickness, top=top_r, bottom=bot_r,
                           leading_edge=leading_edge)

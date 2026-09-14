"""幾何層（§5.3）：中心線抽取、彎曲係數、三片互比。

每片葉片：
- 以輪轂為原點、修正相機 roll（塔架轉正）
- PCA 主軸 → 葉片座標 (u 沿軸, v 垂直)
- 沿 span 分箱，取兩側邊緣中點為中心線、邊緣差為弦寬
- 對中心線做二次擬合：a2 即「彎曲係數」（PCA 軸吸收了一次項，a2 對軸傾斜不敏感）

三片互比不需要絕對量測與歷史基線：同一台風機三片同批同型，在同一轉子位置的剪影應一致。
"""

from __future__ import annotations

from dataclasses import dataclass, asdict

import numpy as np

from .segmentation import BladeComponent, TurbineStructure


@dataclass
class BladeProfile:
    index: int
    axis_angle_deg: float  # 影像平面方位角（數學慣例，270° = 六點鐘）
    radius_px: float  # 輪轂到葉尖
    u: np.ndarray  # 正規化 span 位置（0–1）
    center: np.ndarray  # 中心線側向偏移 / R
    edge_lo: np.ndarray  # 兩側邊緣 / R
    edge_hi: np.ndarray
    width: np.ndarray  # 弦寬 / R
    bend_coeff: float  # 二次擬合係數（單位 R）
    tip_deflection_px: float  # bend_coeff × R：葉尖相對於直線的偏移
    residual_rms_px: float  # 二次擬合殘差（形狀不規則度）
    mean_width_px: float
    tip_xy: tuple[float, float]
    n_contaminated_bins: int = 0  # 弦寬離群（雲塊/鳥/附著物黏在邊緣）而被修補的分箱數

    def to_dict(self) -> dict:
        d = asdict(self)
        for k in ("u", "center", "edge_lo", "edge_hi", "width"):
            d[k] = [None if np.isnan(v) else round(float(v), 5) for v in d[k]]
        return d


def _rot(deg: float) -> np.ndarray:
    t = np.deg2rad(deg)
    return np.array([[np.cos(t), -np.sin(t)], [np.sin(t), np.cos(t)]])


def _fill_nan(a: np.ndarray) -> np.ndarray:
    a = a.copy()
    bad = np.isnan(a)
    if bad.all():
        return a
    idx = np.arange(len(a))
    a[bad] = np.interp(idx[bad], idx[~bad], a[~bad])
    return a


def _robust_series_fit(t: np.ndarray, y: np.ndarray, deg: int = 3, iters: int = 3):
    """對 y(t) 做多項式擬合並迭代剔除 3σ 離群；回傳 (擬合值, 內點遮罩)。"""
    ok = ~np.isnan(y)
    keep = ok.copy()
    coeffs = np.polyfit(t[keep], y[keep], deg)
    for _ in range(iters):
        fit = np.polyval(coeffs, t)
        resid = y - fit
        sigma = 1.4826 * np.nanmedian(np.abs(resid[keep] - np.nanmedian(resid[keep]))) + 1e-6
        new_keep = ok & (np.abs(resid) < 3.0 * sigma)
        if new_keep.sum() < deg + 2 or np.array_equal(new_keep, keep):
            break
        keep = new_keep
        coeffs = np.polyfit(t[keep], y[keep], deg)
    return np.polyval(coeffs, t), keep


def blade_profile(
    comp: BladeComponent,
    hub: tuple[float, float],
    index: int,
    roll_deg: float = 0.0,
    n_bins: int = 48,
    u_min: float = 0.12,
    u_max: float = 0.98,
) -> BladeProfile:
    """從單一葉片元件像素抽出中心線與邊緣輪廓。"""
    hx, hy = hub
    p = np.stack([comp.xs - hx, comp.ys - hy], 1).astype(np.float64)
    if roll_deg:
        p = p @ _rot(-roll_deg).T  # 把塔架轉正

    # 主軸：用外段像素（避免根部殘留輪轂影響），並指向遠離輪轂
    r = np.hypot(p[:, 0], p[:, 1])
    outer = p[r > 0.25 * r.max()]
    c = outer.mean(0)
    _, _, vt = np.linalg.svd(outer - c, full_matrices=False)
    d = vt[0]
    if np.dot(c, d) < 0:
        d = -d
    n = np.array([d[1], -d[0]])  # 與 synth 的 n 軸同向：方位角 θ 時 n = (-sinθ, -cosθ)
    u = p @ d
    v = p @ n
    R = float(np.percentile(u, 99.8))

    edges = np.linspace(u_min * R, u_max * R, n_bins + 1)
    lo = np.full(n_bins, np.nan)
    hi = np.full(n_bins, np.nan)
    which = np.clip(np.searchsorted(edges, u, side="right") - 1, -1, n_bins)
    for i in range(n_bins):
        sel = which == i
        if sel.sum() >= 2:
            vi = v[sel]
            lo[i] = vi.min()
            hi[i] = vi.max()
    lo, hi = _fill_nan(lo), _fill_nan(hi)
    t = (edges[:-1] + edges[1:]) / 2.0 / R

    # 邊緣修補：雲塊/鳥/附著物黏在葉片一側會讓那幾箱的弦寬暴增、中心線被拉歪。
    # 弦寬沿 span 應平滑（根部定值後線性收斂），用 robust 擬合找離群箱，
    # 再看 lo/hi 哪一側偏離自己的擬合較多，就以擬合值取代那一側。
    width = hi - lo
    n_bad = 0
    if n_bins >= 12:
        _, w_ok = _robust_series_fit(t, width)
        bad = ~w_ok & ~np.isnan(width)
        if bad.any():
            lo_fit, _ = _robust_series_fit(t, lo)
            hi_fit, _ = _robust_series_fit(t, hi)
            for i in np.flatnonzero(bad):
                if abs(lo[i] - lo_fit[i]) > abs(hi[i] - hi_fit[i]):
                    lo[i] = lo_fit[i]
                else:
                    hi[i] = hi_fit[i]
            n_bad = int(bad.sum())
            width = hi - lo
    mid = (lo + hi) / 2.0

    ok = ~np.isnan(mid)
    a2, a1, a0 = np.polyfit(t[ok], mid[ok] / R, 2)
    fit = np.polyval([a2, a1, a0], t)
    resid = (mid / R - fit) * R

    tip_uv = np.array([R, np.polyval([a2, a1, a0], 1.0) * R])
    tip_img = tip_uv[0] * d + tip_uv[1] * n
    if roll_deg:
        tip_img = tip_img @ _rot(roll_deg).T
    tip_xy = (float(hx + tip_img[0]), float(hy + tip_img[1]))

    axis_deg = float(np.degrees(np.arctan2(-d[1], d[0])) % 360.0)
    return BladeProfile(
        index=index, axis_angle_deg=axis_deg, radius_px=R, u=t,
        center=mid / R, edge_lo=lo / R, edge_hi=hi / R, width=width / R,
        bend_coeff=float(a2), tip_deflection_px=float(a2 * R),
        residual_rms_px=float(np.sqrt(np.nanmean(resid**2))),
        mean_width_px=float(np.nanmean(width)), tip_xy=tip_xy, n_contaminated_bins=n_bad,
    )


def profiles_from_structure(st: TurbineStructure, correct_roll: bool = True, **kw) -> list[BladeProfile]:
    roll = st.tower_angle_deg if (correct_roll and st.tower_found) else 0.0
    return [blade_profile(b, st.hub, i, roll_deg=roll, **kw) for i, b in enumerate(st.blades)]


# ---------------------------------------------------------------- 三片互比


@dataclass
class MetricComparison:
    metric: str
    values: list[float]
    deviations: list[float]  # 各片相對三片中位數
    outlier_index: int
    outlier_deviation: float  # px（或 radius 比例）
    others_spread: float  # 另外兩片彼此差
    z: float  # |deviation| / noise_floor
    flagged: bool
    direction: str = "both"  # both / high / low：哪個方向才算缺陷徵兆

    def to_dict(self) -> dict:
        return asdict(self)


def compare_metric(name: str, values: list[float], noise_floor: float, z_thresh: float = 3.0,
                   spread_ratio: float = 2.0, direction: str = "both") -> MetricComparison:
    """三片互比：離群者 = 離中位數最遠者；同時要求它與另外兩片的差距明顯大於另外兩片彼此差。

    direction 決定哪個方向才算缺陷徵兆：
    - "both"（預設）：幾何量（葉尖偏移、弦寬）兩個方向都是異常
    - "high" / "low"：只有偏高（或偏低）才算。例如聲學的寬頻位準與高頻占比——
      比另兩片**低**不是缺陷，若不限方向就會把安靜的那片標成侵蝕。
    NaN 一律不參與（全 NaN 時回傳未標記結果）。
    """
    vals = np.asarray(values, float)
    finite = np.flatnonzero(np.isfinite(vals))
    if len(finite) < 2:
        return MetricComparison(name, [float(x) for x in vals],
                                [float("nan")] * len(vals), int(finite[0]) if len(finite) else 0,
                                float("nan"), float("nan"), float("nan"), False, direction)
    fv = vals[finite]
    med = float(np.median(fv))
    dev = vals - med
    # 有方向性時，離群者就是「最高（或最低）的那片」；沒方向性才用「離中位數最遠」。
    # 兩片往相反方向偏時這個差別是關鍵：high 模式要抓最吵的，不是偏離最多的。
    if direction == "high":
        j = int(np.argmax(fv))
    elif direction == "low":
        j = int(np.argmin(fv))
    else:
        j = int(np.argmax(np.abs(fv - med)))
    k = int(finite[j])
    others = np.delete(fv, j)
    spread = float(np.abs(others[0] - others[1])) if len(others) == 2 else 0.0
    dev_k = float(vals[k] - others.mean()) if len(others) else float(dev[k])
    z = abs(dev_k) / max(noise_floor, 1e-9)
    flagged = bool(z >= z_thresh and abs(dev_k) >= spread_ratio * spread)
    if direction == "high" and dev_k <= 0:
        flagged = False
    elif direction == "low" and dev_k >= 0:
        flagged = False
    return MetricComparison(name, [float(x) for x in vals], [float(x) for x in dev], k,
                            dev_k, spread, float(z), flagged, direction)


def compare_blades(
    profiles: list[BladeProfile],
    noise_floor_px: float = 1.5,
    z_thresh: float = 3.0,
    cm_per_px: float | None = None,
    rotor_radius_m: float | None = None,
) -> dict:
    """比較三片（或多幀同位置）的葉尖偏移、半徑、弦寬。

    noise_floor_px：單片量測雜訊底（由靈敏度分析或現場健康機校準）。
    若給 rotor_radius_m 而未給 cm_per_px，以中位半徑推算尺度。
    """
    if len(profiles) < 2:
        return {"n_blades": len(profiles), "comparisons": [], "note": "少於兩片，無法互比"}
    radii = [p.radius_px for p in profiles]
    if cm_per_px is None and rotor_radius_m:
        cm_per_px = rotor_radius_m * 100.0 / float(np.median(radii))
    comps = [
        compare_metric("tip_deflection_px", [p.tip_deflection_px for p in profiles], noise_floor_px, z_thresh),
        compare_metric("radius_px", radii, noise_floor_px * 2.0, z_thresh),
        compare_metric("mean_width_px", [p.mean_width_px for p in profiles], noise_floor_px, z_thresh),
        compare_metric("residual_rms_px", [p.residual_rms_px for p in profiles], noise_floor_px * 0.5, z_thresh),
    ]
    out = {
        "n_blades": len(profiles),
        "cm_per_px": cm_per_px,
        "comparisons": [c.to_dict() for c in comps],
        "any_flagged": any(c.flagged for c in comps),
    }
    if cm_per_px:
        for c in out["comparisons"]:
            c["outlier_deviation_cm"] = c["outlier_deviation"] * cm_per_px
    return out


def side_view_summary(
    profiles: list[BladeProfile],
    hanging_index: int,
    cm_per_px: float | None = None,
    rotor_radius_m: float | None = None,
) -> dict:
    """側視（`quality.detect_side_view` 判定）：不做三片互比，只回報垂掛葉片的彎曲。

    回傳與 `compare_blades` 同形（`comparisons` 為空、`any_flagged` False），報告與 App 端
    不必另開一條路徑；多出來的 `hanging_blade` 是這張照片唯一的量測。單幀的 tip_deflection
    **含預彎**（SENSITIVITY.md §2），不是缺陷量——要與同一台的基線或另一幀比才有意義，
    所以這裡不設門檻、不標記。
    """
    p = profiles[hanging_index]
    if cm_per_px is None and rotor_radius_m:
        # 垂掛在六點鐘的那片投影長度 ≈ 轉子半徑（sin 90° = 1）；上方那段是另兩片疊在一起，
        # 只有 R·sin(30°)，不能拿來反推尺度。
        cm_per_px = rotor_radius_m * 100.0 / max(float(p.radius_px), 1e-6)
    hb = {
        "index": hanging_index,
        "label": "ABC"[hanging_index] if hanging_index < 3 else str(hanging_index),
        "axis_angle_deg": float(p.axis_angle_deg),
        "radius_px": float(p.radius_px),
        "bend_coeff": float(p.bend_coeff),
        "tip_deflection_px": float(p.tip_deflection_px),
        "residual_rms_px": float(p.residual_rms_px),
        "n_contaminated_bins": int(p.n_contaminated_bins),
    }
    if cm_per_px:
        hb["tip_deflection_cm"] = float(p.tip_deflection_px) * cm_per_px
    return {
        "n_blades": len(profiles),
        "view": "side",
        "cm_per_px": cm_per_px,
        "comparisons": [],
        "any_flagged": False,
        "hanging_blade": hb,
        "note": "側視：三片投影共線，互比不適用；量測項目為垂掛葉片的 flapwise 彎曲"
                "（單幀值含預彎，需與同一台的基線比對）",
    }

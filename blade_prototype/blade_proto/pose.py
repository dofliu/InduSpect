"""相機姿態估計與透視補償（SPEC §13-11，2026-09-16 決策）。

`OFFAXIS_SENSITIVITY.md` 量到的事實：地面拍的正視整機照，三片互比會把**預彎的投影**標成
一到三公尺的假葉尖偏移，z 十幾到四十——雜訊底救不回來，只有知道相機在哪裡才能把它算掉。

這支模組做兩件事：

1. **估姿態**（`estimate_pose`）——
   - 仰角：輪轂高度（資產）− 相機高度，除以到輪轂的直線距離。距離來自 GPS 水平距離，
     或由**尺度**反推：焦距（EXIF 35 mm 等效）× 型錄轉子半徑 ÷ 量到的葉長。
   - yaw：機艙把轉子推到塔軸上風側 overhang 那麼遠，站偏了輪轂就會離開塔軸；
     `hub_x − 塔軸外推到輪轂高度的 x` 除以 overhang 就是 sin(yaw)。overhang 型錄很少寫，
     預設 5 m（3 MW 級 4–6 m）——這一項是**粗估**，誤差跟著 overhang 走。
2. **補償**（`compensate_comparison`）——三片同型，預彎一樣；在已知姿態下，預彎 w 造成的
   in-plane 假彎曲對每一片是一個已知方向、已知比例的量 g_i·w（g_i 由針孔投影算出）。
   三個量到的葉尖偏移 d_i 對一個未知 w 做最小平方，殘差才拿去互比。三片對一個參數，
   還剩兩個自由度給真正的缺陷；順帶得到預彎擬合值（合理範圍 1–6 m，超出就是姿態錯了）。
   半徑也補：平面幾何在該姿態下三片投影半徑的比例是算得出來的，除掉它，再減掉葉尖上風側偏移
   （預彎 + 錐角，用先驗 6 m 不擬合——擬合在 yaw = 0 奇異、對 yaw 誤差極敏感）沿軸的分量；
   |yaw| > 15° 時不補半徑（yaw 是靠 overhang 預設值粗估的，平面比例對它太敏感）。

不可退化的約定：
- 沒有姿態就**不補償**，回原始互比 + 「含透視分量」的措辭；不用預設姿態假裝補過。
- 補償只動 `tip_deflection_px` 與 `radius_px` 兩個量；弦寬與殘差不碰（預彎不影響它們）。
- 原始值一律留在輸出（`*_raw`），報告上看得到補了多少。
- 拍攝閘門仍看**原始**半徑離散——閘門在補償之前，補償只在放行之後做。
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np

from .geometry import BladeProfile, compare_metric

DEFAULT_CAMERA_HEIGHT_M = 1.6
DEFAULT_NACELLE_OVERHANG_M = 5.0
DEFAULT_ROTOR_TILT_DEG = 5.0
FULL_FRAME_WIDTH_MM = 36.0
# 預彎擬合值超出這個範圍就不是預彎，是姿態錯了或有真缺陷——此時不補償
PREBEND_FIT_RANGE_M = (0.0, 8.0)
# 半徑補償用的葉尖上風側總偏移**先驗**（預彎 3 m + 錐角 2.5° × 60 m ≈ 5.6 m）。不擬合：三片對兩個
# 未知在 yaw = 0 時奇異、其他姿態下對 yaw 誤差極敏感（實測 W 在 −7 到 +18 m 之間亂跳）；固定 6 m 的代價是
# ±2 m 的先驗誤差 × 每公尺 2–3 px ≈ 60 cm，低於半徑互比的門檻（3 × 3 px ≈ 110 cm @ 12 cm/px）。
DEFAULT_TIP_OFFSET_M = 6.0
# 半徑補償只在 |yaw| 不大時做：平面比例對 yaw 誤差敏感，而 yaw 是由 overhang 預設值粗估的
# （實測估 26° 對真值 20° 時補償後仍差 232 cm；估 12° 對 10° 時 27 cm）。
RADIUS_COMP_MAX_YAW_DEG = 15.0
# 與六點鐘的夾角在這以內的葉片可能與塔架合併（正視 ±20° 是實測；偏軸時塔軸偏向一側，放寬到 35°）
NEAR_TOWER_DEG = 35.0


@dataclass
class PoseEstimate:
    elevation_deg: float | None
    yaw_deg: float | None
    distance_m: float | None
    rotor_tilt_deg: float = DEFAULT_ROTOR_TILT_DEG
    elevation_method: str | None = None  # 'horizontal' | 'focal' | None
    yaw_method: str | None = None  # 'tower_offset' | None
    hub_offset_m: float | None = None  # 塔軸 − 輪轂（公尺，+ = 塔軸在輪轂右側）
    notes: list[str] = field(default_factory=list)

    @property
    def usable(self) -> bool:
        return self.elevation_deg is not None and self.yaw_deg is not None and self.distance_m is not None

    def to_dict(self) -> dict:
        d = asdict(self)
        d["usable"] = self.usable
        return d


# ---------------------------------------------------------------- 單項估計


def focal_px_from_35mm(focal_35mm: float, long_side_px: int) -> float:
    """35 mm 等效焦距 → 像素焦距：全片幅寬 36 mm 對應畫面長邊。"""
    return float(focal_35mm) / FULL_FRAME_WIDTH_MM * float(long_side_px)


def distance_from_scale(rotor_radius_m: float, rotor_radius_px: float, focal_px: float) -> float | None:
    """針孔：D = f_px × R_m / R_px。半徑或焦距不是正數就 None。"""
    if not (rotor_radius_m > 0 and rotor_radius_px > 0 and focal_px > 0):
        return None
    return float(focal_px) * float(rotor_radius_m) / float(rotor_radius_px)


def elevation_from_slant(hub_height_m: float, distance_m: float,
                         camera_height_m: float = DEFAULT_CAMERA_HEIGHT_M) -> float | None:
    dh = float(hub_height_m) - float(camera_height_m)
    if dh <= 0 or distance_m is None or distance_m <= dh:
        return None
    return float(np.degrees(np.arcsin(dh / float(distance_m))))


def elevation_from_horizontal(hub_height_m: float, horizontal_m: float,
                              camera_height_m: float = DEFAULT_CAMERA_HEIGHT_M) -> tuple[float, float] | None:
    dh = float(hub_height_m) - float(camera_height_m)
    if dh <= 0 or horizontal_m is None or horizontal_m <= 0:
        return None
    return float(np.degrees(np.arctan2(dh, float(horizontal_m)))), float(np.hypot(horizontal_m, dh))


def yaw_from_hub_offset(offset_m: float, overhang_m: float = DEFAULT_NACELLE_OVERHANG_M) -> float | None:
    """塔軸相對輪轂的水平偏移（公尺，+ = 塔軸在輪轂右側）→ yaw（+ = 相機在轉子 +x 側）。

    投影：塔頂在輪轂後方 overhang 處，站偏 yaw 時它在畫面上離輪轂 ≈ overhang·sin(yaw)。
    |offset| > overhang 在幾何上不可能，夾到 ±90° 並留註記。"""
    if overhang_m is None or overhang_m <= 0:
        return None
    r = float(np.clip(float(offset_m) / float(overhang_m), -1.0, 1.0))
    return float(np.degrees(np.arcsin(r)))


def estimate_pose(
    structure,
    *,
    hub_height_m: float | None,
    rotor_radius_m: float | None,
    image_long_side_px: int | None = None,
    focal_35mm: float | None = None,
    horizontal_distance_m: float | None = None,
    camera_height_m: float = DEFAULT_CAMERA_HEIGHT_M,
    overhang_m: float = DEFAULT_NACELLE_OVERHANG_M,
    rotor_tilt_deg: float = DEFAULT_ROTOR_TILT_DEG,
    cm_per_px: float | None = None,
) -> PoseEstimate:
    """從結構定位結果 + 資產參數 + 焦距／距離估相機姿態。缺什麼就哪一項 None，**不猜**。"""
    notes: list[str] = []
    radii = [float(b.tip_radius_px) for b in getattr(structure, "blades", [])]
    r_px = float(np.median(radii)) if radii else 0.0
    scale = cm_per_px
    if scale is None and rotor_radius_m and r_px > 0:
        scale = float(rotor_radius_m) * 100.0 / r_px

    el = dist = None
    el_method = None
    if hub_height_m is None or hub_height_m <= 0:
        notes.append("沒有輪轂高度，無法估仰角")
    elif horizontal_distance_m:
        got = elevation_from_horizontal(hub_height_m, horizontal_distance_m, camera_height_m)
        if got is not None:
            el, dist = got
            el_method = "horizontal"
    elif focal_35mm and image_long_side_px and rotor_radius_m and r_px > 0:
        f_px = focal_px_from_35mm(focal_35mm, image_long_side_px)
        dist = distance_from_scale(rotor_radius_m, r_px, f_px)
        el = elevation_from_slant(hub_height_m, dist, camera_height_m) if dist else None
        if el is None:
            notes.append("由焦距反推的距離小於輪轂高度差，姿態不成立（焦距或型錄半徑可能不對）")
            dist = None
        else:
            el_method = "focal"
    else:
        notes.append("沒有 GPS 水平距離也沒有 35 mm 等效焦距，無法估仰角")

    yaw = None
    yaw_method = None
    offset_m = None
    tower_x = getattr(structure, "tower_x_at_hub_px", None)
    if tower_x is None or not getattr(structure, "tower_found", False):
        notes.append("沒有塔架軸，無法估 yaw")
    elif scale is None:
        notes.append("沒有尺度（型錄轉子直徑），無法把塔軸偏移換成公尺")
    else:
        offset_m = (float(tower_x) - float(structure.hub[0])) * scale / 100.0
        yaw = yaw_from_hub_offset(offset_m, overhang_m)
        yaw_method = "tower_offset"
        if abs(offset_m) > overhang_m:
            notes.append(f"塔軸偏移 {offset_m:.1f} m 超過機艙 overhang {overhang_m:.1f} m，yaw 夾在 ±90°——"
                         "overhang 預設值可能不合這台機型")
        else:
            notes.append(f"yaw 由塔軸偏移 {offset_m:+.2f} m ÷ overhang {overhang_m:.1f} m（預設值，粗估）")
    return PoseEstimate(elevation_deg=el, yaw_deg=yaw, distance_m=dist, rotor_tilt_deg=rotor_tilt_deg,
                        elevation_method=el_method, yaw_method=yaw_method, hub_offset_m=offset_m, notes=notes)


# ---------------------------------------------------------------- 針孔投影（與 synth.render_perspective 同一套幾何，獨立實作）


def _camera_axes(elevation_deg: float, yaw_deg: float) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    yaw, el = np.deg2rad(yaw_deg), np.deg2rad(elevation_deg)
    c_dir = np.array([np.sin(yaw) * np.cos(el), -np.sin(el), np.cos(yaw) * np.cos(el)])
    f = -c_dir
    r = np.cross(f, np.array([0.0, 1.0, 0.0]))
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return c_dir, f, r, u


def _rotor_point(u_m: float, w_m: float, azimuth_deg: float, tilt_deg: float) -> np.ndarray:
    t = np.deg2rad(tilt_deg)
    e1 = np.array([1.0, 0.0, 0.0])
    e2 = np.array([0.0, np.cos(t), -np.sin(t)])
    a = np.array([0.0, np.sin(t), np.cos(t)])
    az = np.deg2rad(azimuth_deg)
    d = np.cos(az) * e1 + np.sin(az) * e2
    return u_m * d + w_m * a


def project_rotor_points(points_m: np.ndarray, pose: PoseEstimate, px_per_m: float) -> np.ndarray:
    """轉子座標（公尺，輪轂為原點）→ 相對輪轂影像位置（px，y 向下）。焦距 = D × px_per_m。"""
    c_dir, f, r, u = _camera_axes(pose.elevation_deg, pose.yaw_deg)
    D = float(pose.distance_m)
    q = np.asarray(points_m, float) - (D * c_dir)[None, :]
    depth = q @ f
    f_px = D * px_per_m
    return np.stack([f_px * (q @ r) / depth, -f_px * (q @ u) / depth], 1)


def deflection_basis(axis_angles_deg: list[float], rotor_radius_m: float, pose: PoseEstimate,
                     px_per_m: float) -> list[float]:
    """每片：葉尖有 1 m 上風側預彎時，畫面上垂直葉片軸的位移（px）。

    `blade_profile` 的葉尖偏移是二次項 × R；預彎是 t²，所以 t = 1 處的垂直位移就是它。
    垂直方向 n 與 `blade_profile` 同一個慣例：軸向 d = (cos φ, −sin φ)，n = (−sin φ, −cos φ)。"""
    out = []
    for phi in axis_angles_deg:
        p0 = _rotor_point(rotor_radius_m, 0.0, phi, pose.rotor_tilt_deg)
        p1 = _rotor_point(rotor_radius_m, 1.0, phi, pose.rotor_tilt_deg)
        xy = project_rotor_points(np.stack([p0, p1]), pose, px_per_m)
        d_img = xy[1] - xy[0]
        n = np.array([-np.sin(np.deg2rad(phi)), -np.cos(np.deg2rad(phi))])
        out.append(float(d_img @ n))
    return out


def radius_ratios(axis_angles_deg: list[float], rotor_radius_m: float, pose: PoseEstimate,
                  px_per_m: float) -> list[float]:
    """平面葉片在該姿態下各片投影半徑對中位數的比例（純透視的半徑差）。"""
    rs = []
    for phi in axis_angles_deg:
        xy = project_rotor_points(_rotor_point(rotor_radius_m, 0.0, phi, pose.rotor_tilt_deg)[None, :], pose, px_per_m)
        rs.append(float(np.hypot(*xy[0])))
    med = float(np.median(rs)) if rs else 1.0
    return [r / med for r in rs]


def _loo_pairs(n: int):
    return [([i for i in range(n) if i != k], k) for k in range(n)]


def fit_prebend(deflections_px: list[float], basis_px_per_m: list[float]) -> tuple[float, list[float], int]:
    """d_i = w·g_i + ε_i，**留一法**：對每一片 k 用另兩片擬合 w、算 k 的殘差；殘差最大的那片
    當離群候選，w 取「另兩片」的擬合值。回 (w_m, 全部三片對該 w 的殘差, k)。

    為什麼不用三片一起最小平方：三片對一個參數，一片真的偏了會把 w 拉走三分之一以上，
    殘差被吃掉一半（實測 400 cm 的注入只剩 124 cm、w 變負）。假設「最多一片有問題」，
    用另兩片定 w 才把缺陷留在殘差裡。"""
    d = np.asarray(deflections_px, float)
    g = np.asarray(basis_px_per_m, float)
    n = len(d)
    if n < 3 or not (np.isfinite(d).all() and np.isfinite(g).all()):
        gg = float(np.sum(g ** 2))
        w = float(np.sum(d * g) / gg) if gg > 1e-9 else 0.0
        return w, [float(x) for x in (d - w * g)], -1
    best = None
    for others, k in _loo_pairs(n):
        gg = float(np.sum(g[others] ** 2))
        w_k = float(np.sum(d[others] * g[others]) / gg) if gg > 1e-9 else 0.0
        resid_k = float(d[k] - w_k * g[k])
        if best is None or abs(resid_k) > abs(best[1]):
            best = (w_k, resid_k, k)
    w, _, k = best
    return w, [float(x) for x in (d - w * g)], k


def radial_basis(axis_angles_deg: list[float], rotor_radius_m: float, pose: PoseEstimate,
                 px_per_m: float) -> tuple[list[float], list[float]]:
    """每片：(平面投影半徑對中位數的比例, 葉尖 1 m 上風側偏移沿葉片軸的位移 px)。

    半徑看到的不只平面透視：預彎 + 錐角把葉尖推向上風側 W 公尺，三片葉尖在畫面上**共同**
    位移一個向量，沿各片軸的分量就是半徵的假差。W 是未知（型錄不寫），一起擬合。"""
    ratios, along = [], []
    rs = []
    for phi in axis_angles_deg:
        p0 = _rotor_point(rotor_radius_m, 0.0, phi, pose.rotor_tilt_deg)
        p1 = _rotor_point(rotor_radius_m, 1.0, phi, pose.rotor_tilt_deg)
        xy = project_rotor_points(np.stack([p0, p1]), pose, px_per_m)
        rs.append(float(np.hypot(*xy[0])))
        d_img = np.array([np.cos(np.deg2rad(phi)), -np.sin(np.deg2rad(phi))])
        along.append(float((xy[1] - xy[0]) @ d_img))
    med = float(np.median(rs)) if rs else 1.0
    return [r / med for r in rs], along


def compensate_comparison(profiles: list[BladeProfile], pose: PoseEstimate, rotor_radius_m: float,
                          noise_floor_px: float = 1.5, z_thresh: float = 3.0,
                          cm_per_px: float | None = None,
                          tip_offset_m: float = DEFAULT_TIP_OFFSET_M) -> dict | None:
    """在已知姿態下重做葉尖偏移與半徑的三片互比。姿態不可用 → None（呼叫端保留原始互比）。

    葉尖偏移：預彎 w 由留一法擬合（`fit_prebend`），擬合值超出合理範圍就不補、留原值並註記。
    半徑：除掉平面透視比例、減掉葉尖上風側偏移先驗（`tip_offset_m`）沿軸的分量；|yaw| 太大不補。
    兩者的原始值都留在輸出，報告上看得到補了多少。"""
    if not pose.usable or len(profiles) != 3 or not rotor_radius_m:
        return None
    radii = [float(p.radius_px) for p in profiles]
    r_px = float(np.median(radii))
    px_per_m = r_px / float(rotor_radius_m)
    scale = cm_per_px if cm_per_px is not None else 100.0 / px_per_m
    axes = [float(p.axis_angle_deg) for p in profiles]
    raw_defl = [float(p.tip_deflection_px) for p in profiles]
    basis = deflection_basis(axes, rotor_radius_m, pose, px_per_m)
    w, resid, k_defl = fit_prebend(raw_defl, basis)
    lo, hi = PREBEND_FIT_RANGE_M
    ok_fit = lo <= w <= hi
    ratios, along = radial_basis(axes, rotor_radius_m, pose, px_per_m)
    ok_rad = abs(float(pose.yaw_deg)) <= RADIUS_COMP_MAX_YAW_DEG
    radii_corr = [(r - h * tip_offset_m) / q for r, q, h in zip(radii, ratios, along)]
    comps = [
        compare_metric("tip_deflection_px", resid if ok_fit else raw_defl, noise_floor_px, z_thresh),
        compare_metric("radius_px", radii_corr if ok_rad else radii, noise_floor_px * 2.0, z_thresh),
    ]
    out = {
        "pose": pose.to_dict(),
        "prebend_fit_m": w,
        "prebend_fit_ok": ok_fit,
        "deflection_compensated": ok_fit,
        "tip_offset_prior_m": tip_offset_m,
        "radius_compensated": ok_rad,
        "deflection_basis_px_per_m": basis,
        "radius_ratios": ratios,
        "radius_along_px_per_m": along,
        "tip_deflection_raw_px": raw_defl,
        "tip_deflection_compensated_px": resid,
        "radius_raw_px": radii,
        "radius_compensated_px": radii_corr,
        "comparisons": [c.to_dict() for c in comps],
        "any_flagged": any(c.flagged for c in comps),
        "cm_per_px": scale,
    }
    for c in out["comparisons"]:
        c["outlier_deviation_cm"] = c["outlier_deviation"] * scale
    # 接近六點鐘的葉片會與塔架／機艙合併，中心線被拉歪成假彎曲（README 已知限制：±20°；
    # 偏軸時塔軸在畫面上偏向一側，容忍範圍要放寬）。補償模型算不掉這個，只能點名。
    near_tower = [i for i, a in enumerate(axes) if abs(((a - 270.0) + 180.0) % 360.0 - 180.0) <= NEAR_TOWER_DEG]
    out["blades_near_tower"] = near_tower
    notes = []
    if near_tower:
        labels = "、".join("ABC"[i] if i < 3 else str(i) for i in near_tower)
        notes.append(f"葉片 {labels} 距六點鐘 ≤ {NEAR_TOWER_DEG:.0f}°，可能與塔架合併而使中心線被拉歪；"
                     "該片的葉尖偏移不可靠，請等轉子轉開再拍")
    if not ok_fit:
        notes.append(f"預彎擬合 {w:.1f} m 超出 {lo}–{hi} m：姿態可能不對或有真缺陷，葉尖偏移未補償")
    if not ok_rad:
        notes.append(f"|yaw| {abs(pose.yaw_deg):.0f}° 超過 {RADIUS_COMP_MAX_YAW_DEG:.0f}°，半徑的平面比例對 yaw 誤差太敏感：半徑未補償")
    if notes:
        out["note"] = "；".join(notes)
    return out

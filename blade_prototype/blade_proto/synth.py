"""合成風機影像產生器。

用途：
1. 單元測試夾具（已知 ground truth）。
2. 靈敏度分析：在指定 cm/px 尺度下，多大的葉尖偏移 / 前緣侵蝕能被演算法分辨。

座標慣例：影像 x 向右、y 向下。方位角 azimuth 採數學慣例（逆時針、0° 指向右、
90° 指向上），因此 270° 為六點鐘方向。

所有幾何都以公尺定義、再用 cm_per_px 換成像素，讓「同一台風機在不同倍率/距離下
拍起來長怎樣」可以直接用一個參數控制。
"""

from __future__ import annotations

import contextlib
import wave
from dataclasses import dataclass, field, replace
from typing import Iterator

import cv2
import numpy as np

_SHIFT = 4  # fillPoly 定點小數位數（sub-pixel 邊緣）


@dataclass
class SceneSpec:
    """一台風機 + 相機尺度的完整描述。"""

    width: int = 1200
    height: int = 1600
    cm_per_px: float = 12.0  # 預設讓 60 m 葉片（500 px）完整入鏡；實機尺度請用 for_scale()
    hub_frac: tuple[float, float] = (0.5, 0.42)  # 輪轂在畫面中的相對位置
    rotor_radius_m: float = 60.0
    hub_radius_m: float = 2.0
    tower_top_diameter_m: float = 3.0
    tower_base_diameter_m: float = 4.5
    nacelle_length_m: float = 12.0
    nacelle_height_m: float = 4.0
    root_chord_m: float = 4.0
    tip_chord_m: float = 1.0
    prebend_m: float = 2.0  # 側視：葉尖預彎（離塔方向）
    azimuth_deg: float = 90.0  # 葉片 A 方位角（正視）
    # 每片額外葉尖側向偏移（葉片座標垂直軸向，公分；正視為 in-plane，側視為 flapwise）
    tip_deflection_cm: tuple[float, float, float] = (0.0, 0.0, 0.0)
    # 前緣侵蝕：blade_idx -> (amplitude_cm, start_frac, end_frac)
    erosion: dict = field(default_factory=dict)
    sky_top: tuple[int, int, int] = (200, 150, 90)  # BGR 藍天
    sky_bottom: tuple[int, int, int] = (235, 220, 200)
    cloud_strength: float = 0.15
    blade_gray: int = 236
    tower_gray: int = 215
    blur_sigma: float = 0.9
    noise_sigma: float = 2.5
    seed: int = 0
    sky_seed: int | None = None  # 雲層圖樣的 seed；影片各幀共用同一片天空時設定（None = 用 seed）

    @property
    def px_per_m(self) -> float:
        return 100.0 / self.cm_per_px

    @property
    def hub_xy(self) -> tuple[float, float]:
        return (self.width * self.hub_frac[0], self.height * self.hub_frac[1])

    @property
    def rotor_radius_px(self) -> float:
        return self.rotor_radius_m * self.px_per_m

    def rotor_fits(self, view: str = "front", margin: float = 0.06) -> bool:
        """整個轉子（正視）或垂掛葉片 + 輪轂（側視）是否落在畫面內。"""
        hx, hy = self.hub_xy
        R = self.rotor_radius_px
        m = margin * min(self.width, self.height)
        if view == "front":
            return (hx - R >= m and hx + R <= self.width - m and hy - R >= m and hy + R <= self.height - m)
        return hy + R <= self.height - m and hy - 0.3 * R >= m

    @classmethod
    def for_scale(cls, cm_per_px: float, view: str = "front", sensor_px: tuple[int, int] = (4000, 3000), **kw) -> "SceneSpec":
        """依實機感光元件像素數與尺度建立場景。

        正視用橫幅（轉子要橫著塞進畫面），側視用直幅（葉片垂掛）。
        若轉子在此尺度下塞不進畫面會 raise，避免產生截斷葉片的假象。
        """
        long_side, short_side = max(sensor_px), min(sensor_px)
        if view == "front":
            spec = cls(width=long_side, height=short_side, cm_per_px=cm_per_px, hub_frac=(0.5, 0.5), **kw)
        else:
            kw.setdefault("azimuth_deg", 270.0)
            spec = cls(width=short_side, height=long_side, cm_per_px=cm_per_px, hub_frac=(0.5, 0.25), **kw)
        if not spec.rotor_fits(view):
            raise ValueError(
                f"{cm_per_px} cm/px 下 {view} 視角的轉子塞不進 {sensor_px} 畫面"
                f"（葉片 {spec.rotor_radius_px:.0f} px）；請用較大的 cm_per_px 或更高像素感光元件")
        return spec


# ---------------------------------------------------------------- 基本繪圖


def _poly(img: np.ndarray, pts: np.ndarray, color) -> None:
    p = np.round(np.asarray(pts, dtype=np.float64) * (1 << _SHIFT)).astype(np.int32)
    cv2.fillPoly(img, [p.reshape(-1, 1, 2)], color, lineType=cv2.LINE_AA, shift=_SHIFT)


def _circle(img: np.ndarray, center, radius: float, color) -> None:
    c = tuple(int(round(v * (1 << _SHIFT))) for v in center)
    cv2.circle(img, c, int(round(radius * (1 << _SHIFT))), color, -1, lineType=cv2.LINE_AA, shift=_SHIFT)


def render_sky(spec: SceneSpec, rng: np.random.Generator) -> np.ndarray:
    """垂直漸層 + 低頻雲層雜訊。sky_seed 有設定時雲層用獨立的 rng（影片各幀天空一致）。"""
    if spec.sky_seed is not None:
        rng = np.random.default_rng(spec.sky_seed)
    h, w = spec.height, spec.width
    t = np.linspace(0.0, 1.0, h, dtype=np.float32)[:, None, None]
    top = np.array(spec.sky_top, dtype=np.float32)[None, None, :]
    bot = np.array(spec.sky_bottom, dtype=np.float32)[None, None, :]
    sky = top * (1 - t) + bot * t
    sky = np.broadcast_to(sky, (h, w, 3)).copy()
    if spec.cloud_strength > 0:
        low = rng.standard_normal((max(4, h // 160), max(4, w // 160))).astype(np.float32)
        cloud = cv2.resize(low, (w, h), interpolation=cv2.INTER_CUBIC)
        cloud = cv2.GaussianBlur(cloud, (0, 0), max(1.0, min(h, w) / 40))
        cloud = (cloud - cloud.min()) / (np.ptp(cloud) + 1e-6)  # 0–1
        sky = sky * (1 - spec.cloud_strength) + spec.cloud_strength * (sky * 0.4 + 255 * 0.6) * cloud[..., None] \
            + spec.cloud_strength * sky * (1 - cloud[..., None])
    return np.clip(sky, 0, 255)


def _finish(img: np.ndarray, spec: SceneSpec, rng: np.random.Generator) -> np.ndarray:
    if spec.blur_sigma > 0:
        img = cv2.GaussianBlur(img, (0, 0), spec.blur_sigma)
    if spec.noise_sigma > 0:
        img = img + rng.normal(0.0, spec.noise_sigma, img.shape).astype(np.float32)
    return np.clip(img, 0, 255).astype(np.uint8)


def _dir_vectors(azimuth_deg: float) -> tuple[np.ndarray, np.ndarray]:
    """回傳 (沿葉片軸方向 d, 垂直方向 n)，皆為影像座標單位向量。"""
    th = np.deg2rad(azimuth_deg)
    d = np.array([np.cos(th), -np.sin(th)])
    n = np.array([-np.sin(th), -np.cos(th)])
    return d, n


# ---------------------------------------------------------------- 葉片輪廓


def blade_outline(
    spec: SceneSpec,
    deflection_px: float,
    erosion: tuple[float, float, float] | None,
    rng: np.random.Generator,
    n: int = 300,
    thickness_scale: float = 1.0,
) -> np.ndarray:
    """葉片座標系的封閉輪廓 (u 沿軸、v 垂直)。

    - 弦長：根部 0–20% 固定，之後線性收斂到葉尖
    - 中心線：二次彎曲，葉尖偏移 = deflection_px
    - 侵蝕：前緣（v 較大側）往內縮的平滑隨機凹坑，只作用在 [start, end] span 區間
    - thickness_scale：側視時葉片看到的是厚度方向，用 <1 的比例縮小
    """
    R = spec.rotor_radius_px
    u = np.linspace(0.0, R, n)
    t = u / R
    root = spec.root_chord_m * spec.px_per_m * thickness_scale
    tip = spec.tip_chord_m * spec.px_per_m * thickness_scale
    chord = np.where(t < 0.2, root, root + (tip - root) * (t - 0.2) / 0.8)
    v_c = deflection_px * t**2
    le = v_c + chord / 2
    te = v_c - chord / 2
    if erosion is not None:
        amp_cm, s, e = erosion
        amp = amp_cm / spec.cm_per_px
        band = ((t >= s) & (t <= e)).astype(np.float64)
        noise = rng.standard_normal(n).astype(np.float32)
        noise = cv2.GaussianBlur(noise.reshape(1, -1), (0, 0), 1.2).ravel().astype(np.float64)
        pits = np.clip(noise, 0, None)
        pits = pits / (pits.max() + 1e-9) * amp
        le = le - pits * band  # 材料流失 → 前緣往內縮
    pts = np.concatenate([np.stack([u, le], 1), np.stack([u[::-1], te[::-1]], 1)])
    return pts


def _to_image(pts_uv: np.ndarray, origin, azimuth_deg: float) -> np.ndarray:
    d, n = _dir_vectors(azimuth_deg)
    return np.asarray(origin)[None, :] + pts_uv[:, :1] * d[None, :] + pts_uv[:, 1:] * n[None, :]


# ---------------------------------------------------------------- 場景


def render_front(spec: SceneSpec) -> tuple[np.ndarray, dict]:
    """正視（相機在轉子軸線上）：三片葉片 120° 分佈、塔架在輪轂正下方。"""
    rng = np.random.default_rng(spec.seed)
    img = render_sky(spec, rng)
    mask = np.zeros((spec.height, spec.width), np.uint8)
    hx, hy = spec.hub_xy
    ppm = spec.px_per_m
    R = spec.rotor_radius_px

    # 塔架（上窄下寬）
    top_w = spec.tower_top_diameter_m * ppm
    base_w = spec.tower_base_diameter_m * ppm
    tower = np.array([
        [hx - top_w / 2, hy], [hx + top_w / 2, hy],
        [hx + base_w / 2, spec.height + 2], [hx - base_w / 2, spec.height + 2],
    ])
    _poly(img, tower, (spec.tower_gray,) * 3)
    _poly(mask, tower, 255)

    azimuths, tips, defl_px = [], [], []
    for i in range(3):
        az = spec.azimuth_deg + 120.0 * i
        dpx = spec.tip_deflection_cm[i] / spec.cm_per_px
        pts = blade_outline(spec, dpx, spec.erosion.get(i), rng)
        xy = _to_image(pts, (hx, hy), az)
        _poly(img, xy, (spec.blade_gray,) * 3)
        _poly(mask, xy, 255)
        d, n = _dir_vectors(az)
        tips.append(tuple(np.array([hx, hy]) + R * d + dpx * n))
        azimuths.append(az % 360.0)
        defl_px.append(dpx)

    hub_r = spec.hub_radius_m * ppm
    _circle(img, (hx, hy), hub_r, (spec.blade_gray,) * 3)
    _circle(mask, (hx, hy), hub_r, 255)

    truth = {
        "view": "front",
        "hub": (hx, hy),
        "hub_radius_px": hub_r,
        "rotor_radius_px": R,
        "cm_per_px": spec.cm_per_px,
        "azimuths_deg": azimuths,
        "tips": tips,
        "tip_deflection_px": defl_px,
        "mask": mask,
    }
    return _finish(img, spec, rng), truth


def render_side(spec: SceneSpec) -> tuple[np.ndarray, dict]:
    """側視（相機垂直轉子面）：轉子面投影成一條垂直線。

    方位角 az 的葉片，葉尖在轉子面上的座標為 (R cos az, R sin az)；側視只看得到垂直分量，
    所以每片投影成長度 R·|sin az| 的垂直條，向上（sin>0）或向下（sin<0）。
    預彎與 flapwise 偏移是轉子面外的位移，在側視裡是 +x 方向的 t² 曲線（轉子在機艙 +x 側）。
    spec.azimuth_deg 為葉片 A 的方位角；270° = A 垂掛在六點鐘。
    tip_deflection_cm[i] 為第 i 片的額外 flapwise 偏移。
    """
    rng = np.random.default_rng(spec.seed)
    img = render_sky(spec, rng)
    mask = np.zeros((spec.height, spec.width), np.uint8)
    hx, hy = spec.hub_xy
    ppm = spec.px_per_m
    R = spec.rotor_radius_px
    nac_l = spec.nacelle_length_m * ppm
    nac_h = spec.nacelle_height_m * ppm
    tower_cx = hx - nac_l / 2

    top_w = spec.tower_top_diameter_m * ppm
    base_w = spec.tower_base_diameter_m * ppm
    tower = np.array([
        [tower_cx - top_w / 2, hy], [tower_cx + top_w / 2, hy],
        [tower_cx + base_w / 2, spec.height + 2], [tower_cx - base_w / 2, spec.height + 2],
    ])
    _poly(img, tower, (spec.tower_gray,) * 3)
    _poly(mask, tower, 255)

    nacelle = np.array([
        [hx - nac_l, hy - nac_h / 2], [hx, hy - nac_h / 2], [hx, hy + nac_h / 2], [hx - nac_l, hy + nac_h / 2],
    ])
    _poly(img, nacelle, (spec.tower_gray,) * 3)
    _poly(mask, nacelle, 255)

    prebend_px = spec.prebend_m * ppm
    blades = []
    for i in range(3):
        az = (spec.azimuth_deg + 120.0 * i) % 360.0
        s = np.sin(np.deg2rad(az))
        length = R * abs(s)
        dpx = spec.tip_deflection_cm[i] / spec.cm_per_px
        if length < 2.0:
            blades.append({"azimuth_deg": az, "projected_length_px": length, "tip": (hx, hy)})
            continue
        # 用葉片座標畫：u 沿投影方向（上或下），v = +x 為 flapwise 方向
        # blade_outline 的 v_c = deflection × t²，t = u/R；投影長度不是 R，所以用縮放後的 spec
        sub = replace(spec, rotor_radius_m=spec.rotor_radius_m * abs(s))
        pts = blade_outline(sub, prebend_px + dpx, spec.erosion.get(i), rng, thickness_scale=0.35)
        direction = 90.0 if s > 0 else 270.0
        # _to_image 的 n 軸：方位角 90° 時 n = (-1, 0)，270° 時 n = (1, 0)；統一讓偏移朝 +x
        if s > 0:
            pts[:, 1] = -pts[:, 1]
        xy = _to_image(pts, (hx, hy), direction)
        _poly(img, xy, (spec.blade_gray,) * 3)
        _poly(mask, xy, 255)
        tip = (hx + prebend_px + dpx, hy - length if s > 0 else hy + length)
        blades.append({"azimuth_deg": az, "projected_length_px": length, "tip": tip})

    hub_r = spec.hub_radius_m * ppm
    _circle(img, (hx, hy), hub_r, (spec.blade_gray,) * 3)
    _circle(mask, (hx, hy), hub_r, 255)

    hanging = min(range(3), key=lambda i: abs(((blades[i]["azimuth_deg"] - 270.0) + 180) % 360 - 180))
    truth = {
        "view": "side",
        "hub": (hx, hy),
        "hub_radius_px": hub_r,
        "rotor_radius_px": R,
        "cm_per_px": spec.cm_per_px,
        "tower_center_x": tower_cx,
        "azimuths_deg": [b["azimuth_deg"] for b in blades],
        "projected_lengths_px": [b["projected_length_px"] for b in blades],
        "blades": blades,
        "hanging_index": hanging,
        "hanging_tip": blades[hanging]["tip"],
        "prebend_px": prebend_px,
        "tip_deflection_px": spec.tip_deflection_cm[hanging] / spec.cm_per_px,
        "mask": mask,
    }
    return _finish(img, spec, rng), truth


def render_blade_segment(
    width: int = 1600,
    height: int = 900,
    cm_per_px: float = 0.4,
    chord_m: float = 2.0,
    tilt_deg: float = 4.0,
    erosion_amp_cm: float = 0.0,
    erosion_span: tuple[float, float] = (0.4, 1.0),
    pit_scale_px: float = 3.0,
    blade_gray: int = 236,
    blur_sigma: float = 0.9,
    noise_sigma: float = 2.5,
    seed: int = 0,
) -> tuple[np.ndarray, dict]:
    """長焦分區段照：一段葉片橫越畫面，前緣在上方。用於前緣粗糙度演算法測試。"""
    rng = np.random.default_rng(seed)
    spec = SceneSpec(width=width, height=height, cm_per_px=cm_per_px, seed=seed,
                     blur_sigma=blur_sigma, noise_sigma=noise_sigma)
    img = render_sky(spec, rng)
    mask = np.zeros((height, width), np.uint8)
    chord_px = chord_m * 100.0 / cm_per_px
    n = width + 200
    x = np.linspace(-100, width + 100, n)
    cy = height * 0.55 + np.tan(np.deg2rad(tilt_deg)) * (x - width / 2)
    top = cy - chord_px / 2
    bot = cy + chord_px / 2
    if erosion_amp_cm > 0:
        amp = erosion_amp_cm / cm_per_px
        s, e = erosion_span
        band = ((x >= s * width) & (x <= e * width)).astype(np.float64)
        noise = rng.standard_normal(n).astype(np.float32)
        noise = cv2.GaussianBlur(noise.reshape(1, -1), (0, 0), pit_scale_px).ravel().astype(np.float64)
        pits = np.clip(noise, 0, None)
        pits = pits / (pits.max() + 1e-9) * amp
        top = top + pits * band  # 前緣在上，材料流失 → 邊往下（往內）
    pts = np.concatenate([np.stack([x, top], 1), np.stack([x[::-1], bot[::-1]], 1)])
    _poly(img, pts, (blade_gray,) * 3)
    _poly(mask, pts, 255)
    truth = {"cm_per_px": cm_per_px, "chord_px": chord_px, "erosion_amp_px": erosion_amp_cm / cm_per_px,
             "leading_edge": "top", "mask": mask}
    return _finish(img, spec, rng), truth


def render_video_frames(
    spec: SceneSpec,
    n_frames: int,
    fps: float,
    rpm: float,
    view: str = "front",
    shake_px: float = 0.0,
) -> Iterator[tuple[np.ndarray, dict]]:
    """逐幀產生轉動中的風機。方位角每幀前進 rpm/60*360/fps 度；shake_px 為手持隨機漫步幅度。"""
    rng = np.random.default_rng(spec.seed + 1000)
    step = rpm / 60.0 * 360.0 / fps
    offset = np.zeros(2)
    render = render_front if view == "front" else render_side
    for k in range(n_frames):
        if shake_px > 0:
            offset = 0.85 * offset + rng.normal(0, shake_px * 0.3, 2)
        frac = (spec.hub_frac[0] + offset[0] / spec.width, spec.hub_frac[1] + offset[1] / spec.height)
        # 雲層圖樣整段影片固定（真實天空在 30 秒內幾乎不變），只有感光雜訊逐幀不同
        fs = replace(spec, azimuth_deg=spec.azimuth_deg + step * k, hub_frac=frac, seed=spec.seed + k,
                     sky_seed=spec.sky_seed if spec.sky_seed is not None else spec.seed)
        img, truth = render(fs)
        truth["frame"] = k
        truth["time_s"] = k / fps
        truth["shake_offset"] = tuple(offset)
        yield img, truth

# ---------------------------------------------------------------- 合成音軌


@dataclass
class AudioSpec:
    """合成風機音軌。用來測「逐片聲音異常」演算法（§5.4 音軌）。

    模型（刻意簡化，但保留演算法要抓的結構）：
    - **風噪**：低頻主導的有色雜訊（1/f 斜率），整段穩定、沒有葉片通過週期
    - **葉片通過 swish**：每片每轉一次，寬頻噪音的高斯型振幅突起（這就是 AM 的來源）
    - **前緣侵蝕**：指定葉片的 swish 增益 +N dB，且能量往高頻推（高通再混入）
    - **後緣裂縫哨音**：指定葉片通過時才出現的窄頻正弦（含小幅頻率抖動，避免完美純音）
    """

    sample_rate: int = 24000
    duration_s: float = 8.0
    rpm: float = 12.0
    n_blades: int = 3
    wind_level: float = 0.05  # 風噪 RMS
    wind_slope: float = 1.2  # 1/f^slope，越大低頻越重
    swish_level: float = 0.05  # 葉片通過的寬頻突起振幅
    swish_width: float = 0.18  # 突起寬度（佔一個通過週期的比例）
    phase_s: float = 0.35  # 第一次通過的時刻
    # blade_idx -> 額外寬頻增益 dB（模擬前緣侵蝕）
    broadband_gain_db: dict = field(default_factory=dict)
    # blade_idx -> (頻率 Hz, 振幅) 通過時的哨音（模擬後緣裂縫）
    whistle: dict = field(default_factory=dict)
    seed: int = 0

    @property
    def blade_pass_hz(self) -> float:
        return self.rpm / 60.0 * self.n_blades


def _colored_noise(n: int, sr: int, slope: float, rng: np.random.Generator) -> np.ndarray:
    """1/f^slope 有色雜訊（頻域整形，回傳 RMS 正規化後的訊號）。"""
    spec = rng.standard_normal(n // 2 + 1) + 1j * rng.standard_normal(n // 2 + 1)
    f = np.fft.rfftfreq(n, d=1.0 / sr)
    shape = np.ones_like(f)
    nz = f > 0
    shape[nz] = 1.0 / np.power(f[nz] / 20.0, slope / 2.0)
    shape[0] = 0.0
    x = np.fft.irfft(spec * shape, n=n)
    return x / (np.sqrt(np.mean(x ** 2)) + 1e-12)


def _highpassish(x: np.ndarray, sr: int, cutoff_hz: float) -> np.ndarray:
    """一階高通（差分式），用來把侵蝕葉片的能量往高頻推，不引入 scipy 相依。"""
    a = float(np.exp(-2.0 * np.pi * cutoff_hz / sr))
    y = np.empty_like(x)
    prev_x = prev_y = 0.0
    for i, v in enumerate(x):
        prev_y = a * (prev_y + v - prev_x)
        prev_x = v
        y[i] = prev_y
    return y


def render_audio(spec: AudioSpec) -> tuple[np.ndarray, dict]:
    """回傳 (float32 單聲道 -1..1, ground truth dict)。"""
    rng = np.random.default_rng(spec.seed + 7000)
    sr = spec.sample_rate
    n = int(spec.duration_s * sr)
    t = np.arange(n) / sr
    period = 1.0 / spec.blade_pass_hz

    y = _colored_noise(n, sr, spec.wind_slope, rng) * spec.wind_level

    broad = _colored_noise(n, sr, 0.4, rng)  # swish 用的偏寬頻噪音
    broad_hf = _highpassish(broad, sr, 1500.0)
    broad_hf /= (np.sqrt(np.mean(broad_hf ** 2)) + 1e-12)

    pass_times, pass_blades = [], []
    k = 0
    tp = spec.phase_s
    while tp < spec.duration_s:
        b = k % spec.n_blades
        pass_times.append(float(tp))
        pass_blades.append(b)
        sigma = spec.swish_width * period
        bump = np.exp(-0.5 * ((t - tp) / sigma) ** 2)
        gain_db = float(spec.broadband_gain_db.get(b, 0.0))
        gain = 10.0 ** (gain_db / 20.0)
        # 侵蝕葉片：整體變大，且高頻成分占比提高
        hf_mix = 0.25 + min(0.5, max(0.0, gain_db) / 12.0 * 0.5)
        src = (1.0 - hf_mix) * broad + hf_mix * broad_hf
        y += spec.swish_level * gain * bump * src
        wh = spec.whistle.get(b)
        if wh:
            f0, amp = float(wh[0]), float(wh[1])
            jitter = np.cumsum(rng.standard_normal(n)) / sr * 1.5  # 緩慢頻率抖動
            y += amp * bump * np.sin(2 * np.pi * f0 * t + jitter)
        k += 1
        tp += period

    peak = float(np.max(np.abs(y))) or 1.0
    if peak > 0.95:
        y = y / peak * 0.95
    truth = {
        "sample_rate": sr, "duration_s": spec.duration_s, "rpm": spec.rpm,
        "blade_pass_hz": spec.blade_pass_hz, "period_s": period,
        "pass_times_s": pass_times, "pass_blades": pass_blades,
        "broadband_gain_db": dict(spec.broadband_gain_db),
        "whistle": {int(k2): list(v) for k2, v in spec.whistle.items()},
    }
    return y.astype(np.float32), truth


def write_wav(path: str, samples: np.ndarray, sample_rate: int) -> str:
    """存成 16-bit 單聲道 PCM WAV（stdlib，無外部相依）。"""
    data = np.clip(samples, -1.0, 1.0)
    pcm = (data * 32767.0).astype("<i2")
    with contextlib.closing(wave.open(path, "wb")) as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sample_rate))
        w.writeframes(pcm.tobytes())
    return path

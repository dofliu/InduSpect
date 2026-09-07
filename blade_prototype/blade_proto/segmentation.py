"""葉片/塔架分割與結構定位（§5.1 前處理）。

流程：
1. 估天空模型——**預設為局部模型**（`fit_local_sky`，見下），全機照用；
   長焦分區段照改用邊緣取樣的逐列多項式模型（`fit_sky_model`）
2. 每個像素對模型的 robust 標準化距離 → 固定門檻 → 前景
3. 形態學清理 + 連通元件過濾（去掉小碎片）
4. 結構：距離變換找輪轂（最厚處）→ 移除輪轂圓盤 → 塔架（碰底邊、最寬）→ 其餘為葉片
5. 輪轂精修：各葉片外段軸線的最小平方交點

模型在縮圖上估算（速度），套用在全解析度（幾何精度）。

**為什麼預設是局部模型**（2026-09-07，75 張真實照片實測，見 `REAL_IMAGE_VALIDATION.md`）：
原本的「邊緣取樣 + 逐列多項式 + 全域 robust 尺度」假設整張天空是單一平滑漸層。
真實天空有雲，兩個方向都會壞——雲被當成前景吃進遮罩，或者邊緣取樣帶裡的雲把全域
尺度撐大到什麼都進不了遮罩（30 張設計範圍內的照片有 4 張直接「遮罩為空」）。
局部模型改成假設「天空**局部**平滑」：雲塊是幾百像素的大面積漸變、葉片與塔架是幾十
像素的細長結構，所以用一個比結構寬、比雲小的中值核估背景就能兩者分離。
實測輪轂定位命中 14/30 → 24/30，有雲的情況 1/13 → 10/13，遮罩全空 4 → 0。
"""

from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np


DEFAULT_DIST_THRESH = 5.5  # 逐列多項式模型的門檻，robust sigma 單位

# 局部天空模型的參數。全部由 75 張真實照片掃描而得（set A 選、set B holdout 覆核）：
# kernel_frac 0.16–0.24 × 門檻 7–11 是一整片高原（命中 14–17/19），取高原中心而非尖峰
# ——19 張樣本的 argmax 會跳動，取中心才不是在擬合雜訊。
DEFAULT_LOCAL_KERNEL_FRAC = 0.20   # 中值核邊長 / 工作尺度長邊：要 > 塔架寬、< 雲塊尺度
# 門檻同時對兩組獨立的測試集取：真實照片（輪轂定位命中）與合成夾具（對已知真值的
# 結構召回率 / 天空誤判率）。7.0 是唯一同時成立的點——真實命中 23/30（有雲 10/13）、
# 合成結構召回 95.3%、天空誤判 0.02%。放寬到 9.0 真實命中只多 1 張，但合成結構召回
# 掉到 77.7%（塔架下段融進亮天空時被切掉），對要從遮罩邊緣量幾何的管線不能接受。
DEFAULT_LOCAL_THRESH = 7.0         # 局部 robust sigma 單位（與逐列模型的 5.5 不同尺規）
DEFAULT_LOCAL_WORK_SIDE = 1024     # 估背景與尺度的工作尺度長邊
DEFAULT_LOCAL_MIN_SCALE = 1.2      # 局部尺度下限（Lab 單位），純色無雲天空不會除以 0


@dataclass
class SkyModel:
    """天空顏色模型：Lab 每通道對正規化列位置 t=y/(H-1) 的多項式（處理天空垂直漸層）+ robust 尺度。"""

    coeffs: np.ndarray  # (3, deg+1)
    inv_scale: np.ndarray  # (3,) = 1/MAD

    def mean_rows(self, h: int) -> np.ndarray:
        t = np.linspace(0.0, 1.0, h, dtype=np.float32)
        return np.stack([np.polyval(c, t) for c in self.coeffs], axis=1).astype(np.float32)  # (h,3)


@dataclass
class LocalSkyModel:
    """局部天空模型：背景與尺度都是**影像場**，不是參數化曲面。

    兩個場都在工作尺度上算（中值濾波），套用時雙線性放大回全解析度——它們本來就是
    低頻的（核邊長是畫面的 20%），放大不會失真；殘差則在全解析度上取，1–2 px 的葉尖
    因此保得住。
    """

    bg: np.ndarray  # (h,w,3) float32，Lab 背景估計
    scale: np.ndarray  # (h,w,3) float32，各通道的局部 robust 尺度
    kernel_px: int  # 實際用的中值核邊長（工作尺度的像素）
    min_scale: float


@dataclass
class SegmentationResult:
    mask: np.ndarray  # uint8 0/255，與輸入同尺寸
    sky_model: SkyModel | LocalSkyModel
    threshold: float  # 距離門檻（尺規依模型種類而異）
    scale: float  # 估模型時的縮圖比例
    horizon_y: int | None = None  # 地平線列；None = 畫面沒有可辨識的地面帶


@dataclass
class BladeComponent:
    xs: np.ndarray
    ys: np.ndarray
    area: int
    tip_xy: tuple[float, float]
    tip_radius_px: float
    tip_angle_deg: float  # 數學慣例方位角（270° = 六點鐘）


@dataclass
class TurbineStructure:
    hub: tuple[float, float]
    hub_radius_px: float
    hub_refined: bool
    tower_found: bool
    tower_angle_deg: float  # 塔架軸相對垂直的偏差（正 = 順時鐘）；無塔架時為 0
    tower_width_px: float
    blades: list[BladeComponent] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


# ---------------------------------------------------------------- 天空模型


def _robust_polyfit_1d(t: np.ndarray, y: np.ndarray, deg: int, iters: int = 3) -> np.ndarray:
    keep = np.ones(len(t), bool)
    coeffs = np.polyfit(t, y, deg)
    for _ in range(iters):
        resid = y - np.polyval(coeffs, t)
        s = 1.4826 * np.median(np.abs(resid[keep] - np.median(resid[keep]))) + 1e-3
        keep = np.abs(resid) < 3.0 * s
        if keep.sum() < deg + 2:
            break
        coeffs = np.polyfit(t[keep], y[keep], deg)
    return coeffs


def fit_sky_model(img_bgr: np.ndarray, border_frac: float = 0.06, mode: str = "rows", deg: int = 3) -> SkyModel:
    """從畫面邊緣估天空模型。

    mode="rows"（全機照）：左右兩側窄帶每列取中位數，對列位置做 robust 多項式擬合；
        葉尖偶爾穿過側帶的列會被當離群值剔除。
    mode="top_bottom"（長焦分區段照，葉片橫越畫面、側帶多半是葉片）：
        只用上下兩條帶，兩者中位數線性內插。
    尺度：帶內像素對模型殘差的 MAD（含雲層紋理），下限 0.75 避免合成天空零方差。
    """
    lab = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2Lab).astype(np.float32)
    h, w = lab.shape[:2]
    if mode == "top_bottom":
        b = max(2, int(h * border_frac))
        top = lab[:b].reshape(-1, 3)
        bot = lab[h - b:].reshape(-1, 3)
        m_top, m_bot = np.median(top, 0), np.median(bot, 0)
        # 線性：t=0 → top, t=1 → bot
        coeffs = np.stack([np.array([m_bot[c] - m_top[c], m_top[c]]) for c in range(3)])
        strip_pix = np.concatenate([top, bot])
        strip_t = np.concatenate([np.full(len(top), 0.0), np.full(len(bot), 1.0)])
    else:
        s = max(2, int(w * border_frac))
        t_rows = np.linspace(0.0, 1.0, h)
        left = lab[:, :s]
        right = lab[:, w - s:]
        med_l = np.median(left, axis=1)  # (h,3)
        med_r = np.median(right, axis=1)
        tt = np.concatenate([t_rows, t_rows])
        coeffs = np.stack([_robust_polyfit_1d(tt, np.concatenate([med_l[:, c], med_r[:, c]]), deg) for c in range(3)])
        strip_pix = np.concatenate([left.reshape(-1, 3), right.reshape(-1, 3)])
        strip_t = np.concatenate([np.repeat(t_rows, s), np.repeat(t_rows, s)])
    model_at = np.stack([np.polyval(coeffs[c], strip_t) for c in range(3)], 1)
    resid = strip_pix - model_at
    # 用內點（去掉穿過側帶的葉片）算 MAD
    r_norm = np.abs(resid - np.median(resid, 0))
    mad = np.median(r_norm, 0) * 1.4826
    inlier = (r_norm < 4.0 * (mad + 0.5)).all(1)
    if inlier.sum() > 50:
        mad = np.median(np.abs(resid[inlier] - np.median(resid[inlier], 0)), 0) * 1.4826
    scale = np.maximum(mad, 0.75)
    return SkyModel(coeffs.astype(np.float32), (1.0 / scale).astype(np.float32))


def _grid_coords(n: int, step: int) -> np.ndarray:
    """0, step, 2*step, ... 並確保含最後一個索引（末段不等距，內插用真座標處理）。"""
    xs = list(range(0, n, step))
    if xs[-1] != n - 1:
        xs.append(n - 1)
    return np.array(xs, dtype=np.int32)


def _interp_from_grid(coarse: np.ndarray, xs: np.ndarray, ys: np.ndarray,
                      w: int, h: int) -> np.ndarray:
    """依**真實網格座標**做雙線性內插回 (h, w, c)。

    不用 `cv2.resize`：它假設等距網格，而 `_grid_coords` 的最後一段通常較短。
    """
    def weights(coords: np.ndarray, n: int):
        idx = np.searchsorted(coords, np.arange(n), side="right") - 1
        idx = np.clip(idx, 0, len(coords) - 2)
        lo, hi = coords[idx], coords[idx + 1]
        return idx, ((np.arange(n) - lo) / np.maximum(hi - lo, 1)).astype(np.float32)

    ix, tx = weights(xs, w)
    iy, ty = weights(ys, h)
    top = coarse[iy][:, ix] * (1 - tx)[None, :, None] + coarse[iy][:, ix + 1] * tx[None, :, None]
    bot = coarse[iy + 1][:, ix] * (1 - tx)[None, :, None] + coarse[iy + 1][:, ix + 1] * tx[None, :, None]
    return (top * (1 - ty)[:, None, None] + bot * ty[:, None, None]).astype(np.float32)


def _median_field(lab_u8: np.ndarray, k: int, grid_step: int) -> np.ndarray:
    """大核中值場。`grid_step > 1` 時只在網格點上取值再雙線性內插。

    **這是 App 端（Dart）實際跑的模式。** 網格點的中值不受「有沒有算鄰居」影響，
    所以這裡用快的 `cv2.medianBlur` 算完整場再取樣，數值與「只算網格點」完全相同；
    Dart 端只算網格點是為了成本（見下），不改變結果。

    為什麼 Dart 需要網格：真 2D 大核中值即使用 Perreault 的雙層直方圖，每個輸出像素
    仍要把兩個行直方圖（16 粗 + 256 細）加減進核直方圖，約 544 次 bin 運算；
    1024×820×3 ≈ 1.4G 次，手機上跑不動。只算網格點時，沿 x 每步只加減 `grid_step`
    個 column（每 column k px），總量降到約 64M 次——差 20 倍以上。

    代價（75 張真實照片實測，設計範圍內 30 張的輪轂命中）：
    逐像素 23/30、step=8 22/30、**step=16 22/30**、step=24 23/30、step=32 21/30。
    差異不是單調的，是個別照片在「誤差 ≤ 對角線 5%」門檻兩側翻動——場確實是低頻的。
    相對地，把 `work_side` 從 1024 降到 512/384/256 會掉到 20/19/18，而且時間幾乎沒省
    （瓶頸在結構定位不在中值），所以**寧可網格化也不要降工作尺度**。
    """
    if grid_step <= 1:
        return cv2.medianBlur(lab_u8, k).astype(np.float32)
    h, w = lab_u8.shape[:2]
    full = cv2.medianBlur(lab_u8, k).astype(np.float32)
    xs, ys = _grid_coords(w, grid_step), _grid_coords(h, grid_step)
    return _interp_from_grid(full[np.ix_(ys, xs)], xs, ys, w, h)


def fit_local_sky(
    img_bgr: np.ndarray,
    kernel_frac: float = DEFAULT_LOCAL_KERNEL_FRAC,
    work_side: int = DEFAULT_LOCAL_WORK_SIDE,
    min_scale: float = DEFAULT_LOCAL_MIN_SCALE,
    scale_gain: float = 4.0,
    grid_step: int = 1,
) -> LocalSkyModel:
    """估局部天空模型：背景 = Lab 的大核中值，尺度 = |殘差| 的同核中值。

    中值核是關鍵：它抹掉**比核窄**的東西、保留比核寬的東西。核邊長取工作尺度的 20%
    時，塔架與葉片（幾十像素）被抹掉而留在殘差裡，雲塊（幾百像素）被算進背景而不再
    產生殘差。尺度用同一個鄰域，所以雲區的尺度自然放大——葉片相對「該區的天空」仍然
    突出，遮罩不會因為畫面有雲就整片空掉。

    scale_gain：|殘差| 要量化成 uint8 才能用 OpenCV 的大核中值（O(1) 直方圖法），
    ×4 再除回來，讓 0–64 Lab 單位的殘差有 0.25 的解析度。

    grid_step：中值只在 step 間隔的網格點上取值再雙線性內插（見 `_median_field`）。
    預設 1（逐像素，原型用）；**App 端用 16**——那是手機跑得動的唯一形式，
    代價是 30 張真實照片的輪轂命中 23 → 22。
    """
    h, w = img_bgr.shape[:2]
    s = min(1.0, work_side / max(h, w))
    small = (img_bgr if s >= 1.0 else
             cv2.resize(img_bgr, (max(8, int(w * s)), max(8, int(h * s))),
                        interpolation=cv2.INTER_AREA))
    lab = cv2.cvtColor(small, cv2.COLOR_BGR2Lab)  # uint8：medianBlur 的大核只支援 8U
    k = int(round(kernel_frac * max(lab.shape[:2]))) | 1  # 必須是奇數
    k = int(max(5, min(k, 255)))  # OpenCV 的 medianBlur 上限
    bg = _median_field(lab, k, grid_step)
    resid = lab.astype(np.float32) - bg
    absr = np.clip(np.abs(resid) * scale_gain, 0, 255).astype(np.uint8)
    scale = _median_field(absr, k, grid_step) / scale_gain * 1.4826
    return LocalSkyModel(bg=bg, scale=np.maximum(scale, min_scale),
                         kernel_px=k, min_scale=float(min_scale))


def local_sky_distance(img_bgr: np.ndarray, model: LocalSkyModel) -> np.ndarray:
    """全解析度殘差 ÷ 放大回全解析度的低頻場。"""
    h, w = img_bgr.shape[:2]
    bg, scale = model.bg, model.scale
    if bg.shape[:2] != (h, w):
        bg = cv2.resize(bg, (w, h), interpolation=cv2.INTER_LINEAR)
        scale = cv2.resize(scale, (w, h), interpolation=cv2.INTER_LINEAR)
    lab = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2Lab).astype(np.float32)
    d = (lab - bg) / np.maximum(scale, model.min_scale)
    return np.sqrt(np.einsum("ijk,ijk->ij", d, d))


def sky_distance(img_bgr: np.ndarray, model: SkyModel | LocalSkyModel) -> np.ndarray:
    """依模型種類分派，呼叫端不必知道用的是哪一種。"""
    if isinstance(model, LocalSkyModel):
        return local_sky_distance(img_bgr, model)
    lab = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2Lab).astype(np.float32)
    means = model.mean_rows(lab.shape[0])  # (h,3)
    d = (lab - means[:, None, :]) * model.inv_scale[None, None, :]
    return np.sqrt(np.einsum("ijk,ijk->ij", d, d))


def _otsu_threshold(dist: np.ndarray, cap: float = 40.0) -> float:
    q = np.clip(dist / cap * 255.0, 0, 255).astype(np.uint8)
    t, _ = cv2.threshold(q, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    return float(t) / 255.0 * cap


def _clean_mask(fg: np.ndarray, min_area: int, max_width_frac: float = 0.7, drop_wide_bands: bool = True) -> np.ndarray:
    mask = fg.astype(np.uint8) * 255
    # 不做 morphological open：遠距/側視的葉尖只有 1–2 px 厚，open 會把它吃掉讓葉尖半徑忽長忽短；
    # 雜訊碎片交給下面的面積過濾。close 只補洞。
    k5 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, k5)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    keep = np.zeros(n, bool)
    w = mask.shape[1]
    for i in range(1, n):
        area = stats[i, cv2.CC_STAT_AREA]
        width = stats[i, cv2.CC_STAT_WIDTH]
        if area < min_area:
            continue
        if drop_wide_bands and width > max_width_frac * w and stats[i, cv2.CC_STAT_HEIGHT] < 0.5 * mask.shape[0]:
            continue  # 橫跨畫面的地面/地平線帶（全機照）；分區段照的葉片本身就是橫幅，呼叫端關掉
        keep[i] = True
    return np.where(keep[lab], 255, 0).astype(np.uint8)


def find_horizon(mask: np.ndarray, fill_thresh: float = 0.55, gap_rows: int = 6,
                 min_sky_frac: float = 0.25, min_band_frac: float = 0.02) -> int | None:
    """找地面帶的上緣（地平線列）。由畫面底部往上走，只要該列前景填充率高就繼續。

    真實照片的地面不是「橫跨畫面的矮元件」——它常常和塔架連成同一個元件，
    `_clean_mask` 的寬矮規則抓不到；但它有另一個穩定特徵：**整列幾乎都是前景**。
    容許 gap_rows 列中斷（道路、水面反光會讓某幾列填充率掉下來）。

    回傳 None 的兩種情況：帶太薄（<min_band_frac，多半只是畫面底噪），
    或地面吃掉超過 1−min_sky_frac 的畫面（此時天空模型多半已經壞了，切了也沒意義）。
    """
    h = mask.shape[0]
    fill = (mask > 0).mean(axis=1).astype(np.float32)
    fill = cv2.medianBlur(fill.reshape(-1, 1), 5).ravel()
    top = None
    miss = 0
    for y in range(h - 1, -1, -1):
        if fill[y] >= fill_thresh:
            top, miss = y, 0
        else:
            miss += 1
            if miss > gap_rows:
                break
    if top is None:
        return None
    band = (h - top) / h
    if band < min_band_frac or band > 1.0 - min_sky_frac:
        return None
    return int(top)


def segment_turbine(
    img_bgr: np.ndarray,
    max_side: int = 1200,
    border_frac: float = 0.06,
    min_area_frac: float = 3e-4,
    dist_thresh: float | None = None,
    sky_model: SkyModel | LocalSkyModel | None = None,
    full_res: bool = True,
    sky_mode: str = "local",
    drop_wide_bands: bool = True,
) -> SegmentationResult:
    """把風機（葉片 + 塔架 + 機艙）從天空分出來。

    sky_mode：
    - `"local"`（預設，全機照）：局部天空模型（`fit_local_sky`）。真實照片上唯一撐得住
      雲層的做法，理由與實測見模組 docstring。
    - `"rows"` / `"top_bottom"`：邊緣取樣的逐列多項式模型（`fit_sky_model`）。
      長焦分區段照必須用這個——那種照片的「結構」本身就佔滿畫面，大核中值會把葉片
      算進背景。`surface.py` 走 `top_bottom`。

    drop_wide_bands：把橫跨 70% 畫面寬、高度不到一半的元件當地面/地平線帶刪掉（全機照用）；
    長焦分區段照的葉片本身就是橫幅，要關掉。"""
    h, w = img_bgr.shape[:2]
    scale = min(1.0, max_side / max(h, w))
    small = img_bgr if scale >= 1.0 else cv2.resize(img_bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    if sky_model is not None:
        model = sky_model
    elif sky_mode == "local":
        model = fit_local_sky(img_bgr)  # 自己降到工作尺度，不吃 small
    else:
        model = fit_sky_model(small, border_frac, mode=sky_mode)
    dist_small = None
    if dist_thresh is None:
        if isinstance(model, LocalSkyModel):
            # 局部模型的距離尺規與逐列模型不同（除的是局部尺度而非全域），
            # 門檻另外量。真實照片掃描出的高原中心：見 DEFAULT_LOCAL_THRESH 的註解。
            dist_thresh = DEFAULT_LOCAL_THRESH
        else:
            dist_small = sky_distance(small, model)
            # 固定 5.5 個 robust sigma。合成資料量測：5σ 時塔架召回 95%、天空誤判 0.16%（皆為小碎片）；
            # Otsu 會被「白葉片 vs 藍天」的大距離拉到 14σ 以上，把灰塔架 vs 亮地平線天空吃掉，故不採用。
            dist_thresh = DEFAULT_DIST_THRESH
    # 距離圖先做 σ0.8 高斯平滑再取門檻：孤立雜訊像素被壓下去、邊界變平滑，
    # 而 1 px 寬的葉尖線會變成 2 px 寬的較低值仍高於門檻（形態學 open 會把它整條吃掉）。
    if full_res or scale >= 1.0:
        dist = cv2.GaussianBlur(sky_distance(img_bgr, model), (0, 0), 0.8)
        mask = _clean_mask(dist > dist_thresh, int(min_area_frac * h * w), drop_wide_bands=drop_wide_bands)
    else:
        if dist_small is None:
            dist_small = sky_distance(small, model)
        dist_small = cv2.GaussianBlur(dist_small, (0, 0), 0.8)
        mask_small = _clean_mask(dist_small > dist_thresh, int(min_area_frac * small.shape[0] * small.shape[1]),
                                 drop_wide_bands=drop_wide_bands)
        mask = cv2.resize(mask_small, (w, h), interpolation=cv2.INTER_NEAREST)
    horizon = find_horizon(mask) if drop_wide_bands else None
    return SegmentationResult(mask=mask, sky_model=model, threshold=float(dist_thresh),
                              scale=scale, horizon_y=horizon)


# ---------------------------------------------------------------- 結構定位


def _pca_axis(xs: np.ndarray, ys: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    """回傳 (質心, 主軸單位向量, 伸長比 = sqrt(λ1/λ2))。"""
    pts = np.stack([xs, ys], 1).astype(np.float64)
    c = pts.mean(0)
    _, sv, vt = np.linalg.svd(pts - c, full_matrices=False)
    elong = float(sv[0] / max(sv[1], 1e-6))
    return c, vt[0], elong


def _ls_intersection(points: list[np.ndarray], dirs: list[np.ndarray]) -> np.ndarray:
    """多條直線的最小平方交點：min Σ‖(I - d dᵀ)(x - p)‖²。"""
    A = np.zeros((2, 2))
    b = np.zeros(2)
    for p, d in zip(points, dirs):
        d = d / np.linalg.norm(d)
        P = np.eye(2) - np.outer(d, d)
        A += P
        b += P @ p
    return np.linalg.solve(A + np.eye(2) * 1e-9, b)


def _angle_deg(dx: float, dy: float) -> float:
    """影像向量 → 數學慣例方位角（y 向下所以取負）。"""
    return float(np.degrees(np.arctan2(-dy, dx)) % 360.0)


def _axis_angle_between(a: np.ndarray, b: np.ndarray) -> float:
    """兩條無向軸線的夾角（0–90°）。"""
    c = abs(float(np.dot(a, b))) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)
    return float(np.degrees(np.arccos(np.clip(c, -1.0, 1.0))))


@dataclass
class _Comp:
    xs: np.ndarray
    ys: np.ndarray
    touches_bottom: bool

    def dist_to(self, hub) -> np.ndarray:
        return np.hypot(self.xs - hub[0], self.ys - hub[1])


def _median_row_width(xs: np.ndarray, ys: np.ndarray) -> float:
    rows = np.unique(ys)
    step = max(1, len(rows) // 40)
    return float(np.median([np.ptp(xs[ys == r]) + 1 for r in rows[::step]]))


def _split_by_angle(comp: _Comp, hub: np.ndarray, hub_r: float, min_pixels: int = 30) -> list[_Comp]:
    """一個元件內若有多條「臂」（葉片/塔架在輪轂附近黏在一起），用對輪轂的角度直方圖拆開。

    只用固定半徑帶（6–14 hub_r）的像素建直方圖，避免根部重疊填掉臂與臂之間的空隙，也避免長塔架主導計數；
    所有像素再依「角度落在哪個臂的角度區間」分配，落在空隙者歸最近的臂。
    """
    d = comp.dist_to(hub)
    # 只用固定半徑帶 [6, 14] hub_r 內的像素建直方圖：每條臂在帶內的像素數只和臂寬成正比，
    # 不會被很長的塔架（上千 px）壓過細短的葉片，讓 8% 門檻切不開夾角小的臂。
    band = (d > 6.0 * hub_r) & (d < 14.0 * hub_r)
    if band.sum() < 50:
        band = d > 6.0 * hub_r
    if band.sum() < 50:
        return [comp]
    ang_all = np.degrees(np.arctan2(-(comp.ys - hub[1]), comp.xs - hub[0])) % 360.0
    hist = np.bincount(ang_all[band].astype(int) % 360, minlength=360).astype(float)
    k = np.ones(5) / 5.0
    sm = np.convolve(np.concatenate([hist[-2:], hist, hist[:2]]), k, mode="valid")  # 環狀平滑
    on = sm > 0.08 * sm.max()
    if on.all() or not on.any():
        return [comp]
    # 找環狀的連續 on 區段
    start = int(np.flatnonzero(~on)[0])  # 從某個 off 位置開始掃，保證不切到臂中間
    runs: list[tuple[int, int]] = []
    i = 0
    while i < 360:
        j = (start + i) % 360
        if on[j]:
            a = j
            n = 0
            while on[(start + i) % 360] and n < 360:
                i += 1
                n += 1
            runs.append((a, (a + n - 1) % 360))
        else:
            i += 1
    if len(runs) <= 1:
        return [comp]
    centers = np.array([(a + ((b - a) % 360) / 2.0) % 360 for a, b in runs])
    # 分配：角度落在區間內 → 該臂；否則最近臂心
    label = np.full(len(ang_all), -1)
    for r, (a, b) in enumerate(runs):
        span = (b - a) % 360
        inside = ((ang_all - a) % 360) <= span
        label[inside] = r
    miss = label < 0
    if miss.any():
        diff = np.abs((ang_all[miss, None] - centers[None, :] + 180.0) % 360.0 - 180.0)
        label[miss] = np.argmin(diff, axis=1)
    parts = []
    for r in range(len(runs)):
        sel = label == r
        if sel.sum() < min_pixels:
            continue
        parts.append(_Comp(comp.xs[sel], comp.ys[sel],
                           bool(comp.touches_bottom and comp.ys[sel].max() >= comp.ys.max() - 1)))
    return parts if len(parts) >= 2 else [comp]


def _split_components(mask: np.ndarray, hub: np.ndarray, hub_r: float, min_area: int,
                      tower_axis=None) -> tuple[list[_Comp], _Comp | None]:
    """移除輪轂圓盤後取連通元件。已知塔軸（a, b, tw）時先把塔架帶挖出來直接當塔架：
    雲塊把垂掛葉片和塔架橋接在一起時，角度直方圖切不開（夾角只有幾度），用幾何帶切最可靠。"""
    h, w = mask.shape
    core = mask.copy()
    cv2.circle(core, (int(round(hub[0])), int(round(hub[1]))), int(1.6 * hub_r) + 1, 0, -1)
    tower: _Comp | None = None
    if tower_axis is not None:
        a, b, tw = tower_axis
        yy, xx = np.mgrid[0:h, 0:w]
        band = (np.abs(xx - (a * yy + b)) <= 0.6 * tw) & (yy > hub[1] + hub_r) & (core > 0)
        ty, tx = np.nonzero(band)
        if len(ty) >= min_area:
            tower = _Comp(tx, ty, bool(ty.max() >= h - 2))
            core[band] = 0
    n, lab, stats, _ = cv2.connectedComponentsWithStats(core, connectivity=8)
    comps: list[_Comp] = []
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] < min_area:
            continue
        ys_i, xs_i = np.nonzero(lab == i)
        c = _Comp(xs_i, ys_i, bool(stats[i, cv2.CC_STAT_TOP] + stats[i, cv2.CC_STAT_HEIGHT] >= h - 2))
        if c.dist_to(hub).min() > 3.0 * hub_r:
            continue  # 沒接在輪轂上（雲、鳥、遠處物件）
        comps.extend(_split_by_angle(c, hub, hub_r))
    return comps, tower


def _classify(comps: list[_Comp], hub: np.ndarray, hub_r: float, max_blades: int, given_tower: _Comp | None = None):
    """回傳 (tower_comp | None, tower_axis | None, blade_comps)。given_tower 為塔軸帶切出的塔架（優先採用）。

    塔架：伸長、軸線近垂直（<20°）、質心在輪轂下方；碰底邊者優先（取最寬），
    否則取往下延伸最遠者。正視時若有葉片在六點鐘 ±20° 內會與塔架混淆——拍攝協定應避免。
    葉片：其餘伸長元件（elong > 2.5）且葉尖半徑 > 4 hub_r，依面積取前 max_blades。
    """
    info = []
    for c in comps:
        cen, ax, elong = _pca_axis(c.xs, c.ys)
        d = c.dist_to(hub)
        info.append((c, cen, ax, elong, float(d.max())))
    tower = None
    tower_axis = None
    if given_tower is not None:
        tower = given_tower
        _, tower_axis, _ = _pca_axis(tower.xs, tower.ys)
    cands = [] if given_tower is not None else [
        (c, cen, ax) for (c, cen, ax, elong, rmax) in info
        if elong > 2.5 and cen[1] > hub[1] and _axis_angle_between(ax, np.array([0.0, 1.0])) < 20.0]
    if cands:
        bottom = [t for t in cands if t[0].touches_bottom]
        pool = bottom if bottom else cands
        if bottom:
            tower, _, tower_axis = max(pool, key=lambda t: _median_row_width(t[0].xs, t[0].ys))
        else:
            tower, _, tower_axis = max(pool, key=lambda t: t[0].ys.max())
    blades = [(c, rmax) for (c, cen, ax, elong, rmax) in info
              if c is not tower and elong > 2.5 and rmax > 4.0 * hub_r]
    blades.sort(key=lambda t: -len(t[0].xs))
    return tower, tower_axis, [c for c, _ in blades[:max_blades]]


def _blade_axis(c: _Comp, hub: np.ndarray, rmax: float, span: tuple[float, float] = (0.15, 0.55)):
    """葉片軸線（質心, 方向）。預設用內段 0.15–0.55 R：葉尖偏移 ∝ t²，內段受彎曲影響小，軸線較準地過輪轂。"""
    d = c.dist_to(hub)
    sel = (d > span[0] * rmax) & (d < span[1] * rmax)
    if sel.sum() < 20:
        return None
    cen, ax, _ = _pca_axis(c.xs[sel], c.ys[sel])
    return cen, ax


def _count_arms(mask: np.ndarray, p: np.ndarray, radius: float, n: int = 96) -> int:
    """以 p 為圓心、radius 為半徑取樣一圈，數「與圓心連通的遮罩區域」由 0→1 的次數 = 從該點伸出去的臂數。

    只看與圓心連通的區域：否則塔架上的點會把旁邊經過的垂掛葉片也算成臂。
    """
    h, w = mask.shape
    x0, y0 = int(round(p[0])), int(round(p[1]))
    r = int(np.ceil(radius)) + 2
    xa, xb = max(0, x0 - r), min(w, x0 + r + 1)
    ya, yb = max(0, y0 - r), min(h, y0 + r + 1)
    crop = (mask[ya:yb, xa:xb] > 0).astype(np.uint8)
    cx, cy = x0 - xa, y0 - ya
    if not (0 <= cy < crop.shape[0] and 0 <= cx < crop.shape[1]) or crop[cy, cx] == 0:
        return 0
    yy, xx = np.mgrid[ya:yb, xa:xb]
    crop[(xx - x0) ** 2 + (yy - y0) ** 2 > (radius + 1.5) ** 2] = 0
    _, labels = cv2.connectedComponents(crop, connectivity=8)
    region = labels == labels[cy, cx]
    th = np.linspace(0, 2 * np.pi, n, endpoint=False)
    xs = np.round(cx + radius * np.cos(th)).astype(int)
    ys = np.round(cy + radius * np.sin(th)).astype(int)
    inside = (xs >= 0) & (xs < region.shape[1]) & (ys >= 0) & (ys < region.shape[0])
    ring = np.zeros(n, bool)
    ring[inside] = region[ys[inside], xs[inside]]
    return int(np.sum(ring & ~np.roll(ring, 1)))


def _largest_component_mask(mask: np.ndarray) -> np.ndarray:
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if n <= 2:
        return mask
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    return np.where(lab == k, 255, 0).astype(np.uint8)


def _tower_axis_from_bottom(mask: np.ndarray):
    """從遮罩下方 30% 的列找塔架：逐列取連續段、依中心 x 串成軌跡，選最垂直且覆蓋夠多列的軌跡。

    回傳 (a, b, 中位寬度)，塔軸 x = a·y + b；找不到回傳 None。
    葉片斜著穿過下方列時中心 x 會隨 y 線性漂移，塔架則近乎不動，所以用斜率挑。
    """
    ys_all, _ = np.nonzero(mask)
    top, bottom = int(ys_all.min()), int(ys_all.max())
    y0 = int(bottom - 0.3 * (bottom - top))
    step = max(1, (bottom - y0) // 60)
    rows = list(range(y0, bottom + 1, step))
    tracks: list[dict] = []
    for y in rows:
        row = mask[y] > 0
        d = np.diff(np.concatenate([[0], row.astype(np.int8), [0]]))
        for s_, e_ in zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)):
            cx, wd = (s_ + e_ - 1) / 2.0, int(e_ - s_)
            for t in tracks:
                if t["y"][-1] != y and abs(t["x"][-1] - cx) < max(1.5 * wd, 15.0):
                    t["x"].append(cx)
                    t["y"].append(y)
                    t["w"].append(wd)
                    break
            else:
                tracks.append({"x": [cx], "y": [y], "w": [wd]})
    cands = [t for t in tracks if len(t["y"]) >= 0.6 * len(rows)]
    if not cands:
        return None
    fits = [(abs(np.polyfit(t["y"], t["x"], 1)[0]), t) for t in cands]
    slope, t = min(fits, key=lambda z: z[0])
    if slope > 0.35:  # 超過 ~20° 就不像塔架
        return None
    a, b = np.polyfit(t["y"], t["x"], 1)
    return float(a), float(b), float(np.median(t["w"]))


def _initial_hub_tower_first(mask: np.ndarray, dt: np.ndarray):
    """沿塔軸往上走，取「臂數 ≥ 3 的連續區段」最上端當輪轂/機艙位置。

    靠近六點鐘的葉片會在輪轂下方就與塔架黏合，那一段臂數也是 3，所以不能取第一個 3 臂點；
    輪轂上方沿軸通常沒有遮罩（或只剩 2 臂的向上葉片），區段自然結束。

    停止條件是「軸線離開遮罩超過 3 步」，不是「連續 3 步不合格」：六點鐘葉片貼著塔架時，
    塔身中段會出現零星的 3 臂點，之後又掉回 2 臂——用「不合格就停」會讓走訪停在塔身中央
    （真實影像 631b5a3e 即為此例）。離開遮罩才停，就只會停在機艙上方。
    正視：終點即輪轂；側視：終點是機艙中心，之後由 find_structure 投影到葉片軸線。
    """
    axis = _tower_axis_from_bottom(mask)
    if axis is None:
        return None
    a, b, tw = axis
    h, w = mask.shape
    ys_all, _ = np.nonzero(mask)
    top, bottom = int(ys_all.min()), int(ys_all.max())
    # 轉子在框內時，輪轂上下都還有結構（上方葉片、下方塔架），不可能落在整體高度的最下緣。
    # 落在下緣代表走訪停在塔身或地平線殘渣上（真實影像 631b5a3e），此時回傳 None 讓
    # 呼叫端改用 DT + 臂數法，比硬給一個錯的輪轂安全。
    y_limit = top + 0.75 * (bottom - top)
    step = max(2, int(tw / 2))
    best = None
    gap = 0
    seg_peak = 0.0
    for y in range(h - 1, top, -step):
        x = a * y + b
        xi, yi = int(round(x)), int(round(y))
        on_mask = 0 <= xi < w and mask[yi, xi] != 0
        if on_mask:
            r = float(dt[yi, xi])
            seg_peak = max(seg_peak, r)
            # DT 門檻：tw 是塔基寬度、塔架往上收窄，所以下限只用 0.2×tw；
            # 另要求不低於沿軸最大 DT 的 60%，讓終點停在輪轂/機艙「中心」而非其上緣薄處
            if r >= max(0.2 * tw, 0.6 * seg_peak) and \
                    _count_arms(mask, np.array([x, y], float), max(4.0 * r, 12.0)) >= 3:
                best = (np.array([x, float(y)]), r)
        if best is not None:
            gap = 0 if on_mask else gap + 1
            if gap > 3:
                break
    if best is None or best[0][1] > y_limit:
        return None
    return best[0], best[1], (a, b, tw)


def _initial_hub(mask: np.ndarray, dt: np.ndarray, y_cut: int):
    """輪轂初估：先試「塔架優先」（沿塔軸找分叉），失敗才用「DT 局部極大值 + 臂數」。

    臂數法只在最大連通元件內找（排除獨立雲塊）；輪轂 3–4 臂、塔架/葉片中段 2 臂。
    """
    tf = _initial_hub_tower_first(mask, dt)
    if tf is not None:
        return tf  # (hub, dt, tower_axis)
    band = dt.copy()
    band[y_cut:, :] = 0
    band[_largest_component_mask(mask) == 0] = 0
    peak = float(band.max())
    dil = cv2.dilate(band, np.ones((15, 15), np.uint8))
    cy, cx = np.nonzero((band >= dil - 1e-6) & (band >= 0.4 * peak))
    order = np.argsort(-band[cy, cx])
    picked: list[tuple[np.ndarray, float, int]] = []
    for k in order:
        p = np.array([cx[k], cy[k]], float)
        r = float(band[cy[k], cx[k]])
        if any(np.hypot(*(p - q)) < 3.0 * max(r, rq) for q, rq, _ in picked):
            continue
        picked.append((p, r, _count_arms(mask, p, max(4.0 * r, 12.0))))
        if len(picked) >= 12:
            break
    best = max(picked, key=lambda t: (t[2], t[1]))
    return best[0], best[1], None


def find_second_rotor(
    mask: np.ndarray,
    structure: "TurbineStructure",
    horizon_y: int | None = None,
    min_pixels: int = 200,
) -> tuple[float, int]:
    """把已定位風機的元件拿掉，在剩下的遮罩上再找一次轉子。

    回答的是「畫面裡有沒有**第二個轉子**」，不是「有沒有第二個色塊」。這個區別是量出來的：
    單看「不屬於已定位結構的最大元件」完全分不開單台與多台照片（single 的比值 0.0–4.4、
    multi 的 0.13–2.5），因為那個量被地面、樹線、遠景農田主導，不是第二台風機。
    重跑一次結構定位才問得到正確的問題。

    回傳 (第二個轉子的葉尖半徑, 找到的臂數)；找不到回傳 (0.0, 0)。
    半徑要和主風機的比才有意義——遠處的他機半徑很小，等大同框的才接近 1。
    """
    h, w = mask.shape
    rest = mask.copy()
    if horizon_y is not None and 0 < horizon_y < h:
        rest[horizon_y:, :] = 0
    n, lab, _, _ = cv2.connectedComponentsWithStats(rest, connectivity=8)
    own: set[int] = set()
    for b in structure.blades:
        inside = b.ys < rest.shape[0]
        if inside.any():
            own.update(np.unique(lab[b.ys[inside], b.xs[inside]]).tolist())
    hx, hy = int(round(structure.hub[0])), int(round(structure.hub[1]))
    if 0 <= hx < w and 0 <= hy < h:
        own.add(int(lab[hy, hx]))
    own.discard(0)
    for i in own:
        rest[lab == i] = 0
    if int((rest > 0).sum()) < min_pixels:
        return 0.0, 0
    try:
        st2 = find_structure(rest)
    except ValueError:
        return 0.0, 0
    return max((b.tip_radius_px for b in st2.blades), default=0.0), len(st2.blades)


def find_structure(
    mask: np.ndarray,
    hub_hint: tuple[float, float] | None = None,
    max_blades: int = 3,
    min_blade_area_frac: float = 2e-4,
    n_iter: int = 4,
    refine: bool | None = None,
    horizon_y: int | None = None,
) -> TurbineStructure:
    """從分割遮罩找輪轂、塔架、葉片。

    1. 輪轂初估：距離變換在遮罩上方 65% 的最大值（葉根 + 輪轂/機艙是最厚的地方）；
       相鄰葉片夾角小時峰值會落在楔形上，靠下面的迭代修正。
    2. 迭代：移除輪轂圓盤 → 連通元件（楔形用角度聚類拆開）→ 分類塔架/葉片
       → 葉片外段軸線最小平方交點（正視）或投影到主葉片軸線（側視、共線）→ 更新輪轂。

    horizon_y：地平線列（`find_horizon` 的輸出）。給了就只在地平線以上做結構定位。
    真實影像上這是最重要的一個參數：地面/植被進入遮罩後，距離變換最厚處會落在地面，
    輪轂初估與塔軸偵測會整個歪掉，而且地面殘塊會被當成第四片葉片。
    """
    h, w = mask.shape
    notes: list[str] = []
    if horizon_y is not None and 0 < horizon_y < h:
        mask = mask.copy()
        mask[horizon_y:, :] = 0
        notes.append(f"只用地平線（第 {horizon_y} 列）以上做結構定位")
    ys_all, xs_all = np.nonzero(mask)
    if len(ys_all) == 0:
        raise ValueError("遮罩為空，無法定位結構")
    top, bottom = ys_all.min(), ys_all.max()
    dt = cv2.distanceTransform(mask, cv2.DIST_L2, 5)

    def _dt_at(p: np.ndarray) -> float:
        x, y = int(round(p[0])), int(round(p[1]))
        if 0 <= x < w and 0 <= y < h:
            return float(dt[y, x])
        return 0.0

    if hub_hint is not None:
        hub = np.array(hub_hint, float)
        peak = _dt_at(hub)
        if peak <= 0:
            peak = float(dt.max()) * 0.5
            notes.append("hub_hint 落在背景上，hub_radius 以 DT 最大值一半代替")
        tower_axis = None
    else:
        hub, peak, tower_axis = _initial_hub(mask, dt, int(top + 0.65 * (bottom - top)))
    hub_r = peak
    min_area = int(min_blade_area_frac * h * w)
    if refine is None:
        refine = hub_hint is None  # 給了提示就視為固定輪轂（影片離群幀重算、人工點選）

    refined = False
    tower = None
    blades: list[_Comp] = []
    for it in range(n_iter if refine else 0):
        comps, given = _split_components(mask, hub, hub_r, min_area, tower_axis)
        tower, tower_dir, blades = _classify(comps, hub, hub_r, max_blades, given)
        axes = []
        for c in blades:
            a = _blade_axis(c, hub, float(c.dist_to(hub).max()))
            if a is not None:
                axes.append(a)
        # 正視時塔架軸也過輪轂；但側視塔架在機艙中心下方、與葉片平行 → 只在不平行時採用。
        # 另外要求塔架軸近垂直（<5°）：葉片與塔架重疊時合併元件的軸會歪掉，不能拿來定輪轂。
        if tower is not None and tower_dir is not None and axes and \
                _axis_angle_between(tower_dir, np.array([0.0, 1.0])) < 5.0 and \
                all(_axis_angle_between(tower_dir, ax) > 25.0 for _, ax in axes):
            axes.append((np.array([tower.xs.mean(), tower.ys.mean()]), tower_dir))
        if not axes:
            notes.append("找不到任何伸長元件，輪轂保留初估")
            break
        well_conditioned = len(axes) >= 2 and max(
            _axis_angle_between(a1, a2) for i, (_, a1) in enumerate(axes) for _, a2 in axes[i + 1:]) > 25.0
        if well_conditioned:
            new_hub = _ls_intersection([p for p, _ in axes], [d for _, d in axes])
        else:
            big = max(blades, key=lambda c: len(c.xs)) if blades else None
            a = _blade_axis(big, hub, float(big.dist_to(hub).max())) if big is not None else None
            if a is None:
                break
            cen, ax = a
            new_hub = cen + ax * float(np.dot(hub - cen, ax))
            if it == 0:
                notes.append("葉片軸線共線（側視），輪轂投影到主葉片軸線")
        moved = float(np.hypot(*(new_hub - hub)))
        # 允許的移動距離以**轉子半徑**為尺規，不是 hub_r。hub_r 量的是機艙在遮罩裡的
        # 厚度，會隨天空模型的鬆緊而變（換成局部天空模型後從 17.8 掉到 11.0），拿它當
        # 尺規會把側視合法的「投影到葉片軸線」也擋掉。精修是葉片軸線的交點/投影，
        # 移動幾個百分比的葉長屬正常，幾十個百分比才是軸線被塔架拉歪。
        # 保留 4×hub_r 當下限，所以這條只會放寬、不會變嚴。
        rotor_r = max((float(c.dist_to(hub).max()) for c in blades), default=0.0)
        limit = max(4.0 * peak, 0.15 * rotor_r)
        if not (0 <= new_hub[0] < w and 0 <= new_hub[1] < h) or moved > limit:
            notes.append(f"輪轂精修移動 {moved:.0f} px 超過上限 {limit:.0f} px，保留前一估計")
            break
        hub = new_hub
        hub_r = max(_dt_at(hub), peak)  # 圓盤只用來切開葉根，寧大勿小
        refined = True
        if moved < 0.5:
            break

    # 最終元件與輸出
    comps, given = _split_components(mask, hub, hub_r, min_area, tower_axis)
    tower, tower_dir, blades = _classify(comps, hub, hub_r, max_blades, given)
    tower_angle, tower_width = 0.0, 0.0
    if tower is not None:
        ax = tower_dir if tower_dir[1] > 0 else -tower_dir
        tower_angle = float(np.degrees(np.arctan2(ax[0], ax[1])))
        tower_width = _median_row_width(tower.xs, tower.ys)
    else:
        notes.append("未找到塔架元件（畫面可能未含塔架，或塔架被亮天空吃掉）")

    out: list[BladeComponent] = []
    for c in blades:
        d = c.dist_to(hub)
        j = int(np.argmax(d))
        out.append(BladeComponent(
            xs=c.xs, ys=c.ys, area=int(len(c.xs)),
            tip_xy=(float(c.xs[j]), float(c.ys[j])), tip_radius_px=float(d[j]),
            tip_angle_deg=_angle_deg(c.xs[j] - hub[0], c.ys[j] - hub[1]),
        ))
    out.sort(key=lambda b: b.tip_angle_deg)
    return TurbineStructure(
        hub=(float(hub[0]), float(hub[1])), hub_radius_px=float(hub_r), hub_refined=refined,
        tower_found=tower is not None, tower_angle_deg=tower_angle, tower_width_px=tower_width,
        blades=out, notes=notes,
    )

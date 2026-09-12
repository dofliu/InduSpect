"""運動分割：用「會動的才是轉子」取代「跟天空顏色不一樣的才是轉子」來定位輪轂。

背景：幾何層的分割走天空模型（`segmentation.py`），真實照片輪轂命中 23/30、有雲 10/13，
逆光是硬限制——因為它問的是「哪些像素不像天空」，而雲、光暈、建物都不像天空。
影片多給了一個維度：時間。轉子在動、其他都不動（或動得完全不像放射狀的細長段）。

方法（單段手機影片，5–15 秒即可）：
  1. `stabilise`：ORB 特徵 + RANSAC 相似變換，把每幀對齊到中間那一幀。特徵大多落在地面、
     塔架、機艙這些有紋理又不動的地方；轉子上的匹配少而且彼此不一致，RANSAC 會丟掉它們。
     刻意不用整張相位相關——轉子與雲會把相關峰拉走（實測某幀估出 171 px 的假位移）。
  2. `motion_masks`：逐像素時間中位數 = 靜態背景（雲、塔架、機艙、地面都在裡面），
     |幀 − 背景| 超過背景殘差尺度（時間 MAD）的 k 倍就是「這一幀在動的像素」。
  3. `hub_from_lines`：每幀運動遮罩裡的**細長**元件取主軸直線，全部投進一張票圖；
     3 片 × N 幀的直線只會在輪轂一處交會。雲塊不細長、草不細長，地面上的葉片影子雖然
     細長但交在影子自己的中心，遠處的小風機線短票少。
     這比「聯集遮罩的外輪廓擬合圓」穩：外輪廓會被相連的雲／影子拉歪，共點不會。

不做的事：這裡只定位輪轂與轉子半徑。三片互比、拍攝閘門仍走既有的幾何層——
運動分割給它一個可靠的 `hub_hint`，不取代它。
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np


@dataclass
class StabiliseResult:
    frames: list[np.ndarray]
    shifts_px: list[float]  # 每幀相對參考幀的平移量；對齊失敗為 NaN
    valid: np.ndarray  # uint8 0/255：所有幀都有影像的共同區域
    methods: list[str] = field(default_factory=list)  # 每幀用了 'ref' / 'orb' / 'phase' / 'none'
    offsets: list[tuple[float, float] | None] = field(default_factory=list)  # 每幀估得的平移 (dx, dy)

    @property
    def failed_frames(self) -> int:
        return int(sum(1 for s in self.shifts_px if s != s))

    @property
    def fallback_frames(self) -> int:
        """ORB 找不到夠多靜態特徵、退回下半幅相位相關的幀數（合成場景沒有地面紋理時會全部走這裡）。"""
        return int(sum(1 for m in self.methods if m == "phase"))


@dataclass
class MotionHub:
    ok: bool
    hub: tuple[float, float] | None = None
    rotor_r_px: float = 0.0
    peak: float = 0.0
    second_peak: float = 0.0
    n_lines: int = 0
    n_lines_through_hub: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def peak_ratio(self) -> float:
        """主峰 / 次峰（次峰離主峰 ≥ 60 px）。越大越可信；< 1.3 表示畫面裡另有一個放射中心。"""
        return self.peak / self.second_peak if self.second_peak > 0 else float("inf")


def stabilise(frames: list[np.ndarray], ref_index: int | None = None) -> StabiliseResult:
    mid = len(frames) // 2 if ref_index is None else ref_index
    ref_gray = cv2.cvtColor(frames[mid], cv2.COLOR_BGR2GRAY)
    orb = cv2.ORB_create(nfeatures=4000, fastThreshold=10)
    kp_r, des_r = orb.detectAndCompute(ref_gray, None)
    bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    h, w = ref_gray.shape
    # 備援：下半幅相位相關。轉子在畫面上半，下半是地面與塔基；ORB 在沒有紋理的場景
    # （合成影像、雪地、海面）會找不到夠多特徵，這時只用下半幅估平移，至少不會被轉子拉走。
    y0 = int(h * 0.55)
    ref_low = ref_gray[y0:].astype(np.float32)
    win = cv2.createHanningWindow(ref_low.shape[1::-1], cv2.CV_32F)
    # 備援只信「回應夠強且位移很小」的估計：下半幅若含轉子下半（近拍、仰拍），相位相關會
    # 鎖到葉片的週期位置，給出回應 0.3–0.4 但位移 90–170 px 的假答案（合成場景實測）。
    # 手持 10–15 秒的漂移實測只有幾個百分點（abla：中位 4.4、最大 15.5 px @1024），超過就當沒對齊，
    # 保留原幀（腳架的正確答案本來就是恆等）。
    fallback_max_shift = 0.05 * max(h, w)
    fallback_min_resp = 0.2
    out: list[np.ndarray] = []
    shifts: list[float] = []
    methods: list[str] = []
    offsets: list[tuple[float, float] | None] = []
    valid = np.full((h, w), 255, np.uint8)
    max_shift = 0.2 * max(h, w)

    def _sane(m: np.ndarray) -> bool:
        # 手持拍靜態場景：沒有變焦、轉動很小、平移有限。違反任一項就是 RANSAC 被轉子／雲的
        # 假匹配帶走了（合成場景實測估出 100–200 px 的假平移），寧可退回備援。
        scale = math.hypot(m[0, 0], m[1, 0])
        rot = abs(math.degrees(math.atan2(m[1, 0], m[0, 0])))
        return 0.97 <= scale <= 1.03 and rot <= 3.0 and math.hypot(m[0, 2], m[1, 2]) <= max_shift

    for i, f in enumerate(frames):
        if i == mid:
            out.append(f)
            shifts.append(0.0)
            methods.append("ref")
            offsets.append((0.0, 0.0))
            continue
        g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
        m = None
        method = "none"
        if des_r is not None:
            kp, des = orb.detectAndCompute(g, None)
            if des is not None and len(kp) >= 20:
                matches = bf.match(des, des_r)
                if len(matches) >= 20:
                    src_pts = np.float32([kp[x.queryIdx].pt for x in matches])
                    dst_pts = np.float32([kp_r[x.trainIdx].pt for x in matches])
                    m, inl = cv2.estimateAffinePartial2D(src_pts, dst_pts, method=cv2.RANSAC,
                                                         ransacReprojThreshold=3.0)
                    if m is None or inl is None or int(inl.sum()) < 12 or not _sane(m):
                        m = None
                    else:
                        method = "orb"
        if m is None:
            (dx, dy), resp = cv2.phaseCorrelate(ref_low, g[y0:].astype(np.float32), win)
            if resp >= fallback_min_resp and math.hypot(dx, dy) <= fallback_max_shift:
                m = np.float32([[1, 0, -dx], [0, 1, -dy]])
                method = "phase"
        methods.append(method)
        if m is None:
            out.append(f)
            shifts.append(float("nan"))
            offsets.append(None)
            continue
        shifts.append(float(math.hypot(m[0, 2], m[1, 2])))
        offsets.append((float(m[0, 2]), float(m[1, 2])))
        out.append(cv2.warpAffine(f, m, (w, h), borderMode=cv2.BORDER_CONSTANT, borderValue=0))
        valid &= cv2.warpAffine(np.full((h, w), 255, np.uint8), m, (w, h), borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    valid = cv2.erode(valid, cv2.getStructuringElement(cv2.MORPH_RECT, (9, 9)))
    return StabiliseResult(frames=out, shifts_px=shifts, valid=valid, methods=methods, offsets=offsets)


def motion_masks(frames: list[np.ndarray], k: float = 6.0, valid: np.ndarray | None = None
                 ) -> tuple[np.ndarray, np.ndarray, float]:
    """回傳 (背景 uint8, 每幀運動遮罩 uint8 0/1 [N,H,W], 使用的門檻)。"""
    stack = np.stack([cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) for f in frames]).astype(np.float32)
    bg = np.median(stack, axis=0)
    resid = np.abs(stack - bg)
    # 背景殘差尺度：每個像素在時間上的 MAD，取整張的中位數當全域尺規
    # （葉片只佔少數幀，不影響中位；地板 1.0 避免全黑影片除以零）
    mad = np.median(np.abs(resid - np.median(resid, axis=0)), axis=0)
    sigma = float(max(np.median(mad) * 1.4826, 1.0))
    thr = k * sigma
    masks = (resid > thr).astype(np.uint8)
    if valid is not None:
        masks &= (valid > 0).astype(np.uint8)[None]
    # 刻意不做形態學開運算：葉尖只有幾個像素寬，3×3 的開運算會把葉尖整段吃掉，
    # 半徑就量短了。碎點交給 `hub_from_lines` 的 min_area 去濾。
    return bg.astype(np.uint8), masks, thr


def _line_key(cx: float, cy: float, dx: float, dy: float, theta_bin_deg: float, rho_bin_px: float) -> tuple[int, int]:
    """直線的 Hough 參數分箱 (θ, ρ)：同一條實體邊緣在每幀都落在同一箱。"""
    theta = math.atan2(dy, dx) % math.pi
    nx, ny = -math.sin(theta), math.cos(theta)  # 法向量
    rho = cx * nx + cy * ny
    return int(theta / math.radians(theta_bin_deg)), int(round(rho / rho_bin_px))


def background_edges(bg: np.ndarray, thresh: float = 24.0) -> np.ndarray:
    """靜態背景的強邊緣（塔架、地平線、建物輪廓）。穩像殘餘 1–4 px 會讓這些邊緣在每幀閃成細長段。"""
    gx = cv2.Sobel(bg, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(bg, cv2.CV_32F, 0, 1, ksize=3)
    mag = cv2.magnitude(gx, gy) / 4.0  # Sobel 3×3 的權重和是 4
    edges = (mag > thresh).astype(np.uint8)
    return cv2.dilate(edges, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))


def hub_from_lines(masks: np.ndarray, min_area: int = 30, min_elong: float = 3.0, sigma: float = 4.0,
                   through_px: float = 15.0, min_votes: float = 6.0, static_frac: float = 0.25,
                   min_angle_bins: int = 5, bg_edges: np.ndarray | None = None,
                   edge_frac_max: float = 0.5, refine: bool = True,
                   valid: np.ndarray | None = None) -> MotionHub:
    first = _hub_from_lines_once(masks, min_area, min_elong, sigma, through_px, min_votes, static_frac,
                                 min_angle_bins, bg_edges, edge_frac_max, valid)
    if not refine or not first.ok:
        return first
    # 第二回合：三片葉根在輪轂附近常黏成一個 Y 形元件（細長度不夠被丟掉，一幀就少三條線）。
    # 挖掉輪轂圓盤再算一次，元件拆成三條臂；線多了就採用，沒多就維持第一回合。
    n, h, w = masks.shape
    r0 = max(8, int(0.025 * max(h, w)))
    cut = masks.copy()
    for t in range(n):
        cv2.circle(cut[t], (int(round(first.hub[0])), int(round(first.hub[1]))), r0, 0, -1)
    second = _hub_from_lines_once(cut, min_area, min_elong, sigma, through_px, min_votes, static_frac,
                                  min_angle_bins, bg_edges, edge_frac_max, valid, radius_masks=masks)
    if second.ok and second.n_lines > first.n_lines and second.peak >= 0.8 * first.peak:
        second.notes.append(f"第二回合挖掉輪轂圓盤（r={r0}）後線數 {first.n_lines} → {second.n_lines}")
        return second
    return first


def _elongation(pts: np.ndarray) -> float:
    if len(pts) < 5:
        return 0.0
    ev = np.linalg.eigvalsh(np.cov((pts - pts.mean(axis=0)).T))
    return math.sqrt(ev[1] / ev[0]) if ev[0] > 1e-6 else 0.0


def _arm_pixels(mask: np.ndarray, min_area: int, min_elong: float) -> list[np.ndarray]:
    """一幀運動遮罩 → 細長臂的像素集合清單。

    三片葉根在輪轂附近常黏成一個 Y／星形元件（合成正視圖每幀都是：一個 17,710 px、
    細長度 1.7 的元件，一條線都取不到）。這裡不需要知道輪轂在哪：星形最厚的地方就是
    臂的交點（距離變換最大值），挖掉那一塊，剩下的就是幾條各自細長的臂。雲塊挖掉最厚點
    後剩的碎片不細長，自然沒有線。
    """
    out: list[np.ndarray] = []
    nc, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    for i in range(1, nc):
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area < min_area:
            continue
        comp = (lab == i)
        ys, xs = np.nonzero(comp)
        pts = np.column_stack([xs, ys]).astype(np.float32)
        if _elongation(pts) >= min_elong:
            out.append(pts)
            continue
        if area < 8 * min_area:
            continue
        # 不細長的大元件：挖掉最厚點再拆
        x0, y0, bw, bh = (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
                          int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))
        # 補一圈 0 再算距離變換：元件填滿整個外框（例如一整條地面帶）時裡面沒有任何 0，
        # OpenCV 會回無限大。
        sub = np.pad(comp[y0:y0 + bh, x0:x0 + bw].astype(np.uint8), 1)
        dt = cv2.distanceTransform(sub, cv2.DIST_L2, 5)
        cy, cx = np.unravel_index(int(np.argmax(dt)), dt.shape)
        r0 = max(6, int(2.5 * float(dt[cy, cx])))
        cut = sub.copy()
        cv2.circle(cut, (int(cx), int(cy)), r0, 0, -1)
        nc2, lab2, stats2, _ = cv2.connectedComponentsWithStats(cut, connectivity=8)
        for j in range(1, nc2):
            if stats2[j, cv2.CC_STAT_AREA] < min_area:
                continue
            ys2, xs2 = np.nonzero(lab2 == j)
            pts2 = np.column_stack([xs2 + x0 - 1, ys2 + y0 - 1]).astype(np.float32)
            if _elongation(pts2) >= min_elong:
                out.append(pts2)
    return out


def _hub_from_lines_once(masks: np.ndarray, min_area: int, min_elong: float, sigma: float,
                         through_px: float, min_votes: float, static_frac: float,
                         min_angle_bins: int, bg_edges: np.ndarray | None,
                         edge_frac_max: float, valid: np.ndarray | None = None,
                         radius_masks: np.ndarray | None = None) -> MotionHub:
    # 半徑一律在原始遮罩上量：第二回合傳進來的 masks 挖掉了第一回合輪轂附近的圓盤，
    # 在那上面量第一個候選的半徑會從第一個環就連續落空、量成十幾個像素，於是近處那台
    # 反而輸給遠處那台（Montrigaud 實測）。
    rmasks = masks if radius_masks is None else radius_masks
    n, h, w = masks.shape
    raw: list[tuple[float, float, float, float, np.ndarray, int]] = []
    n_on_edge = 0
    for t in range(n):
        for pts in _arm_pixels(masks[t], min_area, min_elong):
            if bg_edges is not None and float(bg_edges[pts[:, 1].astype(int), pts[:, 0].astype(int)].mean()) > edge_frac_max:
                # 元件大半坐在靜態邊緣上 = 邊緣閃爍，不是會動的東西。葉片掃過天空，
                # 只在越過塔架／地平線的那幾格碰到邊緣，比例遠低於一半。
                n_on_edge += 1
                continue
            mean = pts.mean(axis=0)
            ev, evec = np.linalg.eigh(np.cov((pts - mean).T))
            d = evec[:, 1]
            raw.append((float(mean[0]), float(mean[1]), float(d[0]), float(d[1]), pts, t))
    if not raw:
        return MotionHub(ok=False, notes=["沒有任何會動的細長元件——相機沒對到轉子，或轉子沒在轉"
                                          + (f"（{n_on_edge} 段是靜態邊緣的閃爍）" if n_on_edge else "")])

    # 靜態邊緣抑制：穩像殘餘 1–4 px 會讓塔架邊緣、地平線、遠處那排風機在每幀都閃成一條細長段，
    # 而且**每幀都是同一條線**（實測 abla 片段：塔架垂直線 × 地平線水平線的交點拿到 100 票，
    # 真輪轂 104 票）。葉片的線每幀角度都不同，同一箱只會在每轉回到同方位時被碰到。
    # 所以：同一 (θ, ρ) 箱出現在 > static_frac 的幀裡就是靜態邊緣，整箱丟掉。
    key_frames: dict[tuple[int, int], set[int]] = {}
    keys = []
    for cx, cy, dx, dy, pts, t in raw:
        k = _line_key(cx, cy, dx, dy, 3.0, 6.0)
        keys.append(k)
        key_frames.setdefault(k, set()).add(t)
    static_keys = {k for k, fr in key_frames.items() if len(fr) > static_frac * n}
    lines = [(cx, cy, dx, dy, pts) for (cx, cy, dx, dy, pts, t), k in zip(raw, keys) if k not in static_keys]
    n_static = len(raw) - len(lines) + n_on_edge
    if not lines:
        return MotionHub(ok=False, n_lines=0,
                         notes=[f"會動的細長段全是靜態邊緣的閃爍（{n_static} 段）——轉子可能沒在轉"])

    acc = np.zeros((h, w), np.float32)
    big = float(h + w)
    for cx, cy, dx, dy, _ in lines:
        p1 = (int(round(cx - dx * big)), int(round(cy - dy * big)))
        p2 = (int(round(cx + dx * big)), int(round(cy + dy * big)))
        layer = np.zeros((h, w), np.uint8)
        # 票數 = 1 條線一票，不依面積加權——否則地面上的大影子會壓過葉片
        cv2.line(layer, p1, p2, 1, 3)
        acc += layer
    accs = cv2.GaussianBlur(acc, (0, 0), sigma)

    def _support(px: float, py: float) -> list[tuple[float, float, float, float, np.ndarray]]:
        return [ln for ln in lines if abs((px - ln[0]) * ln[3] - (py - ln[1]) * ln[2]) <= through_px]

    def _angle_bins(sup) -> int:
        # 通過此點的線覆蓋幾個 15° 方向箱（共 12 箱）：轉子掃過所有方向，兩條靜態邊緣的交點只有 2 箱
        return len({int((math.atan2(dy, dx) % math.pi) / math.radians(15)) for _, _, dx, dy, _ in sup})

    # 取前三個峰，要求方向多樣性，再依票數排
    sup_map = accs.copy()
    cands = []
    for _ in range(3):
        hy, hx = np.unravel_index(int(np.argmax(sup_map)), sup_map.shape)
        v = float(sup_map[hy, hx])
        if v < min_votes:
            break
        sup = _support(float(hx), float(hy))
        cands.append((v, float(hx), float(hy), sup, _angle_bins(sup)))
        cv2.circle(sup_map, (int(hx), int(hy)), 60, 0, -1)
    if not cands:
        return MotionHub(ok=False, n_lines=len(lines), peak=float(accs.max()),
                         notes=[f"共點票數太少（{accs.max():.1f} < {min_votes}）——會動的細長段不夠多，轉子可能沒在轉或畫面太小"])
    diverse = [c for c in cands if c[4] >= min_angle_bins]
    notes = []
    if not diverse:
        return MotionHub(ok=False, n_lines=len(lines), peak=cands[0][0],
                         notes=[f"最強的共點只有 {cands[0][4]} 個方向箱（需 ≥ {min_angle_bins}）——那是兩條靜態邊緣的交點，不是轉子"])
    if diverse[0] is not cands[0]:
        notes.append("票數最高的共點方向單一，改取次高但方向多樣的那個")
    # 票數相近（≥ 0.6× 主峰）的候選之間，取**有效半徑最大**的那個。取像規格是「單台主風機、
    # 整個轉子在框內」，主風機一定是畫面裡最大的轉子；遠處那台票數可能一樣多（線多但短），
    # 半徑分得開（Montrigaud 兩台同框實測：只看票數會選到遠處那台）。
    # 有效半徑 = min(佔有率半徑, 1.3 × 支持段最遠點的中位數)：佔有率半徑會被滿天快雲撐大
    # （Lawrence Weston 實測：雲團假中心 r_occ=220 但支持段只伸到 37 px；真輪轂 144 vs 101），
    # 掃過的範圍不可能超過支持它的葉片段實際伸到的地方。
    comparable = [c for c in diverse if c[0] >= 0.6 * diverse[0][0]]
    scored = []
    for c in comparable:
        r_occ = rotor_radius_from_occupancy(rmasks, (c[1], c[2]), valid=valid)
        far_med = float(np.median([np.hypot(p[:, 0] - c[1], p[:, 1] - c[2]).max() for *_, p in c[3]])) if c[3] else 0.0
        scored.append((min(r_occ, 1.3 * far_med), r_occ, far_med, c))
    scored.sort(key=lambda x: (-x[0], -x[3][0]))
    r_eff, rotor_r, far_med, chosen = scored[0]
    if chosen is not diverse[0]:
        top = next(x for x in scored if x[3] is diverse[0])
        notes.append(f"票數相近的候選有 {len(comparable)} 個，改取有效半徑最大的（{r_eff:.0f} px vs 票數最高者 {top[0]:.0f} px）")
    if len(comparable) > 1:
        notes.append("畫面裡有第二個放射中心（另一台風機或移動的雲）——結果以最大的轉子為主風機，建議人工確認")
    if rotor_r > 2.0 * far_med > 0:
        notes.append(f"佔有率半徑（{rotor_r:.0f} px）遠大於支持段伸到的距離（{far_med:.0f} px）——畫面裡有大範圍的其他運動（雲），半徑可能偏大")
    peak, hx, hy, sup, bins = chosen
    second = next((c[0] for c in cands if c is not chosen), 0.0)
    if len(comparable) == 1 and second > 0 and peak / second < 1.3:
        notes.append("票圖有第二個放射中心（另一台風機或地面影子）——建議人工確認輪轂位置")
    if n_static:
        notes.append(f"抑制了 {n_static} 段靜態邊緣的閃爍")
    return MotionHub(ok=True, hub=(hx, hy), rotor_r_px=rotor_r, peak=peak, second_peak=second,
                     n_lines=len(lines), n_lines_through_hub=len(sup), notes=notes)


def rotor_radius_from_occupancy(masks: np.ndarray, hub: tuple[float, float], dr: float = 4.0,
                                n_angle_bins: int = 36, min_coverage: float = 0.7,
                                valid: np.ndarray | None = None) -> float:
    """轉子半徑 = 以輪轂為圓心往外走，「每個方向都有東西動過」的最後一個環。

    轉子內側的環，三片在 N 幀裡掃過所有方向，每個角度格都累積得到一整條葉片寬的像素-幀數；
    轉子外側只剩雲、草、噪點，動的東西在角度上是聚集的。判「這一格有沒有被掃過」用的是
    像素-幀數對雜訊期望值的倍數，不是佔有率大小——葉尖本來就細（佔有率低），單看佔有率會在
    葉尖之前就停。雜訊底取有效區域佔有率的 20 百分位（真正靜止的像素），**不取中位數**：
    轉子佔畫面大半時中位數就是轉子本身（合成正視圖實測：中位 = 1/N，正好每個像素被掃一次）。
    出框的部分（仰拍時葉尖在畫面外）只算在畫面內的角度格。
    """
    n, h, w = masks.shape
    counts = masks.sum(axis=0).astype(np.float32)  # 每個像素被判「在動」的幀數
    region = (valid > 0) if valid is not None else np.ones((h, w), bool)
    floor = float(np.quantile(counts[region] / n, 0.2)) if region.any() else 0.0
    yy, xx = np.mgrid[0:h, 0:w]
    rr = np.hypot(xx - hub[0], yy - hub[1])
    ang = np.arctan2(yy - hub[1], xx - hub[0])
    abin = ((ang + math.pi) / (2 * math.pi) * n_angle_bins).astype(int) % n_angle_bins
    rmax = float(rr.max())
    radius = 0.0
    r = dr
    misses = 0
    while r < rmax:
        ring = (rr >= r) & (rr < r + dr) & region
        if not ring.any():
            break
        bins_in = np.bincount(abin[ring], minlength=n_angle_bins)
        hits_in = np.bincount(abin[ring], weights=counts[ring], minlength=n_angle_bins)
        present = bins_in > 0
        expected = floor * n * bins_in
        hit = present & (hits_in >= np.maximum(3.0, 2.5 * expected))
        coverage = hit.sum() / max(int(present.sum()), 1)
        if coverage >= min_coverage:
            radius = r + dr
            misses = 0
        else:
            misses += 1
            if misses >= 3:  # 連續三個環都不像轉子才停（被塔架／機艙遮住的環不該提早停）
                break
        r += dr
    return radius


def locate_hub(frames: list[np.ndarray]) -> tuple[MotionHub, StabiliseResult, np.ndarray]:
    """一步到位：對齊 → 運動遮罩 → 共點。回傳 (結果, 對齊資訊, 背景圖)。"""
    st = stabilise(frames)
    bg, masks, _ = motion_masks(st.frames, valid=st.valid)
    return hub_from_lines(masks, bg_edges=background_edges(bg), valid=st.valid), st, bg

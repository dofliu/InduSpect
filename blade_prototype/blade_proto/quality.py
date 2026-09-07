"""拍攝品質閘門：把「安靜給出錯答案」變成「明確拒收」。

真實影像驗證（`REAL_IMAGE_VALIDATION.md`）量到的問題不是演算法偶爾算錯，而是它
**算錯的時候看起來和算對的時候一樣**：輪轂落在穀倉屋頂上、地平線殘塊被當成第三片
葉片，`find_structure` 一樣回傳一個三葉結構，三片互比一樣吐出一組數字。現場操作者
看不出差別，報告也不會告訴他。

這支模組在結構定位之後、幾何互比之前擋一道。它不判斷葉片好壞，只判斷**這張照片
能不能拿來判斷**。判定失敗時要給的是「怎麼重拍」，不是「這台風機沒問題」。

門檻取自 45 張真實照片（set A）的量測，並在另外 30 張（set B holdout）上覆核；
兩批的分佈與逐項效果見 `REAL_IMAGE_VALIDATION.md`。
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .segmentation import find_second_rotor


# 地平線以上、非天空像素占該區域的比例。整台風機對著天空拍只有幾個百分點；超過就
# 表示雲層/建物/地形進了遮罩。這條**只發警告不拒收**——見 assess_capture 內的說明。
MAX_MASK_FRAC = 0.15
# 三片葉尖半徑的離散度上限（(max−min)/median）。同一台風機三片等長，真實照片上
# 正確定位時 ≤12%；抓到地物、電線或別台風機當葉片時會跳到 23% 以上，而且沒有中間值。
# 這是整個閘門唯一真正有鑑別力的條件：75 張真實照片上它零誤放行。
MAX_RADIUS_SPREAD = 0.15
# 第二個轉子的半徑相對主風機的比例，超過就發**取景歧義警告**（不拒收，見 assess_capture）。
# 0.5 = 「大小相當」，警告不需要拒收那種精度。
SECOND_ROTOR_WARN_RATIO = 0.5
# 前景太少代表風機根本沒被分出來（白葉片對上亮雲天空）。
MIN_MASK_FRAC = 0.0015


@dataclass
class CaptureVerdict:
    """拍攝品質判定。ok=False 時**不得**進行三片互比或產生幾何結論。"""

    ok: bool
    reasons: list[str] = field(default_factory=list)   # 拒收原因（含重拍建議）
    warnings: list[str] = field(default_factory=list)  # 可用但要降權
    metrics: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {"ok": self.ok, "reasons": list(self.reasons),
                "warnings": list(self.warnings), "metrics": dict(self.metrics)}


def _spread(values: list[float]) -> float:
    if len(values) < 2:
        return float("nan")
    med = float(np.median(values))
    if med <= 1e-6:
        return float("inf")
    return float(np.ptp(values) / med)


def assess_capture(
    seg=None,
    structure=None,
    error: BaseException | str | None = None,
    *,
    n_blades_expected: int = 3,
    max_mask_frac: float = MAX_MASK_FRAC,
    min_mask_frac: float = MIN_MASK_FRAC,
    max_radius_spread: float = MAX_RADIUS_SPREAD,
    second_rotor_ratio: float = SECOND_ROTOR_WARN_RATIO,
    check_second_rotor: bool = True,
) -> CaptureVerdict:
    """判斷一張全機照能不能拿來做幾何互比。

    seg：`segment_turbine` 的結果；structure：`find_structure` 的結果（丟例外時傳 None
    並把例外放在 error）。任何一項不過就直接拒收——這裡寧可錯殺，因為放行一張
    定位錯誤的照片，代價是一份看起來合格的錯誤報告。
    """
    reasons: list[str] = []
    warnings: list[str] = []
    metrics: dict = {}

    if error is not None:
        reasons.append(f"結構定位失敗（{error}）：多半是天空模型被雲層或前景物撐壞，"
                       "請找雲量少的時段、讓風機正對乾淨天空重拍")
        return CaptureVerdict(False, reasons, warnings, metrics)

    if seg is not None:
        # 只看地平線以上：結構定位本來就只用這一區（`find_structure(horizon_y=...)`），
        # 把地面算進來會讓「風機拍得乾淨、但地面剛好入鏡」的照片被誤擋。
        sky = seg.mask if seg.horizon_y is None else seg.mask[:seg.horizon_y]
        frac = float((sky > 0).mean()) if sky.size else 1.0
        metrics["mask_area_frac"] = round(float((seg.mask > 0).mean()), 4)
        metrics["sky_mask_frac"] = round(frac, 4)
        metrics["horizon_y"] = seg.horizon_y
        if frac < min_mask_frac:
            reasons.append(f"畫面上幾乎分不出風機（前景僅 {frac * 100:.2f}%）："
                           "白色葉片對上亮雲天空對比不足，請換角度讓葉片背景是純天空")
        elif frac > max_mask_frac:
            # 只給警告不拒收：75 張真實照片的門檻掃描顯示，這條規則擋掉的錯誤案例
            # 全部已經被下面的葉尖半徑規則擋掉，自己額外擋掉的只有一張正確案例
            # （309348db，岩石地面讓地平線以上仍有 20% 前景）。詳見 REAL_IMAGE_VALIDATION.md。
            warnings.append(f"地平線以上的前景占 {frac * 100:.0f}%（一般 <{max_mask_frac * 100:.0f}%）："
                            "雲層、建物或地形可能被當成風機，判定結果請降權看待")

    if structure is None:
        if not reasons:
            reasons.append("沒有結構定位結果")
        return CaptureVerdict(False, reasons, warnings, metrics)

    n = len(structure.blades)
    metrics["n_blades"] = n
    if n != n_blades_expected:
        reasons.append(f"只定位到 {n} 片葉片（應為 {n_blades_expected}）："
                       "可能有葉片正好貼在塔架上（六點鐘方位）或沒入雲層，"
                       "請等轉子轉到三片都離開塔架再拍")

    radii = [float(b.tip_radius_px) for b in structure.blades]
    metrics["tip_radii_px"] = [round(r, 1) for r in radii]
    if len(radii) >= 2:
        sp = _spread(radii)
        metrics["tip_radius_spread"] = round(sp, 3)
        if sp > max_radius_spread:
            reasons.append(f"三片葉尖半徑差 {sp * 100:.0f}%（上限 {max_radius_spread * 100:.0f}%）："
                           "同一台風機三片等長，差這麼多代表有一片其實是地物、電線或別台風機，"
                           "請重拍並確保只有一台風機在框內")

    if seg is not None and seg.horizon_y is not None:
        below = [i for i, b in enumerate(structure.blades) if b.tip_xy[1] >= seg.horizon_y]
        if below:
            reasons.append(f"第 {'、'.join(str(i + 1) for i in below)} 片的葉尖落在地平線以下："
                           "抓到的不是葉片，請重拍")

    # 取景歧義：畫面裡有第二個轉子時，演算法有可能乾淨地鎖上「不是操作者要量的那一台」。
    # 這一條**只發警告不拒收**，理由是量出來的：75 張真實照片上閘門本來就沒有誤放行
    # ——multi 照片全部被上面的半徑離散規則擋下（兩台等大同框時三片候選會混到兩台身上，
    # 半徑自然不一致），所以再加一條拒收只有代價沒有收益：ratio > 0.5 會擋掉 8 張正確
    # 放行中的 2 張。詳見 REAL_IMAGE_VALIDATION.md §6。警告則零代價，而且講的是事實。
    if check_second_rotor and seg is not None and radii:
        r2, n2 = find_second_rotor(seg.mask, structure, getattr(seg, "horizon_y", None))
        r1 = float(np.median(radii))
        metrics["second_rotor_radius_px"] = round(r2, 1)
        metrics["second_rotor_arms"] = n2
        if r1 > 1.0:
            ratio = r2 / r1
            metrics["second_rotor_ratio"] = round(ratio, 3)
            if ratio >= second_rotor_ratio:
                warnings.append(
                    f"畫面裡還有另一個轉子，半徑約為主風機的 {ratio * 100:.0f}%："
                    "請確認量到的是要量的那一台；風場的風機外觀相同，量錯對象不會有任何徵兆")

    if not structure.tower_found:
        warnings.append("沒有找到塔架：塔架傾斜與六點鐘方位判讀不可用（幾何互比仍可進行）")
    if not structure.hub_refined:
        warnings.append("輪轂只有初估、未經葉片軸線精修：葉尖偏移量的精度會下降")
    for note in structure.notes:
        if "超過 4×hub_r" in note or "共線" in note:
            warnings.append(f"結構定位提示：{note}")

    return CaptureVerdict(not reasons, reasons, warnings, metrics)

"""拍攝品質閘門（`quality.py`）與地平線偵測（`segmentation.find_horizon`）。

驗的是「錯的時候要說出來」：真實影像驗證量到的問題是定位錯誤時輸出看起來正常，
所以這裡的每個案例都對應一種真實照片上量到的失敗模式。
"""

import numpy as np
import pytest

from blade_proto.quality import CaptureVerdict, assess_capture
from blade_proto.segmentation import (SegmentationResult, SkyModel, find_horizon,
                                      find_structure, segment_turbine)
from blade_proto.synth import SceneSpec, render_front


class _Blade:
    def __init__(self, r, tip=(0.0, 0.0)):
        self.tip_radius_px = r
        self.tip_xy = tip


class _Structure:
    def __init__(self, radii, tips=None, tower=True, refined=True, notes=()):
        tips = tips or [(0.0, 0.0)] * len(radii)
        self.blades = [_Blade(r, t) for r, t in zip(radii, tips)]
        self.tower_found = tower
        self.hub_refined = refined
        self.notes = list(notes)


def _seg(mask):
    model = SkyModel(np.zeros((3, 4), np.float32), np.ones(3, np.float32))
    h = find_horizon(mask)
    return SegmentationResult(mask=mask, sky_model=model, threshold=5.5, scale=1.0, horizon_y=h)


def _mask_with_ground(h=200, w=300, ground_frac=0.25, tower=True):
    m = np.zeros((h, w), np.uint8)
    m[int(h * (1 - ground_frac)):, :] = 255            # 整列都是前景的地面帶
    if tower:
        m[int(h * 0.2):, w // 2 - 4:w // 2 + 4] = 255  # 塔架與地面相連
    return m


# ------------------------------------------------------------------ 地平線


def test_find_horizon_locates_ground_band_connected_to_tower():
    """真實照片的地面常和塔架連成同一元件，`drop_wide_bands` 的寬矮規則抓不到；
    地平線靠「整列填充率」找，塔架穿過去也不影響。"""
    m = _mask_with_ground(ground_frac=0.25)
    y = find_horizon(m)
    assert y is not None and 0.72 * 200 <= y <= 0.78 * 200


def test_find_horizon_returns_none_for_pure_sky_shot():
    """整張都是天空（仰角拍攝）就沒有地平線可切，不能亂切掉葉尖。"""
    m = np.zeros((200, 300), np.uint8)
    m[40:160, 145:155] = 255
    assert find_horizon(m) is None


def test_find_horizon_refuses_when_ground_swallows_the_frame():
    """地面吃掉大半畫面時天空模型多半已經壞了，回 None 讓上層據實反映，而不是硬切。"""
    assert find_horizon(_mask_with_ground(ground_frac=0.85, tower=False)) is None


def test_horizon_keeps_structure_out_of_the_ground():
    """合成正視照人工貼上地面帶：不給 horizon_y 時輪轂被地面拉走，給了就回到轉子上。"""
    img, _ = render_front(SceneSpec(cm_per_px=12.0, azimuth_deg=90.0, seed=5))
    seg = segment_turbine(img)
    h = seg.mask.shape[0]
    ground = seg.mask.copy()
    ground[int(h * 0.82):, :] = 255
    hub_naive = find_structure(ground).hub
    hub_cut = find_structure(ground, horizon_y=find_horizon(ground)).hub
    truth = find_structure(seg.mask).hub
    assert np.hypot(*(np.array(hub_cut) - truth)) < np.hypot(*(np.array(hub_naive) - truth))


# ------------------------------------------------------------------ 閘門


def test_gate_rejects_when_structure_raised():
    v = assess_capture(None, None, ValueError("遮罩為空，無法定位結構"))
    assert not v.ok and "重拍" in v.reasons[0]


def test_gate_rejects_uneven_tip_radii_the_fake_blade_signature():
    """三片等長是物理事實；半徑差幾十趴代表其中一片是地物、電線或別台風機。
    75 張真實照片上這條是唯一零誤放行的條件。"""
    v = assess_capture(_seg(_mask_with_ground()), _Structure([220.0, 214.0, 96.0]))
    assert not v.ok
    assert any("葉尖半徑差" in r for r in v.reasons)
    assert v.metrics["tip_radius_spread"] > 0.15


def test_gate_accepts_three_consistent_blades():
    v = assess_capture(_seg(_mask_with_ground(ground_frac=0.1)), _Structure([220.0, 214.0, 219.0]))
    assert v.ok and not v.reasons


def test_gate_rejects_wrong_blade_count_and_says_why():
    v = assess_capture(_seg(_mask_with_ground()), _Structure([220.0, 214.0]))
    assert not v.ok
    assert any("只定位到 2 片" in r and "塔架" in r for r in v.reasons)


def test_gate_rejects_when_turbine_barely_segmented():
    """白葉片對上亮雲天空時遮罩幾乎全空——要說「對比不足」，不是回報三片一致。"""
    m = np.zeros((400, 600), np.uint8)
    m[10:14, 10:14] = 255
    v = assess_capture(_seg(m), _Structure([100.0, 101.0, 99.0]))
    assert not v.ok and any("對比不足" in r for r in v.reasons)


def test_gate_flags_blade_tip_below_horizon():
    m = _mask_with_ground(ground_frac=0.25)
    st = _Structure([220.0, 218.0, 221.0], tips=[(10.0, 20.0), (30.0, 25.0), (40.0, 190.0)])
    v = assess_capture(_seg(m), st)
    assert not v.ok and any("地平線以下" in r for r in v.reasons)


def test_large_foreground_is_a_warning_not_a_rejection():
    """門檻掃描顯示這條額外擋掉的只有正確案例，錯誤案例已被半徑規則擋下，故降為警告。"""
    m = np.zeros((200, 300), np.uint8)
    m[:120, :] = 255          # 地平線以上一大片前景（雲層/建物）
    m[150:, :] = 255          # 地面帶
    v = assess_capture(_seg(m), _Structure([220.0, 216.0, 219.0]))
    assert v.ok
    assert any("前景占" in w for w in v.warnings)


def test_gate_warns_but_passes_without_tower():
    v = assess_capture(_seg(_mask_with_ground(ground_frac=0.1)),
                       _Structure([220.0, 214.0, 219.0], tower=False, refined=False))
    assert v.ok
    assert any("沒有找到塔架" in w for w in v.warnings)
    assert any("未經葉片軸線精修" in w for w in v.warnings)


def test_verdict_serialises_for_the_report():
    v = assess_capture(_seg(_mask_with_ground(ground_frac=0.1)), _Structure([220.0, 214.0, 219.0]))
    d = v.to_dict()
    assert set(d) == {"ok", "reasons", "warnings", "metrics"}
    assert isinstance(d["metrics"]["tip_radii_px"], list)

"""拍攝品質閘門（`quality.py`）與地平線偵測（`segmentation.find_horizon`）。

驗的是「錯的時候要說出來」：真實影像驗證量到的問題是定位錯誤時輸出看起來正常，
所以這裡的每個案例都對應一種真實照片上量到的失敗模式。
"""

import cv2
import numpy as np
import pytest

from blade_proto.quality import (SIDE_VIEW_MAX_TILT_DEG, CaptureVerdict, assess_capture,
                                 detect_side_view)
from blade_proto.segmentation import (SegmentationResult, SkyModel, find_horizon,
                                      find_second_rotor, find_structure, segment_turbine)
from blade_proto.synth import SceneSpec, render_front, render_side


class _Blade:
    """假葉片。`xs`/`ys` 是真結構會有的像素索引——第二轉子檢查要靠它認出「哪些元件
    是已定位的風機自己」，所以 stub 也得有，不能讓安全檢查因為缺屬性而被跳過。"""

    def __init__(self, r, tip=(0.0, 0.0), pixels=None, angle=0.0):
        self.tip_radius_px = r
        self.tip_xy = tip
        self.tip_angle_deg = angle  # 數學慣例，270° = 六點鐘；預設 0°（朝右）不會被當成側視
        px = pixels if pixels is not None else [(int(tip[0]), int(tip[1]))]
        self.xs = np.array([p[0] for p in px], dtype=np.int64)
        self.ys = np.array([p[1] for p in px], dtype=np.int64)


class _Structure:
    def __init__(self, radii, tips=None, tower=True, refined=True, notes=(), hub=(150.0, 60.0), angles=None):
        tips = tips or [(0.0, 0.0)] * len(radii)
        angles = angles or [0.0] * len(radii)
        self.blades = [_Blade(r, t, angle=a) for r, t, a in zip(radii, tips, angles)]
        self.tower_found = tower
        self.hub_refined = refined
        self.hub = hub
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


# ------------------------------------------------------------ 取景歧義（第二個轉子）


def _two_turbine_mask(h=400, w=700, second_scale=1.0):
    """兩台風機的遮罩：左邊是主風機，右邊按 second_scale 縮放。"""
    m = np.zeros((h, w), np.uint8)

    def turbine(cx, r, tower_h):
        cv2.circle(m, (cx, 120), max(4, int(r * 0.09)), 255, -1)          # 機艙
        for ang in (90, 210, 330):                                        # 三片
            t = np.deg2rad(ang)
            cv2.line(m, (cx, 120), (int(cx + r * np.cos(t)), int(120 - r * np.sin(t))),
                     255, max(2, int(r * 0.05)))
        cv2.line(m, (cx, 120), (cx, 120 + tower_h), 255, max(3, int(r * 0.07)))

    turbine(180, 90, 240)
    if second_scale > 0:
        turbine(520, int(90 * second_scale), int(240 * second_scale))
    return m


def test_second_rotor_is_found_only_when_a_second_turbine_is_there():
    for scale, expect in ((0.0, False), (1.0, True)):
        mask = _two_turbine_mask(second_scale=scale)
        st = find_structure(mask)
        r2, n2 = find_second_rotor(mask, st)
        assert (n2 > 0) is expect, f"second_scale={scale} 得到 n2={n2}"
        if expect:
            r1 = float(np.median([b.tip_radius_px for b in st.blades]))
            assert r2 / r1 > 0.5, f"等大的第二台應該量到相當的半徑，得到 {r2}/{r1}"


def test_framing_ambiguity_is_a_warning_not_a_rejection():
    """量出來的結論：閘門本來就沒有誤放行（multi 照片全被半徑離散擋下），
    所以再加一條拒收只會擋掉正確案例。警告零代價，而且講的是事實。"""
    mask = _two_turbine_mask(second_scale=1.0)
    st = find_structure(mask)
    v = assess_capture(_seg(mask), st)
    assert v.ok, v.reasons                       # 不因為取景歧義而拒收
    assert any("另一個轉子" in w for w in v.warnings)
    assert "確認量到的是要量的那一台" in " ".join(v.warnings)
    assert v.metrics["second_rotor_ratio"] >= 0.5


def test_no_framing_warning_for_a_lone_turbine():
    mask = _two_turbine_mask(second_scale=0.0)
    v = assess_capture(_seg(mask), find_structure(mask))
    assert not any("另一個轉子" in w for w in v.warnings)
    assert v.metrics["second_rotor_arms"] == 0


def test_distant_other_turbine_does_not_trigger_the_warning():
    """遠處的他機是合法取景（75 張裡很多張都有）——半徑遠小於主風機，不該警告。"""
    mask = _two_turbine_mask(second_scale=0.25)
    v = assess_capture(_seg(mask), find_structure(mask))
    assert v.metrics["second_rotor_ratio"] < 0.5
    assert not any("另一個轉子" in w for w in v.warnings)


def test_second_rotor_check_can_be_skipped_for_cost():
    """它要多跑一次結構定位；逐幀分析影片時呼叫端可以關掉。"""
    mask = _two_turbine_mask(second_scale=1.0)
    v = assess_capture(_seg(mask), find_structure(mask), check_second_rotor=False)
    assert "second_rotor_ratio" not in v.metrics
    assert not any("另一個轉子" in w for w in v.warnings)


# ------------------------------------------------------------------ 側視（§13-12）
# 規格 §5.1 的側視模式（垂掛葉片量 flapwise 彎曲）原本會被「葉片數 ≠ 3」與「半徑離散」
# 兩條正視規則拒收（BLADE_TEST_REPORT.md §4.2）。側視另走一組規則，但判定側視要嚴：
# 恰好兩片、一上一下、都在垂直 ±12° 內、塔架找到。12° 是拿 75 張真實照片定的——
# ≤12° 沒有任何一張命中，所以真實影像的閘門結果一張都不變。


def test_side_view_two_vertical_blades_skips_three_blade_rules():
    v = assess_capture(_seg(_mask_with_ground(ground_frac=0.1)),
                       _Structure([300.0, 150.0], angles=[270.0, 90.0]))
    assert v.ok, v.reasons
    assert v.metrics["view"] == "side" and v.metrics["hanging_blade_index"] == 0
    assert v.metrics["tip_radius_spread"] > 0.15, "離散度照記錄，只是不拿來判"
    assert any("側視" in w and "互比不適用" in w for w in v.warnings), v.warnings


def test_side_view_needs_one_up_and_one_down():
    v = assess_capture(_seg(_mask_with_ground()), _Structure([300.0, 150.0], angles=[90.0, 92.0]))
    assert not v.ok and any("只定位到 2 片" in r for r in v.reasons)
    assert v.metrics["view"] == "front"


def test_oblique_view_is_not_side_view():
    """1573f056（真實照片，標註「轉子近側視」）兩片是 6.6° 與 19.2°——斜視不是側視，
    垂掛葉片的彎曲含透視分量，放行只會多一個假訊號來源。"""
    v = assess_capture(_seg(_mask_with_ground()), _Structure([277.0, 215.8], angles=[289.2, 83.4]))
    assert not v.ok and v.metrics["view"] == "front"


def test_side_view_requires_tower():
    v = assess_capture(_seg(_mask_with_ground()),
                       _Structure([300.0, 150.0], angles=[270.0, 90.0], tower=False))
    assert not v.ok and v.metrics["view"] == "front"


def test_single_hanging_blade_is_not_side_view():
    """單獨一根垂直的東西也可能是桿子、桅杆或被雲切掉的別台風機。"""
    v = assess_capture(_seg(_mask_with_ground()), _Structure([300.0], angles=[270.0]))
    assert not v.ok and v.metrics["view"] == "front"
    assert detect_side_view(_Structure([300.0], angles=[270.0])) is None


def test_side_view_tilt_threshold_is_pinned():
    assert SIDE_VIEW_MAX_TILT_DEG == 12.0
    assert detect_side_view(_Structure([300.0, 150.0], angles=[270.0 + 12.0, 90.0])) == 0
    assert detect_side_view(_Structure([300.0, 150.0], angles=[270.0 + 12.5, 90.0])) is None


def test_synthetic_side_view_passes_the_gate_end_to_end():
    """合成側視照（葉片 A 垂掛在六點鐘）整條路：分割 → 結構 → 閘門放行、標成側視。"""
    img, _ = render_side(SceneSpec.for_scale(6.0, "side", (1500, 2000), seed=1))
    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    v = assess_capture(seg, st)
    assert v.ok, v.reasons
    assert v.metrics["view"] == "side"
    hang = st.blades[v.metrics["hanging_blade_index"]]
    assert abs(((hang.tip_angle_deg - 270.0) + 180) % 360 - 180) < SIDE_VIEW_MAX_TILT_DEG

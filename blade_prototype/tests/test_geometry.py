"""幾何層（§5.3）：彎曲係數與三片互比。"""

import cv2
import numpy as np
import pytest

from blade_proto.synth import SceneSpec, render_front, render_side
from blade_proto.segmentation import segment_turbine, find_structure
from blade_proto.cli import _analyze_still_payload
from blade_proto.geometry import (compare_blades, compare_metric, profiles_from_structure,
                                  side_view_summary)
from blade_proto.quality import assess_capture


def _profiles(spec, view="front"):
    img, truth = (render_front if view == "front" else render_side)(spec)
    st = find_structure(segment_turbine(img).mask)
    return profiles_from_structure(st), truth


def test_clean_rotor_not_flagged():
    for seed in range(3):
        profs, _ = _profiles(SceneSpec(seed=seed))
        assert len(profs) == 3
        cmp_ = compare_blades(profs, noise_floor_px=1.5)
        defl = [c for c in cmp_["comparisons"] if c["metric"] == "tip_deflection_px"][0]
        assert not defl["flagged"], defl
        assert max(abs(v) for v in defl["values"]) < 2.0


def test_deflected_blade_flagged_with_correct_magnitude():
    # 12 cm/px：600 cm = 50 px
    profs, truth = _profiles(SceneSpec(azimuth_deg=90, tip_deflection_cm=(600, 0, 0)))
    cmp_ = compare_blades(profs, noise_floor_px=1.5, cm_per_px=12.0)
    defl = [c for c in cmp_["comparisons"] if c["metric"] == "tip_deflection_px"][0]
    assert defl["flagged"]
    outlier = profs[defl["outlier_index"]]
    assert abs(outlier.axis_angle_deg - 90) < 10  # 被偏移的是正上方那片
    assert abs(defl["outlier_deviation"] - 50.0) < 5.0
    assert abs(defl["outlier_deviation_cm"] - 600.0) < 60.0


def test_deflected_blade_in_wedge_configuration():
    """葉片與塔架夾 30° 的配置下，偏移 25 px 的葉片仍被正確標出。"""
    profs, _ = _profiles(SceneSpec(azimuth_deg=60, tip_deflection_cm=(0, 300, 0)))
    cmp_ = compare_blades(profs, noise_floor_px=1.5)
    defl = [c for c in cmp_["comparisons"] if c["metric"] == "tip_deflection_px"][0]
    assert defl["flagged"]
    assert abs(profs[defl["outlier_index"]].axis_angle_deg - 180) < 10
    assert abs(defl["outlier_deviation"] - 25.0) < 4.0


def test_side_view_hanging_blade_bend():
    """側視：垂掛葉片彎曲係數 = 預彎 + 額外偏移，兩者差異可量測。"""
    def hanging(spec):
        profs, truth = _profiles(spec, "side")
        h = [p for p in profs if abs(p.axis_angle_deg - 270) < 10]
        assert len(h) == 1
        return h[0].tip_deflection_px, truth

    b0, t0 = hanging(SceneSpec(seed=1, azimuth_deg=270.0))
    b1, t1 = hanging(SceneSpec(seed=1, azimuth_deg=270.0, tip_deflection_cm=(100, 0, 0)))
    assert abs(abs(b0) - t0["prebend_px"]) < 0.25 * t0["prebend_px"]
    assert abs((b1 - b0) - t1["tip_deflection_px"] * np.sign(b0)) < 3.0


def test_compare_metric_outlier_logic():
    c = compare_metric("m", [0.0, 0.2, 10.0], noise_floor=1.0)
    assert c.outlier_index == 2 and c.flagged
    c = compare_metric("m", [0.0, 5.0, 10.0], noise_floor=1.0)
    assert not c.flagged  # 三片彼此差距相近，沒有單一離群
    c = compare_metric("m", [0.0, 0.1, 0.2], noise_floor=1.0)
    assert not c.flagged


# ---------------------------------------------------------------- 側視（§13-12）


def _side_scene(defl_cm=(0, 0, 0), seed=1):
    """葉片 A（index 0）垂掛在六點鐘的合成側視照；6 cm/px、1500×2000（轉子 1000 px 塞得進）。"""
    spec = SceneSpec.for_scale(6.0, "side", (1500, 2000), tip_deflection_cm=defl_cm, seed=seed)
    img, truth = render_side(spec)
    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    # 側視是宣告制（2026-09-28，SPEC §13-16）：真側視也要宣告才走側視規則
    return img, truth, st, assess_capture(seg, st, expected_view="side")


def test_side_view_summary_reports_hanging_blade_without_comparisons():
    _, _, st, v = _side_scene()
    assert v.metrics["view"] == "side"
    profs = profiles_from_structure(st)
    s = side_view_summary(profs, v.metrics["hanging_blade_index"], rotor_radius_m=60.0)
    assert s["view"] == "side" and s["comparisons"] == [] and s["any_flagged"] is False
    hb = s["hanging_blade"]
    assert abs(((hb["axis_angle_deg"] - 270.0) + 180) % 360 - 180) < 12
    assert abs(s["cm_per_px"] - 6.0) < 0.6, "垂掛葉片投影長度 ≈ 轉子半徑，反推的尺度要對"
    assert "tip_deflection_cm" in hb and "互比不適用" in s["note"]


def test_side_view_bend_recovers_injected_deflection():
    """垂掛那片多 50 cm 偏移 → 6 cm/px 下 8.3 px。單幀含預彎，所以比的是兩幀的差。"""
    _, _, st0, v0 = _side_scene()
    _, _, st1, v1 = _side_scene(defl_cm=(50, 0, 0))
    p0 = profiles_from_structure(st0)[v0.metrics["hanging_blade_index"]]
    p1 = profiles_from_structure(st1)[v1.metrics["hanging_blade_index"]]
    assert abs(abs(p1.tip_deflection_px - p0.tip_deflection_px) - 50.0 / 6.0) < 1.5


def test_analyze_still_payload_uses_side_summary_for_side_view(tmp_path):
    img, _, _, _ = _side_scene()
    path = str(tmp_path / "side.png")
    cv2.imwrite(path, img)
    out = _analyze_still_payload(path, rotor_radius_m=60.0, expected_view="side")
    q = out["capture_quality"]
    assert q["ok"] and q["metrics"]["view"] == "side"
    assert out["comparison"]["view"] == "side" and out["comparison"]["comparisons"] == []
    assert out["comparison"]["hanging_blade"]["index"] == q["metrics"]["hanging_blade_index"]

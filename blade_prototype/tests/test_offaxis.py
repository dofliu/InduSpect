"""偏軸透視夾具（A5，SPEC §13-11）：站偏了、仰拍了，三片互比會多量到什麼。

守四件事：①正軸、平面時透視渲染與 `render_front` 逐像素同一張圖；②投影半徑與解析式一致；
③**平面葉片**偏軸只改半徑不改彎曲（直線投影仍是直線）——葉尖偏移量不到；④**有預彎的葉片**
偏軸時預彎被投影成 in-plane 彎曲，三片互比把它標成一兩百公分的葉尖偏移，而場景裡沒有缺陷。
"""

from __future__ import annotations

import numpy as np
import pytest

from blade_proto.geometry import compare_blades, profiles_from_structure
from blade_proto.quality import assess_capture
from blade_proto.segmentation import find_structure, segment_turbine
from blade_proto.synth import CameraSpec, SceneSpec, perspective_project, render_front, render_perspective

REAL_BLADE = dict(prebend_m=3.0, rotor_tilt_deg=5.0, cone_deg=2.5)


def _pipeline(img):
    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    verdict = assess_capture(seg, st)
    profs = profiles_from_structure(st) if verdict.ok else []
    cmp_ = compare_blades(profs, rotor_radius_m=SceneSpec().rotor_radius_m) if len(profs) == 3 else None
    return verdict, profs, cmp_


def _metric(cmp_, name):
    return next(c for c in cmp_["comparisons"] if c["metric"] == name)


def test_on_axis_planar_perspective_is_render_front():
    spec = SceneSpec()
    img0, t0 = render_front(spec)
    img1, t1 = render_perspective(spec, CameraSpec(distance_m=300.0))
    assert np.allclose(t0["tips"], t1["tips"], atol=1e-6)
    assert np.allclose(t1["apparent_radii_px"], spec.rotor_radius_px, atol=1e-6)
    m0, m1 = t0["mask"] > 0, t1["mask"] > 0
    iou = (m0 & m1).sum() / (m0 | m1).sum()
    # 塔架多了 overhang、機艙是長方體：遮罩不會逐像素相同，但葉片與輪轂完全重合
    assert iou > 0.95
    assert np.abs(img0.astype(int) - img1.astype(int)).mean() < 0.1


def test_elevation_shrinks_the_upper_blade_by_the_analytic_amount():
    spec = SceneSpec()  # 葉片 A 在 90°（正上方）
    cam = CameraSpec.ground(300.0, 100.0)
    assert cam.distance_m == pytest.approx(np.hypot(300.0, 100.0))
    assert cam.elevation_deg == pytest.approx(np.degrees(np.arctan2(100.0, 300.0)))
    _, t = render_perspective(spec, cam)
    R, D, el = spec.rotor_radius_m, cam.distance_m, np.deg2rad(cam.elevation_deg)
    top_ratio = t["apparent_radii_px"][0] / spec.rotor_radius_px
    assert top_ratio == pytest.approx(np.cos(el) / (1.0 + R / D * np.sin(el)), rel=1e-6)
    assert t["apparent_radii_px"][0] < min(t["apparent_radii_px"][1:]), "仰拍時最上面那片投影最短"
    # 投影函式本身：輪轂中心永遠落在主點
    hub = perspective_project(np.zeros((1, 3)), cam, spec)[0]
    assert tuple(hub) == pytest.approx(spec.hub_xy)


def test_planar_blades_off_axis_change_radii_but_not_bend():
    """直線的投影還是直線：平面葉片再怎麼偏軸，葉尖偏移都量不到；透視全落在半徑上。"""
    img, _ = render_perspective(SceneSpec(), CameraSpec(distance_m=300.0, yaw_deg=20.0, elevation_deg=18.0))
    verdict, profs, cmp_ = _pipeline(img)
    assert verdict.ok and verdict.metrics["view"] == "front"
    assert all(abs(p.tip_deflection_px) < 1.5 for p in profs), [p.tip_deflection_px for p in profs]
    assert not _metric(cmp_, "tip_deflection_px")["flagged"]
    radius = _metric(cmp_, "radius_px")
    assert radius["flagged"] and radius["outlier_deviation"] < 0
    assert abs(radius["outlier_deviation_cm"]) > 300, "假的葉片長度差是公尺級"
    top = max(range(3), key=lambda i: np.sin(np.deg2rad(profs[i].axis_angle_deg)))
    assert radius["outlier_index"] == top, "仰拍的簽名：最短的是最上面那片"
    assert 0.05 < verdict.metrics["tip_radius_spread"] < 0.15, "在閘門門檻之內——它擋不到這種站位"


def test_prebend_off_axis_is_read_as_tip_deflection_of_real_photo_magnitude():
    """真實葉片（預彎 3 m）+ 地面 300 m、yaw 20°：互比標出約 250 cm 的葉尖偏移，
    與 BLADE_TEST_REPORT.md §3.3 的 ed894e7a（226 cm）同一個量級。場景裡沒有缺陷。"""
    cam = CameraSpec.ground(300.0, 100.0, yaw_deg=20.0, **REAL_BLADE)
    img, _ = render_perspective(SceneSpec(), cam)
    verdict, profs, cmp_ = _pipeline(img)
    assert verdict.ok
    tip = _metric(cmp_, "tip_deflection_px")
    assert tip["flagged"]
    assert 150 < abs(tip["outlier_deviation_cm"]) < 400
    assert cmp_["any_flagged"]


def test_steep_elevation_is_caught_by_the_radius_spread_gate():
    """仰角 30°、R/D = 0.2：三片投影半徑離散超過 15%，閘門拒收——極端站位有人擋。"""
    img, t = render_perspective(SceneSpec(), CameraSpec(distance_m=300.0, elevation_deg=30.0))
    verdict, _, _ = _pipeline(img)
    assert not verdict.ok
    assert verdict.metrics["tip_radius_spread"] > 0.15
    assert any("三片等長" in r for r in verdict.reasons)
    spread_truth = (max(t["apparent_radii_px"]) - min(t["apparent_radii_px"])) / np.median(t["apparent_radii_px"])
    assert spread_truth > 0.15, "純投影就已經超過門檻，不是分割誤差"


def test_cone_is_linear_and_absorbed_by_the_axis_but_prebend_is_not():
    """錐角是沿 span 線性的偏移，PCA 軸吸收掉；預彎是 t²，才會變成彎曲係數。"""
    spec = SceneSpec()
    cam_cone = CameraSpec(distance_m=300.0, yaw_deg=25.0, cone_deg=4.0)
    cam_bend = CameraSpec(distance_m=300.0, yaw_deg=25.0, prebend_m=4.0)
    _, p_cone, _ = _pipeline(render_perspective(spec, cam_cone)[0])
    _, p_bend, _ = _pipeline(render_perspective(spec, cam_bend)[0])
    assert p_cone and p_bend
    cone = max(abs(p.tip_deflection_px) for p in p_cone)
    bend = max(abs(p.tip_deflection_px) for p in p_bend)
    # 錐角留下的只是透視把線性偏移微微彎掉的殘量（實測約 2.4 px），預彎是它的好幾倍
    assert cone < 3.0, cone
    assert bend > 6.0 and bend > 2.5 * cone, (cone, bend)

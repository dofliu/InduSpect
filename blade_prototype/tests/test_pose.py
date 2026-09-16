"""姿態估計與透視補償（`pose.py`，SPEC §13-11 決策）。

守：①仰角由輪轂高 + 焦距反推距離、yaw 由塔軸偏移——在合成透視照上對得回渲染用的相機參數；
②健康風機偏軸 yaw ≤ 20° 的假葉尖偏移補償後不再被標記、預彎擬合回到 3 m 附近；
③注入的真缺陷補償後**留得住**且指對那一片；④半徑補償在 |yaw| ≤ 15° 才做，短葉片仍抓得到；
⑤沒有姿態就沒有補償——不用預設值假裝補過。
"""

from __future__ import annotations

import numpy as np
import pytest

from blade_proto import pose as P
from blade_proto.geometry import profiles_from_structure
from blade_proto.quality import assess_capture
from blade_proto.segmentation import find_structure, segment_turbine
from blade_proto.synth import CameraSpec, SceneSpec, render_perspective

REAL_BLADE = dict(prebend_m=3.0, rotor_tilt_deg=5.0, cone_deg=2.5)
R_M = SceneSpec().rotor_radius_m
HUB_HEIGHT_M = 100.0


def _scene(spec: SceneSpec, cam: CameraSpec, frac=(1.0, 1.0, 1.0)):
    img, _ = render_perspective(spec, cam, blade_length_frac=frac)
    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    assert assess_capture(seg, st).ok
    profs = profiles_from_structure(st)
    long_side = max(spec.width, spec.height)
    f35 = cam.distance_m * spec.px_per_m * 36.0 / long_side  # 渲染用的焦距換成 35 mm 等效
    est = P.estimate_pose(st, hub_height_m=HUB_HEIGHT_M, rotor_radius_m=R_M,
                          image_long_side_px=long_side, focal_35mm=f35)
    return st, profs, est


def _metric(comp, name):
    return next(c for c in comp["comparisons"] if c["metric"] == name)


def test_single_estimators_are_plain_geometry():
    assert P.focal_px_from_35mm(24.0, 4000) == pytest.approx(4000 * 24 / 36)
    assert P.distance_from_scale(60.0, 500.0, 2500.0) == pytest.approx(300.0)
    assert P.distance_from_scale(60.0, 0.0, 2500.0) is None
    assert P.elevation_from_slant(100.0, 316.2) == pytest.approx(np.degrees(np.arcsin(98.4 / 316.2)))
    assert P.elevation_from_slant(100.0, 50.0) is None, "距離比高度差還短：姿態不成立"
    el, d = P.elevation_from_horizontal(100.0, 300.0)
    assert el == pytest.approx(np.degrees(np.arctan2(98.4, 300.0))) and d == pytest.approx(np.hypot(300.0, 98.4))
    assert P.yaw_from_hub_offset(2.5, 5.0) == pytest.approx(30.0)
    assert P.yaw_from_hub_offset(9.0, 5.0) == pytest.approx(90.0), "超過 overhang 夾在 ±90°"
    assert P.yaw_from_hub_offset(1.0, 0.0) is None


def test_pose_estimate_recovers_camera_from_perspective_scene():
    """地面 300 m、yaw 20°：仰角差 < 1.5°，yaw 方向對、量級對（overhang 預設 5 m 對渲染的 6 m，
    估出來會偏大約 1.2 倍——那是先驗誤差，記在 notes 裡）。"""
    cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=20.0, **REAL_BLADE)
    st, _, est = _scene(SceneSpec(), cam)
    assert est.usable
    assert est.elevation_method == "focal" and est.yaw_method == "tower_offset"
    # 仰角偏低約 1.5°：中位葉長被透視壓短（頂片最短）→ 反推距離偏大；加上相機高度 1.6 m 的假設
    assert abs(est.elevation_deg - cam.elevation_deg) < 2.0
    assert abs(est.distance_m - cam.distance_m) / cam.distance_m < 0.08
    assert 15.0 < est.yaw_deg < 32.0, est.yaw_deg
    assert est.hub_offset_m > 0, "相機在 +x 側 → 塔軸在輪轂右側"
    assert st.tower_x_at_hub_px is not None
    assert any("overhang" in n for n in est.notes)


def test_pose_estimate_on_axis_gives_zero_yaw_and_refuses_without_inputs():
    cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=0.0, **REAL_BLADE)
    st, _, est = _scene(SceneSpec(), cam)
    assert abs(est.yaw_deg) < 2.0 and abs(est.elevation_deg - cam.elevation_deg) < 1.5
    # 沒有輪轂高度／沒有焦距 → 仰角 None、不可用；yaw 仍估得出來
    none = P.estimate_pose(st, hub_height_m=None, rotor_radius_m=R_M)
    assert none.elevation_deg is None and not none.usable and none.yaw_deg is not None
    no_f = P.estimate_pose(st, hub_height_m=HUB_HEIGHT_M, rotor_radius_m=R_M)
    assert no_f.elevation_deg is None and any("焦距" in n for n in no_f.notes)
    # 沒有尺度就沒有 yaw
    no_scale = P.estimate_pose(st, hub_height_m=HUB_HEIGHT_M, rotor_radius_m=None,
                               image_long_side_px=1600, focal_35mm=50.0)
    assert no_scale.yaw_deg is None


@pytest.mark.parametrize("hor,yaw", [(300.0, 0.0), (300.0, 10.0), (300.0, 20.0), (480.0, 10.0), (480.0, 20.0)])
def test_compensation_removes_false_tip_deflection_of_healthy_rotor(hor, yaw):
    """健康風機、真實葉片、地面站位：原始互比標出一到兩公尺的假葉尖偏移（或只因 spread 規則
    沒標），用**估計**的姿態補償後殘差 < 50 cm、不標記，預彎擬合回到 3 m ± 0.8。"""
    cam = CameraSpec.ground(hor, HUB_HEIGHT_M, yaw_deg=yaw, **REAL_BLADE)
    _, profs, est = _scene(SceneSpec(), cam)
    comp = P.compensate_comparison(profs, est, R_M)
    assert comp is not None and comp["deflection_compensated"]
    tip = _metric(comp, "tip_deflection_px")
    assert not tip["flagged"], tip
    assert abs(tip["outlier_deviation_cm"]) < 50, tip
    assert abs(comp["prebend_fit_m"] - 3.0) < 0.8, comp["prebend_fit_m"]
    assert max(abs(v) for v in comp["tip_deflection_raw_px"]) > max(abs(v) for v in comp["tip_deflection_compensated_px"])


@pytest.mark.parametrize("blade", [0, 1, 2])
def test_compensation_keeps_an_injected_defect_on_the_right_blade(blade):
    """同一站位（300 m、yaw 20°），某一片注入 400 cm 葉尖偏移：補償後仍標記、指對那一片、量級 250–600 cm。
    留一法擬合是關鍵：三片一起最小平方會把缺陷吃掉一半（實測只剩 124 cm）。"""
    d = [0.0, 0.0, 0.0]
    d[blade] = 400.0
    cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=20.0, **REAL_BLADE)
    _, profs, est = _scene(SceneSpec(tip_deflection_cm=tuple(d)), cam)
    comp = P.compensate_comparison(profs, est, R_M)
    tip = _metric(comp, "tip_deflection_px")
    assert tip["flagged"]
    assert tip["outlier_index"] == blade
    assert 250 < abs(tip["outlier_deviation_cm"]) < 600, tip


def test_radius_compensation_only_within_yaw_limit_and_keeps_short_blade():
    # yaw 10°：半徑補償做了，健康三片不再被標
    cam = CameraSpec.ground(480.0, HUB_HEIGHT_M, yaw_deg=10.0, **REAL_BLADE)
    _, profs, est = _scene(SceneSpec(), cam)
    comp = P.compensate_comparison(profs, est, R_M)
    assert comp["radius_compensated"]
    assert not _metric(comp, "radius_px")["flagged"], _metric(comp, "radius_px")
    # 同站位、第二片短 3%（1.8 m）：補償後半徑互比仍標記且指對
    _, profs_s, est_s = _scene(SceneSpec(), cam, frac=(1.0, 0.97, 1.0))
    comp_s = P.compensate_comparison(profs_s, est_s, R_M)
    rad = _metric(comp_s, "radius_px")
    assert rad["flagged"] and rad["outlier_index"] == 1 and rad["outlier_deviation"] < 0, rad
    # yaw 20°（估出來約 26°）：半徑不補、原值保留並註記
    cam20 = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=20.0, **REAL_BLADE)
    _, profs20, est20 = _scene(SceneSpec(), cam20)
    comp20 = P.compensate_comparison(profs20, est20, R_M)
    assert not comp20["radius_compensated"]
    assert _metric(comp20, "radius_px")["values"] == pytest.approx(comp20["radius_raw_px"])
    assert "半徑未補償" in comp20.get("note", "")


def test_near_tower_blade_is_named_not_silently_compensated():
    """轉子方位角 60°、yaw 20°：一片距六點鐘 30°，與塔架合併把中心線拉歪成 30 px 的假彎曲，
    連平面葉片都量得到（不是透視）。補償模型算不掉它，只能點名。"""
    cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=20.0, **REAL_BLADE)
    _, profs, est = _scene(SceneSpec(azimuth_deg=60.0), cam)
    comp = P.compensate_comparison(profs, est, R_M)
    assert comp["blades_near_tower"], [p.axis_angle_deg for p in profs]
    assert "塔架合併" in comp["note"]


def test_no_pose_no_compensation():
    from blade_proto.geometry import BladeProfile  # noqa: F401
    cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=10.0, **REAL_BLADE)
    _, profs, _ = _scene(SceneSpec(), cam)
    unusable = P.PoseEstimate(elevation_deg=None, yaw_deg=10.0, distance_m=None)
    assert not unusable.usable
    assert P.compensate_comparison(profs, unusable, R_M) is None
    assert P.compensate_comparison(profs, P.PoseEstimate(18.0, 10.0, 316.0), None) is None


def test_fit_prebend_leave_one_out_isolates_the_odd_blade():
    g = [2.5, -3.8, 2.0]
    d = [3 * 2.5, 3 * -3.8 + 40.0, 3 * 2.0]  # 第二片多 40 px
    w, resid, k = P.fit_prebend(d, g)
    assert w == pytest.approx(3.0) and k == 1
    assert resid[1] == pytest.approx(40.0) and abs(resid[0]) < 1e-9 and abs(resid[2]) < 1e-9

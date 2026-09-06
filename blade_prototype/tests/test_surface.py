"""表面層（§5.2）：前緣粗糙度。"""

import pytest

from blade_proto.synth import render_blade_segment
from blade_proto.surface import analyze_blade_edges


def _run(amp_cm, cm_per_px=0.4, seed=1):
    img, _ = render_blade_segment(cm_per_px=cm_per_px, erosion_amp_cm=amp_cm, seed=seed)
    return analyze_blade_edges(img, cm_per_px=cm_per_px, leading_edge="top").to_dict()


def test_clean_edges_are_smooth_and_symmetric():
    d = _run(0.0)
    assert d["top"]["rms_px"] < 0.5
    assert d["bottom"]["rms_px"] < 0.5
    assert 0.6 < d["le_over_te_rms_ratio"] < 1.5
    assert d["top"]["pit_count"] <= 2
    assert d["top"]["n_samples"] > 500


@pytest.mark.parametrize("amp_cm,min_ratio,p95_factor", [(1.0, 1.5, 2.0), (2.0, 2.5, 4.0), (5.0, 5.0, 8.0)])
def test_erosion_raises_leading_edge_roughness(amp_cm, min_ratio, p95_factor):
    d = _run(amp_cm)
    assert d["le_over_te_rms_ratio"] > min_ratio
    assert d["top"]["pit_count"] >= 5
    assert d["top"]["inward_p95_px"] > p95_factor * _run(0.0)["top"]["inward_p95_px"]
    # 侵蝕只在 span 40–100%：第一個 zone 幾乎乾淨，第三個最粗
    z = d["top"]["zone_rms_px"]
    assert z[0] < 0.5 and z[2] > z[0] * 2


def test_rotation_handles_tilted_blade():
    img, _ = render_blade_segment(cm_per_px=0.4, tilt_deg=-9.0, erosion_amp_cm=0.0, seed=4)
    d = analyze_blade_edges(img, cm_per_px=0.4).to_dict()
    assert abs(d["axis_angle_deg"] - (-9.0)) < 1.0
    assert d["top"]["rms_px"] < 0.6

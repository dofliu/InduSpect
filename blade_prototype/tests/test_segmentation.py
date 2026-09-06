"""分割與結構定位（§5.1）。"""

import numpy as np
import pytest

from blade_proto.synth import SceneSpec, render_front, render_side
from blade_proto.segmentation import segment_turbine, find_structure


def _iou(a, b):
    a, b = a > 0, b > 0
    return (a & b).sum() / (a | b).sum()


@pytest.mark.parametrize("azimuth", [90.0, 60.0, 110.0])
def test_front_segmentation_and_structure(azimuth):
    """三種方位角：標準 Y（離塔 60°）、葉片與塔架夾 30°（楔形）、夾 40°。

    拍攝協定要求沒有葉片落在六點鐘 ±20° 內（會與塔架合併），所以不測 15° 這種配置。"""
    img, truth = render_front(SceneSpec(azimuth_deg=azimuth, seed=1))
    seg = segment_turbine(img)
    assert _iou(seg.mask, truth["mask"]) > 0.95
    st = find_structure(seg.mask)
    hub_err = np.hypot(st.hub[0] - truth["hub"][0], st.hub[1] - truth["hub"][1])
    assert hub_err < 5.0, st.notes
    assert st.tower_found
    assert abs(st.tower_angle_deg) < 1.0
    assert len(st.blades) == 3
    got = sorted(b.tip_angle_deg for b in st.blades)
    exp = sorted(truth["azimuths_deg"])
    assert np.allclose(got, exp, atol=2.0)
    for b in st.blades:
        assert abs(b.tip_radius_px - truth["rotor_radius_px"]) < 0.02 * truth["rotor_radius_px"]


def test_side_structure():
    img, truth = render_side(SceneSpec(seed=2, azimuth_deg=270.0))
    st = find_structure(segment_turbine(img).mask)
    hub_err = np.hypot(st.hub[0] - truth["hub"][0], st.hub[1] - truth["hub"][1])
    assert hub_err < 12.0, st.notes  # 側視：先落在機艙中心再投影到葉片軸，沿軸方向殘差約半個輪轂半徑
    assert st.tower_found
    angles = sorted(b.tip_angle_deg for b in st.blades)
    assert len(angles) == 2  # 上方兩片投影重疊成一條
    assert abs(angles[0] - 90) < 5 and abs(angles[1] - 270) < 5
    down = [b for b in st.blades if abs(b.tip_angle_deg - 270) < 5][0]
    assert abs(down.tip_radius_px - truth["rotor_radius_px"]) < 0.03 * truth["rotor_radius_px"]


def test_hub_hint_overrides_estimate():
    img, truth = render_front(SceneSpec(seed=3))
    st = find_structure(segment_turbine(img).mask, hub_hint=truth["hub"])
    assert np.hypot(st.hub[0] - truth["hub"][0], st.hub[1] - truth["hub"][1]) < 3.0
    assert len(st.blades) == 3


def test_empty_mask_raises():
    with pytest.raises(ValueError):
        find_structure(np.zeros((100, 100), np.uint8))

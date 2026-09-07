"""分割與結構定位（§5.1）。"""

import numpy as np
import pytest

from blade_proto.synth import SceneSpec, render_front, render_side
from blade_proto.segmentation import (DEFAULT_LOCAL_THRESH, find_structure, fit_local_sky,
                                      fit_sky_model, local_sky_distance, segment_turbine)


def _iou(a, b):
    a, b = a > 0, b > 0
    return (a & b).sum() / (a | b).sum()


def _recall_and_sky_fp(mask, truth):
    """結構召回率與天空誤判率。

    分開驗這兩個，而不是只看 IoU：IoU 把兩種錯誤混在一起，一個 0.95 可能是
    「漏抓一點」也可能是「誤抓一堆」。真實影像上壞事都是誤抓造成的（地面與雲塊
    進遮罩 → 輪轂跑掉），而幾何量測靠的是遮罩邊緣 → 需要高召回。兩個都要盯。
    """
    m, t = mask > 0, truth > 0
    return (m & t).sum() / max(t.sum(), 1), (m & ~t).sum() / max((~t).sum(), 1)


@pytest.mark.parametrize("azimuth", [90.0, 60.0, 110.0])
def test_front_segmentation_and_structure(azimuth):
    """三種方位角：標準 Y（離塔 60°）、葉片與塔架夾 30°（楔形）、夾 40°。

    拍攝協定要求沒有葉片落在六點鐘 ±20° 內（會與塔架合併），所以不測 15° 這種配置。"""
    img, truth = render_front(SceneSpec(azimuth_deg=azimuth, seed=1))
    seg = segment_turbine(img)
    recall, sky_fp = _recall_and_sky_fp(seg.mask, truth["mask"])
    assert recall > 0.93, f"結構召回 {recall:.3f}：遮罩邊緣是幾何量測的依據，不能漏"
    assert sky_fp < 0.001, f"天空誤判 {sky_fp:.4f}：誤抓會把輪轂拉到雲塊或地面上"
    assert _iou(seg.mask, truth["mask"]) > 0.94
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


# ------------------------------------------------------------ 局部天空模型


def test_local_sky_model_survives_cloud_that_breaks_the_row_model():
    """把真實照片上的失敗做成確定性夾具：雲進遮罩 → 輪轂被拉到雲塊上。

    真實語料上量到的是「有雲時輪轂命中 1/13」。這裡用 cloud_strength=0.5 的合成場景
    重現同一個機制：逐列多項式模型的天空誤判率升到 0.8%，輪轂偏掉 189 px；
    局部模型誤判 0.00%，輪轂誤差 0.2 px。詳見 REAL_IMAGE_VALIDATION.md §5。
    """
    img, truth = render_front(SceneSpec(azimuth_deg=90.0, seed=1, cloud_strength=0.5))

    rows = segment_turbine(img, sky_mode="rows")
    _, rows_fp = _recall_and_sky_fp(rows.mask, truth["mask"])
    rows_st = find_structure(rows.mask)
    rows_err = np.hypot(rows_st.hub[0] - truth["hub"][0], rows_st.hub[1] - truth["hub"][1])

    local = segment_turbine(img)  # 預設就是 sky_mode="local"
    local_recall, local_fp = _recall_and_sky_fp(local.mask, truth["mask"])
    local_st = find_structure(local.mask)
    local_err = np.hypot(local_st.hub[0] - truth["hub"][0], local_st.hub[1] - truth["hub"][1])

    assert rows_err > 50.0, "夾具沒有重現舊模型的失敗，門檻或雲層參數被改動了"
    assert rows_fp > 5 * local_fp, "舊模型的失敗機制是「雲被當成前景」，誤判率應明顯較高"
    assert local_err < 5.0, local_st.notes
    assert len(local_st.blades) == 3
    assert local_recall > 0.85 and local_fp < 0.001


def test_local_fields_upsample_to_full_resolution():
    """場在工作尺度上算、殘差在全解析度上取。

    這條路徑真實語料走不到（那些照片本來就只有 1024 px），但外業原圖是 4000 px：
    背景與尺度必須放大回去，而且放大後的遮罩要跟「直接在工作尺度算」量到的結構一致。
    """
    img, truth = render_front(SceneSpec(azimuth_deg=90.0, seed=1))
    h, w = img.shape[:2]
    model = fit_local_sky(img)
    assert model.kernel_px % 2 == 1 and 5 <= model.kernel_px <= 255
    assert model.bg.shape[:2] != (h, w), "夾具應該比工作尺度大，才測得到放大路徑"

    dist = local_sky_distance(img, model)
    assert dist.shape == (h, w)
    assert np.isfinite(dist).all()
    # 天空的距離接近 0、結構的距離明顯高於門檻
    t = truth["mask"] > 0
    assert np.median(dist[~t]) < 2.0
    assert np.percentile(dist[t], 75) > DEFAULT_LOCAL_THRESH

    seg = segment_turbine(img)  # full_res=True 走的就是這條
    assert seg.mask.shape == (h, w)
    st = find_structure(seg.mask)
    assert len(st.blades) == 3
    for b in st.blades:  # 葉尖半徑仍是全解析度的精度
        assert abs(b.tip_radius_px - truth["rotor_radius_px"]) < 0.02 * truth["rotor_radius_px"]


def test_local_scale_floor_keeps_a_flawless_sky_from_exploding():
    """完全無雜訊的純色天空：局部尺度會是 0，必須被下限接住而不是產生 inf/nan。"""
    flat = np.full((300, 400, 3), (200, 150, 90), np.uint8)
    model = fit_local_sky(flat)
    assert (model.scale >= model.min_scale - 1e-6).all()
    dist = local_sky_distance(flat, model)
    assert np.isfinite(dist).all() and dist.max() < 1.0  # 純天空不該有任何前景


def test_segment_turbine_honours_an_explicitly_passed_model():
    """dynamics 會估一次模型套用到整段影片；兩種模型都要走得通。"""
    img, _ = render_front(SceneSpec(azimuth_deg=90.0, seed=1))
    for model in (fit_local_sky(img), fit_sky_model(img)):
        seg = segment_turbine(img, sky_model=model)
        assert seg.sky_model is model
        assert (seg.mask > 0).any()

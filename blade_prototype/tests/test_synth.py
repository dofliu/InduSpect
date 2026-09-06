import pytest

from blade_proto.synth import SceneSpec, render_front, render_side, render_blade_segment


def test_default_scene_fits_frame():
    spec = SceneSpec()
    assert spec.rotor_fits("front")
    img, truth = render_front(spec)
    assert img.shape == (spec.height, spec.width, 3)
    assert truth["mask"].shape == (spec.height, spec.width)
    assert 0.02 < (truth["mask"] > 0).mean() < 0.2


def test_for_scale_rejects_unfittable_rotor():
    with pytest.raises(ValueError):
        SceneSpec.for_scale(3.7, "front", (4000, 3000))
    spec = SceneSpec.for_scale(4.8, "front", (4000, 3000))
    assert (spec.width, spec.height) == (4000, 3000)
    side = SceneSpec.for_scale(2.5, "side", (4000, 3000))
    assert (side.width, side.height) == (3000, 4000)


def test_side_and_segment_render():
    img, truth = render_side(SceneSpec(azimuth_deg=270.0))
    assert truth["view"] == "side" and img.dtype.name == "uint8"
    assert truth["hanging_index"] == 0
    assert abs(truth["projected_lengths_px"][1] - 0.5 * truth["rotor_radius_px"]) < 1e-6
    img, truth = render_blade_segment(cm_per_px=1.0, erosion_amp_cm=3.0)
    assert truth["erosion_amp_px"] == 3.0
    assert img.shape[:2] == truth["mask"].shape

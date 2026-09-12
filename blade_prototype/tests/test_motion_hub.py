"""運動分割輪轂定位（`motion_hub.py`）。

合成影片能驗的是演算法的正確性：手持晃動下對齊得回來、輪轂落在真值附近、
奇偶幀兩個獨立子集算出同一個中心。真實影片的表現在 `INNOVATION_REVIEW.md`。
"""

import math

import cv2
import numpy as np
import pytest

from blade_proto.motion_hub import hub_from_lines, locate_hub, motion_masks, stabilise
from blade_proto.synth import SceneSpec, render_video_frames


def _frames(n: int = 48, rpm: float = 12.0, fps: float = 7.0, seed: int = 3):
    """轉動中的合成風機，縮到一半（450×600）讓測試跑得快。

    刻意不用 `render_video_frames(shake_px=…)`：那個晃動是「風機相對固定的天空移動」，
    跟真實手持（整張畫面一起動）相反，穩像器對齊靜態背景後風機反而會被留在錯的位置。
    手持晃動由 `_camera_shake` 對整張幀施加平移來模擬。
    """
    spec = SceneSpec(width=900, height=1200, cm_per_px=12.0, seed=seed, cloud_strength=0.25)
    out, truths = [], []
    for img, truth in render_video_frames(spec, n_frames=n, fps=fps, rpm=rpm, shake_px=0.0):
        out.append(cv2.resize(img, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA))
        truths.append(truth)
    return out, truths, spec


def _with_ground(frames, seed: int = 11):
    """在畫面底部貼一條有紋理的地面帶（每幀相同）。合成天空與塔架沒有 ORB 抓得到的特徵，
    真實影片的地面、植被、塔基有；沒有這條帶，穩像只能走備援。"""
    rng = np.random.default_rng(seed)
    h, w = frames[0].shape[:2]
    band_h = int(h * 0.15)
    tex = cv2.GaussianBlur(rng.integers(40, 200, (band_h, w, 3)).astype(np.uint8), (0, 0), 1.2)
    out = []
    for f in frames:
        g = f.copy()
        g[h - band_h:] = tex
        out.append(g)
    return out


def _camera_shake(frames, amp_px: float = 6.0, seed: int = 5):
    """整張幀的隨機漫步平移（真實手持）。回傳 (晃動後的幀, 每幀真值平移 (dx, dy))。"""
    rng = np.random.default_rng(seed)
    off = np.zeros(2)
    out, truth = [], []
    h, w = frames[0].shape[:2]
    for f in frames:
        off = 0.85 * off + rng.normal(0, amp_px * 0.4, 2)
        m = np.float32([[1, 0, off[0]], [0, 1, off[1]]])
        out.append(cv2.warpAffine(f, m, (w, h), borderMode=cv2.BORDER_REPLICATE))
        truth.append((float(off[0]), float(off[1])))
    return out, truth


def _truth_hub(spec: SceneSpec, scale: float = 0.5) -> tuple[float, float]:
    return (spec.width * spec.hub_frac[0] * scale, spec.height * spec.hub_frac[1] * scale)


def test_hub_within_tolerance_without_shake():
    frames, _, spec = _frames()
    res, st, _ = locate_hub(frames)
    assert res.ok
    gx, gy = _truth_hub(spec)
    diag = math.hypot(*frames[0].shape[1::-1])
    assert math.hypot(res.hub[0] - gx, res.hub[1] - gy) / diag < 0.01


def test_hub_within_tolerance_with_handheld_shake():
    clean, _, spec = _frames()
    frames, shake = _camera_shake(_with_ground(clean), amp_px=6.0)
    res, st, _ = locate_hub(frames)
    assert res.ok
    # 對齊到中間幀：真值輪轂 = 乾淨輪轂 + 中間幀的晃動
    mid = len(frames) // 2
    gx, gy = _truth_hub(spec)
    gx, gy = gx + shake[mid][0], gy + shake[mid][1]
    diag = math.hypot(*frames[0].shape[1::-1])
    assert math.hypot(res.hub[0] - gx, res.hub[1] - gy) / diag < 0.01
    # 穩像估出來的平移要對得上真值：幀 k 要移 −(shake_k − shake_mid)
    errs = []
    for k, off in enumerate(st.offsets):
        if k == mid:
            continue
        assert off is not None, f"frame {k} 對齊失敗（{st.methods[k]}）"
        want = (-(shake[k][0] - shake[mid][0]), -(shake[k][1] - shake[mid][1]))
        errs.append(math.hypot(off[0] - want[0], off[1] - want[1]))
    assert float(np.median(errs)) < 1.0
    assert max(errs) < 3.0
    assert st.methods.count("orb") >= len(frames) * 3 // 4


def test_rotor_radius_matches_truth():
    frames, _, spec = _frames()
    res, _, _ = locate_hub(_with_ground(frames))
    r_true = spec.rotor_radius_px * 0.5
    assert abs(res.rotor_r_px - r_true) / r_true < 0.08


def test_odd_and_even_frames_agree():
    clean, _, _ = _frames()
    frames, _ = _camera_shake(_with_ground(clean), amp_px=4.0)
    st = stabilise(frames)
    _, masks, _ = motion_masks(st.frames, valid=st.valid)
    a, b = hub_from_lines(masks[0::2]), hub_from_lines(masks[1::2])
    assert a.ok and b.ok
    assert math.hypot(a.hub[0] - b.hub[0], a.hub[1] - b.hub[1]) <= 6.0


def test_static_scene_reports_no_rotor():
    frames, _, _ = _frames(rpm=0.0, n=16)
    res, _, _ = locate_hub(frames)
    assert not res.ok
    assert res.notes  # 要說得出為什麼不行，不能靜靜回 False


def test_background_median_removes_rotor():
    frames, _, spec = _frames()
    _, _, bg = locate_hub(frames)
    # 轉子掃過的區域在背景圖上應該回到天空亮度，而不是葉片亮度：
    # 取輪轂正上方 0.6R 處（沒有塔架與機艙）的背景值，跟畫面角落的天空比
    gx, gy = _truth_hub(spec)
    r = spec.rotor_radius_px * 0.5
    sample = int(bg[int(gy - 0.6 * r), int(gx)])
    sky = int(np.median(bg[5:25, 5:25]))
    assert abs(sample - sky) < 25


@pytest.mark.parametrize("min_elong", [3.0, 5.0])
def test_elongation_threshold_still_finds_hub(min_elong):
    frames, _, spec = _frames(n=32)
    st = stabilise(frames)
    _, masks, _ = motion_masks(st.frames, valid=st.valid)
    res = hub_from_lines(masks, min_elong=min_elong)
    gx, gy = _truth_hub(spec)
    diag = math.hypot(*frames[0].shape[1::-1])
    assert res.ok and math.hypot(res.hub[0] - gx, res.hub[1] - gy) / diag < 0.01

"""動態層（§5.4）：轉速、葉尖追蹤、六點鐘取幀。用小尺寸影格控制測試時間。"""

import numpy as np

from blade_proto.synth import SceneSpec, render_video_frames
from blade_proto.dynamics import analyze_frames, _assign, _wrap


def test_rpm_tracking_and_six_oclock_with_shake():
    spec = SceneSpec(width=640, height=854, cm_per_px=22.0, azimuth_deg=100.0, seed=5)
    fps, rpm = 30.0, 15.0
    frames = [f for f, _ in render_video_frames(spec, n_frames=100, fps=fps, rpm=rpm, shake_px=5.0)]
    res = analyze_frames(frames, fps=fps, max_side=640)
    assert abs(res.rpm - rpm) / rpm < 0.03
    assert res.direction == "ccw"
    # 100 幀 = 300°：至少兩片葉片會經過六點鐘
    assert sum(1 for s in res.six_oclock_frames if s) >= 2
    for s in res.six_oclock_frames:
        assert len(s) <= 1  # 每片一圈內只該有一幀
    # 三片葉尖半徑一致（同一台健康風機）
    med = np.array(res.radius_median_px)
    assert np.ptp(med) / med.mean() < 0.03
    # 正視時葉片經過塔架會缺測，但偵測率仍應高
    for t in res.tracks:
        assert np.mean(t.detected) > 0.6


def test_six_oclock_frame_is_actually_vertical():
    spec = SceneSpec(width=640, height=854, cm_per_px=22.0, azimuth_deg=250.0, seed=6)
    fps, rpm = 30.0, 12.0
    truths = []
    frames = []
    for f, t in render_video_frames(spec, n_frames=60, fps=fps, rpm=rpm):
        frames.append(f)
        truths.append(t)
    res = analyze_frames(frames, fps=fps, max_side=640)
    hits = [k for s in res.six_oclock_frames for k in s]
    assert hits
    for k in hits:
        az = np.array(truths[k]["azimuths_deg"])
        # 正視時六點鐘葉片被塔架遮住，角度是內插值：容許 5°（約 2 幀）
        assert np.min(np.abs(_wrap(az - 270.0))) < 5.0


def test_side_view_six_oclock_by_projected_length():
    """側視：三葉尖共線，六點鐘 = 向下葉片投影長度極大；轉速由相鄰通過間隔推得。"""
    spec = SceneSpec(width=640, height=854, cm_per_px=22.0, azimuth_deg=240.0, seed=7, hub_frac=(0.5, 0.3))
    fps, rpm = 30.0, 15.0
    frames, truths = [], []
    for f, t in render_video_frames(spec, n_frames=120, fps=fps, rpm=rpm, view="side", shake_px=4.0):
        frames.append(f)
        truths.append(t)
    res = analyze_frames(frames, fps=fps, max_side=640, view="side")
    hits = sorted(k for s in res.six_oclock_frames for k in s)
    # 120 幀 @15 rpm @30 fps = 4 s = 1 圈 → 三片各通過一次
    assert len(hits) == 3
    for k in hits:
        az = np.array(truths[k]["azimuths_deg"])
        # 投影長度在極大附近是餘弦平頂，±2 幀（6°）內都算對
        assert np.min(np.abs(_wrap(az - 270.0))) < 7.0
    assert abs(res.rpm - rpm) / rpm < 0.05
    med = np.array(res.radius_median_px)
    assert np.all(np.isfinite(med)) and np.ptp(med) / med.mean() < 0.03


def test_assign_prefers_nearest_with_missing():
    pred = [10.0, 130.0, 250.0]
    dets = [(132.0, 100.0), (12.0, 100.0)]  # 第三片缺測
    assert _assign(pred, dets, 30.0) == [1, 0, None]
    assert _assign(pred, [], 30.0) == [None, None, None]

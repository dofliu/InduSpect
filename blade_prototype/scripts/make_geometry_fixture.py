"""產生幾何層 Dart 移植的交叉驗證夾具。

一張合成正視圖 + 一份 Python 在同一張圖上量到的參考值，寫進
`flutter_app/test/assets/`。Dart 端逐階段對照，這樣某個符號寫錯時會在**它發生的
那一階段**紅掉，而不是變成最後一個對不上的數字。

**改動 `segmentation.py` 之後要重跑這支**，否則 Flutter 的交叉驗證測試會紅：

    cd blade_prototype && python scripts/make_geometry_fixture.py

夾具刻意做小（384×512）：測的是移植正確性，那與尺度無關，而 PNG 要進版控。
真實尺度的表現由 `REAL_IMAGE_VALIDATION.md`（75 張真實照片）負責。
"""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import cv2, numpy as np
from blade_proto import segmentation as seg
from blade_proto.synth import SceneSpec, render_front

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'flutter_app', 'test', 'assets')
GRID_STEP = 16

# 夾具刻意做小（384×512、noise 1.2）：測的是**移植正確性**，那與尺度無關，
# 而 PNG 要進版控。真實尺度的表現由 blade_prototype 在 75 張真實照片上驗證。
spec = SceneSpec(width=384, height=512, cm_per_px=37.5, seed=1,
                 noise_sigma=1.2, cloud_strength=0.35, azimuth_deg=90.0)
img, truth = render_front(spec)
h, w = img.shape[:2]
cv2.imwrite(f'{OUT}/blade_front_scene.png', img,
            [cv2.IMWRITE_PNG_COMPRESSION, 9])
print(f'影像 {w}×{h}')

model = seg.fit_local_sky(img, grid_step=GRID_STEP)
sg = seg.segment_turbine(img, sky_mode='local', sky_model=model)
st = seg.find_structure(sg.mask, horizon_y=sg.horizon_y)

lab = cv2.cvtColor(img, cv2.COLOR_BGR2Lab)
dist = seg.local_sky_distance(img, model)

# 場的取樣點：固定座標，Dart 端逐點比對
sample_xy = [(0, 0), (w // 2, 0), (w - 1, h - 1), (w // 3, h // 2),
             (w // 2, h // 2), (10, h - 10), (w - 10, 10)]
ref = {
    '_readme': [
        '幾何層 Dart 移植的交叉驗證參考值。由 blade_prototype 在 blade_front_scene.png 上量出。',
        f'天空模型用 grid_step={GRID_STEP}（App 端的模式）。改動 segmentation.py 後要重跑',
        'scripts/make_geometry_fixture.py，否則 Flutter 的交叉驗證測試會紅。',
    ],
    'size': [w, h],
    'grid_step': GRID_STEP,
    'kernel_px': int(model.kernel_px),
    'lab8_samples': {f'{x},{y}': [int(v) for v in lab[y, x]] for x, y in sample_xy},
    'bg_samples': {f'{x},{y}': [round(float(v), 3) for v in model.bg[y, x]]
                   for x, y in sample_xy},
    'scale_samples': {f'{x},{y}': [round(float(v), 3) for v in model.scale[y, x]]
                      for x, y in sample_xy},
    'dist_samples': {f'{x},{y}': round(float(dist[y, x]), 3) for x, y in sample_xy},
    'threshold': float(sg.threshold),
    'mask_area_frac': round(float((sg.mask > 0).mean()), 5),
    'horizon_y': sg.horizon_y,
    'hub': [round(float(st.hub[0]), 2), round(float(st.hub[1]), 2)],
    'hub_radius_px': round(float(st.hub_radius_px), 2),
    'hub_refined': bool(st.hub_refined),
    'tower_found': bool(st.tower_found),
    'tower_angle_deg': round(float(st.tower_angle_deg), 3),
    'tower_width_px': round(float(st.tower_width_px), 2),
    'n_blades': len(st.blades),
    'blades': sorted([
        {'tip_radius_px': round(float(b.tip_radius_px), 2),
         'tip_angle_deg': round(float(b.tip_angle_deg), 2),
         'area': int(b.area)}
        for b in st.blades], key=lambda d: d['tip_angle_deg']),
    'truth': {
        'hub': [round(float(truth['hub'][0]), 2), round(float(truth['hub'][1]), 2)],
        'rotor_radius_px': round(float(truth['rotor_radius_px']), 2),
        'mask_area_frac': round(float((truth['mask'] > 0).mean()), 5),
    },
}
with open(f'{OUT}/blade_geometry_reference.json', 'w', encoding='utf-8') as fh:
    json.dump(ref, fh, indent=1, ensure_ascii=False)
    fh.write('\n')
print(json.dumps({k: v for k, v in ref.items()
                  if k not in ('_readme', 'lab8_samples', 'bg_samples',
                               'scale_samples', 'dist_samples')},
                 indent=1, ensure_ascii=False))

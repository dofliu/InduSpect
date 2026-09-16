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
from blade_proto.geometry import compare_blades, profiles_from_structure
from blade_proto.quality import assess_capture
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

profiles = profiles_from_structure(st)
# 帶型錄轉子半徑：Python 由三片葉長中位數反推 cm/px，Dart 端要得到同一個數（A4）
cmp_ = compare_blades(profiles, rotor_radius_m=spec.rotor_radius_m)
verdict = assess_capture(sg, st)

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
    # 塔軸外推到輪轂那一列的 x（姿態估計的 yaw 線索）；正視合成照它應該就在輪轂正下方
    'tower_x_at_hub_px': None if st.tower_x_at_hub_px is None else round(float(st.tower_x_at_hub_px), 2),
    'n_blades': len(st.blades),
    'blades': sorted([
        {'tip_radius_px': round(float(b.tip_radius_px), 2),
         'tip_angle_deg': round(float(b.tip_angle_deg), 2),
         'area': int(b.area)}
        for b in st.blades], key=lambda d: d['tip_angle_deg']),
    'profiles': sorted([
        {'axis_angle_deg': round(float(pr.axis_angle_deg), 2),
         'radius_px': round(float(pr.radius_px), 2),
         'bend_coeff': round(float(pr.bend_coeff), 5),
         'tip_deflection_px': round(float(pr.tip_deflection_px), 3),
         'residual_rms_px': round(float(pr.residual_rms_px), 4),
         'mean_width_px': round(float(pr.mean_width_px), 3),
         'n_contaminated_bins': int(pr.n_contaminated_bins)}
        for pr in profiles], key=lambda d: d['axis_angle_deg']),
    'comparison': {
        'n_blades': cmp_['n_blades'],
        'any_flagged': bool(cmp_['any_flagged']),
        'rotor_radius_m': spec.rotor_radius_m,
        'cm_per_px': round(float(cmp_['cm_per_px']), 5),
        'metrics': {c['metric']: {'z': round(float(c['z']), 3),
                                  'others_spread': round(float(c['others_spread']), 4),
                                  'outlier_deviation': round(float(c['outlier_deviation']), 4),
                                  'flagged': bool(c['flagged'])}
                    for c in cmp_['comparisons']},
    },
    'capture_verdict': {
        'ok': bool(verdict.ok),
        'n_reasons': len(verdict.reasons),
        'n_warnings': len(verdict.warnings),
        'tip_radius_spread': verdict.metrics.get('tip_radius_spread'),
        'sky_mask_frac': verdict.metrics.get('sky_mask_frac'),
        'second_rotor_ratio': verdict.metrics.get('second_rotor_ratio'),
    },
    'truth': {
        'hub': [round(float(truth['hub'][0]), 2), round(float(truth['hub'][1]), 2)],
        'rotor_radius_px': round(float(truth['rotor_radius_px']), 2),
        'mask_area_frac': round(float((truth['mask'] > 0).mean()), 5),
        'cm_per_px': spec.cm_per_px,
    },
}
# 一片有真實葉尖偏移的情境：只存數值不存第二張 PNG。
# Dart 端用這些數值直接餵 compareBlades，驗「標記真的會觸發」——
# 輪廓抽取本身已由上面健康那組逐項對照過，兩者合起來就覆蓋了整條路徑。
spec_d = SceneSpec(width=384, height=512, cm_per_px=37.5, seed=1,
                   noise_sigma=1.2, cloud_strength=0.35, azimuth_deg=90.0,
                   tip_deflection_cm=(0.0, 900.0, 0.0))
img_d, _ = render_front(spec_d)
sg_d = seg.segment_turbine(img_d, sky_mode='local',
                           sky_model=seg.fit_local_sky(img_d, grid_step=GRID_STEP))
st_d = seg.find_structure(sg_d.mask, horizon_y=sg_d.horizon_y)
pr_d = profiles_from_structure(st_d)
cmp_d = compare_blades(pr_d, rotor_radius_m=spec_d.rotor_radius_m)
ref['deflected'] = {
    '_note': '第二片注入 900 cm 葉尖偏移（24 px @ 37.5 cm/px）；不存 PNG，只存數值',
    'profiles': [
        {'axis_angle_deg': round(float(pr.axis_angle_deg), 2),
         'radius_px': round(float(pr.radius_px), 3),
         'tip_deflection_px': round(float(pr.tip_deflection_px), 4),
         'residual_rms_px': round(float(pr.residual_rms_px), 4),
         'mean_width_px': round(float(pr.mean_width_px), 4)}
        for pr in pr_d],
    'any_flagged': bool(cmp_d['any_flagged']),
    'rotor_radius_m': spec_d.rotor_radius_m,
    'cm_per_px': round(float(cmp_d['cm_per_px']), 5),
    'metrics': {c['metric']: {'z': round(float(c['z']), 3),
                              'outlier_index': int(c['outlier_index']),
                              'outlier_deviation': round(float(c['outlier_deviation']), 4),
                              'outlier_deviation_cm': round(float(c['outlier_deviation_cm']), 3),
                              'others_spread': round(float(c['others_spread']), 4),
                              'flagged': bool(c['flagged'])}
                for c in cmp_d['comparisons']},
}

with open(os.path.join(OUT, 'blade_geometry_reference.json'), 'w',
          encoding='utf-8') as fh:
    json.dump(ref, fh, indent=1, ensure_ascii=False)
    fh.write('\n')
print(json.dumps({k: v for k, v in ref.items()
                  if k not in ('_readme', 'lab8_samples', 'bg_samples',
                               'scale_samples', 'dist_samples')},
                 indent=1, ensure_ascii=False))

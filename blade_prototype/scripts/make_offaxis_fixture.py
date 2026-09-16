#!/usr/bin/env python3
"""偏軸透視 + 姿態補償的 Dart 交叉驗證夾具（SPEC §13-11 決策的第三件事）。

一張合成的**地面偏軸正視照**（真實葉片：預彎 3 m、傾角 5°、錐角 2.5°；相機水平 300 m、
輪轂高 100 m、yaw 20°）+ Python 在同一張圖上的：原始三片互比（假葉尖偏移被標記）、
姿態估計（仰角由輪轂高 + 焦距、yaw 由塔軸偏移）、補償後的互比（不再標記）、預彎擬合。
Dart 的 `BladePoseService` 與 `runGeometryPipeline(hubHeightM:, focal35mm:)` 要在同一張圖上
得到同一個結論。改了 `pose.py`／`segmentation.py`／`synth.render_perspective` 就重跑這支。

場景刻意小（600×800、24 cm/px、葉片 250 px）：Dart 測試在 VM 裡跑分割。PNG 沒有 EXIF，
所以參考值裡帶 35 mm 等效焦距，Dart 測試用參數餵進去（App 端從 EXIF 讀同一個數）。
"""

from __future__ import annotations

import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from blade_proto import pose as P  # noqa: E402
from blade_proto.geometry import compare_blades, profiles_from_structure  # noqa: E402
from blade_proto.quality import assess_capture  # noqa: E402
from blade_proto.segmentation import find_structure, segment_turbine  # noqa: E402
from blade_proto.synth import CameraSpec, SceneSpec, render_perspective  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'flutter_app', 'test', 'assets')
HUB_HEIGHT_M = 100.0
REAL_BLADE = dict(prebend_m=3.0, rotor_tilt_deg=5.0, cone_deg=2.5)


def _round(o):
    if isinstance(o, float):
        return round(o, 4)
    if isinstance(o, dict):
        return {k: _round(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_round(v) for v in o]
    return o


def main() -> int:
    spec = SceneSpec(width=600, height=800, cm_per_px=24.0, seed=7)
    cam = CameraSpec.ground(300.0, HUB_HEIGHT_M, yaw_deg=20.0, **REAL_BLADE)
    img, truth = render_perspective(spec, cam)
    path = f'{OUT}/blade_offaxis_scene.png'
    cv2.imwrite(path, img, [cv2.IMWRITE_PNG_COMPRESSION, 9])
    img = cv2.imread(path)  # 與 Dart 端一樣從 PNG 讀回來

    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    verdict = assess_capture(seg, st)
    if not verdict.ok or verdict.metrics.get('view') != 'front' or len(st.blades) != 3:
        raise SystemExit(f'合成偏軸照沒有被正視放行：{verdict.to_dict()}')
    profs = profiles_from_structure(st)
    raw = compare_blades(profs, rotor_radius_m=spec.rotor_radius_m)

    long_side = max(spec.width, spec.height)
    f35 = cam.distance_m * spec.px_per_m * 36.0 / long_side
    est = P.estimate_pose(st, hub_height_m=HUB_HEIGHT_M, rotor_radius_m=spec.rotor_radius_m,
                          image_long_side_px=long_side, focal_35mm=f35)
    if not est.usable:
        raise SystemExit(f'姿態估不出來：{est.to_dict()}')
    comp = P.compensate_comparison(profs, est, spec.rotor_radius_m, cm_per_px=raw['cm_per_px'])
    raw_tip = next(c for c in raw['comparisons'] if c['metric'] == 'tip_deflection_px')
    comp_tip = next(c for c in comp['comparisons'] if c['metric'] == 'tip_deflection_px')
    if not raw_tip['flagged'] or comp_tip['flagged']:
        raise SystemExit(f'夾具要「原始標記、補償後不標記」才有意義：raw={raw_tip}, comp={comp_tip}')

    ref = {
        '_readme': '由 blade_prototype/scripts/make_offaxis_fixture.py 產生，勿手改。'
                   '偏軸透視 + 姿態補償（SPEC §13-11）的 Dart 交叉驗證：同一張圖、同一個結論。',
        'size': [img.shape[1], img.shape[0]],
        'cm_per_px_truth': spec.cm_per_px,
        'rotor_radius_m': spec.rotor_radius_m,
        'hub_height_m': HUB_HEIGHT_M,
        'focal_35mm': f35,
        'camera_truth': truth['camera'],
        'nacelle_overhang_truth_m': cam.nacelle_overhang_m,
        'overhang_prior_m': P.DEFAULT_NACELLE_OVERHANG_M,
        'tip_offset_prior_m': P.DEFAULT_TIP_OFFSET_M,
        'structure': {
            'hub': list(st.hub), 'tower_found': st.tower_found,
            'tower_x_at_hub_px': st.tower_x_at_hub_px,
            'n_blades': len(st.blades),
            'axis_angles_deg': [p.axis_angle_deg for p in profs],
            'radii_px': [p.radius_px for p in profs],
            'tip_deflection_px': [p.tip_deflection_px for p in profs],
        },
        'capture_verdict': {'ok': verdict.ok, 'view': verdict.metrics['view'],
                            'tip_radius_spread': verdict.metrics.get('tip_radius_spread')},
        'raw': {'cm_per_px': raw['cm_per_px'],
                'metrics': {c['metric']: {k: c[k] for k in ('flagged', 'z', 'outlier_index', 'outlier_deviation', 'outlier_deviation_cm')}
                            for c in raw['comparisons']}},
        'pose_estimate': est.to_dict(),
        'compensated': {k: v for k, v in comp.items() if k not in ('pose', 'comparisons')},
        'compensated_metrics': {c['metric']: {k: c[k] for k in ('flagged', 'z', 'outlier_index', 'outlier_deviation', 'outlier_deviation_cm', 'values')}
                                for c in comp['comparisons']},
    }
    with open(os.path.join(OUT, 'blade_offaxis_reference.json'), 'w', encoding='utf-8') as fh:
        json.dump(_round(ref), fh, indent=1, ensure_ascii=False)
        fh.write('\n')
    print(json.dumps(_round({k: v for k, v in ref.items() if k not in ('_readme',)}), ensure_ascii=False, indent=1))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

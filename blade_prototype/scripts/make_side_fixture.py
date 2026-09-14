#!/usr/bin/env python3
"""側視閘門的 Dart 交叉驗證夾具：一張合成側視照 + Python 端的閘門與垂掛葉片量測。

側視走另一組閘門規則（`quality.detect_side_view`，§13-12）；Dart 端 `BladeStructureGate`
與 `runGeometryPipeline` 要在同一張圖上得到同一個結論（side／垂掛葉片索引／不互比），
垂掛葉片的葉尖偏移要到像素以內。改了 `quality.py`／`segmentation.py`／`geometry.py`
的側視路徑就重跑這支，否則 `blade_geometry_compare_test.dart` 的側視測試會紅。

場景刻意小（600×900、15 cm/px、葉片 A 垂掛在六點鐘）：Dart 測試要在 VM 裡跑分割與
結構定位，1500×2000 會讓單元測試變成幾十秒。
"""

from __future__ import annotations

import json
import os
import sys

import cv2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from blade_proto.geometry import profiles_from_structure, side_view_summary  # noqa: E402
from blade_proto.quality import SIDE_VIEW_MAX_TILT_DEG, assess_capture  # noqa: E402
from blade_proto.segmentation import find_structure, segment_turbine  # noqa: E402
from blade_proto.synth import SceneSpec, render_side  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'flutter_app', 'test', 'assets')


def main() -> int:
    spec = SceneSpec(width=600, height=900, cm_per_px=15.0, azimuth_deg=270.0,
                     hub_frac=(0.5, 0.3), seed=11)
    img, truth = render_side(spec)
    cv2.imwrite(f'{OUT}/blade_side_scene.png', img, [cv2.IMWRITE_PNG_COMPRESSION, 9])
    # 與 Dart 端一樣從 PNG 讀回來，避免無損以外的任何差異
    img = cv2.imread(f'{OUT}/blade_side_scene.png')

    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    verdict = assess_capture(seg, st)
    if not verdict.ok or verdict.metrics.get('view') != 'side':
        raise SystemExit(f'合成側視照沒有被判成側視放行：{verdict.to_dict()}')
    profs = profiles_from_structure(st)
    summary = side_view_summary(profs, verdict.metrics['hanging_blade_index'])

    ref = {
        '_readme': '由 blade_prototype/scripts/make_side_fixture.py 產生，勿手改。'
                   '側視閘門（§13-12）的 Dart 交叉驗證：同一張圖、同一個結論。',
        'size': [img.shape[1], img.shape[0]],
        'cm_per_px': spec.cm_per_px,
        'side_view_max_tilt_deg': SIDE_VIEW_MAX_TILT_DEG,
        'n_blades': len(st.blades),
        'tip_angles_deg': [round(float(b.tip_angle_deg), 2) for b in st.blades],
        'tip_radii_px': [round(float(b.tip_radius_px), 1) for b in st.blades],
        'tower_found': bool(st.tower_found),
        'capture_verdict': {
            'ok': bool(verdict.ok),
            'view': verdict.metrics['view'],
            'hanging_blade_index': verdict.metrics['hanging_blade_index'],
            'n_reasons': len(verdict.reasons),
            'n_warnings': len(verdict.warnings),
        },
        'hanging_blade': {k: (round(v, 4) if isinstance(v, float) else v)
                          for k, v in summary['hanging_blade'].items()},
        'truth': {'azimuth_deg': spec.azimuth_deg,
                  'prebend_px': truth.get('prebend_px'),
                  'tip_deflection_px': truth.get('tip_deflection_px')},
    }
    with open(os.path.join(OUT, 'blade_side_reference.json'), 'w', encoding='utf-8') as fh:
        json.dump(ref, fh, indent=1, ensure_ascii=False)
    print(json.dumps({k: v for k, v in ref.items() if k != '_readme'}, ensure_ascii=False, indent=1))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

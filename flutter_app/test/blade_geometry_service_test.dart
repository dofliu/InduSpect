import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:induspect_ai/services/blade_geometry_service.dart';
import 'package:induspect_ai/services/blade_image_ops.dart';
import 'package:induspect_ai/services/blade_structure_service.dart';

/// 幾何層 Dart 實作對照 Python 原型（`blade_prototype/blade_proto/segmentation.py`）。
///
/// 參考值由 `blade_prototype/scripts/make_geometry_fixture.py` 在同一張
/// `blade_front_scene.png` 上量出並凍結。**逐階段對照**：色空間 → 天空模型場 →
/// 距離 → 遮罩 → 地平線 → 結構。這樣某個符號寫錯時會在它發生的那一階段紅掉。
///
/// 不要求逐位相同：`package:image` 的 PNG 解碼、雙線性放大的實作細節、
/// 圓盤與圓的光柵化都與 OpenCV 有微小差異。要求的是**同一個結構**——
/// 輪轂位置、塔架、三片葉尖的半徑與角度，那些才是幾何層的輸出。
void main() {
  late Map<String, dynamic> ref;
  late img.Image scene;

  setUpAll(() {
    ref = jsonDecode(
      File('test/assets/blade_geometry_reference.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final decoded = img.decodePng(
        File('test/assets/blade_front_scene.png').readAsBytesSync());
    scene = decoded!;
  });

  BladeGeometryParams paramsOf() => BladeGeometryParams(
        gridStep: ref['grid_step'] as int,
      );

  test('夾具本身：尺寸與 Python 產生時一致', () {
    final size = (ref['size'] as List).cast<int>();
    expect([scene.width, scene.height], size);
  });

  test('第一階段 — 8-bit Lab：逐點與 OpenCV 相符（±2 量化）', () {
    final samples = ref['lab8_samples'] as Map<String, dynamic>;
    samples.forEach((key, expected) {
      final p = key.split(',').map(int.parse).toList();
      final px = scene.getPixel(p[0], p[1]);
      final got = BladeImageOps.lab8OfRgb(
          px.r.toInt(), px.g.toInt(), px.b.toInt());
      final want = (expected as List).cast<int>();
      for (var c = 0; c < 3; c++) {
        expect(got[c], closeTo(want[c], 2),
            reason: '($key) 通道 $c；RGB=(${px.r},${px.g},${px.b})');
      }
    });
  });

  group('第二階段 — 局部天空模型', () {
    test('核大小與 Python 相同（0.20 × 長邊，取奇數）', () {
      final m = BladeGeometryService.fitLocalSky(scene, params: paramsOf());
      expect(m.kernelPx, ref['kernel_px'] as int);
      expect(m.kernelPx.isOdd, isTrue);
      expect(m.w, scene.width);
      expect(m.h, scene.height);
    });

    test('背景場與尺度場逐點與 Python 相符', () {
      final m = BladeGeometryService.fitLocalSky(scene, params: paramsOf());
      final bg = ref['bg_samples'] as Map<String, dynamic>;
      bg.forEach((key, expected) {
        final p = key.split(',').map(int.parse).toList();
        final o = (p[1] * m.w + p[0]) * 3;
        final want = (expected as List).cast<num>();
        for (var c = 0; c < 3; c++) {
          expect(m.bg[o + c], closeTo(want[c].toDouble(), 3.0),
              reason: 'bg($key) 通道 $c');
        }
      });
      final sc = ref['scale_samples'] as Map<String, dynamic>;
      sc.forEach((key, expected) {
        final p = key.split(',').map(int.parse).toList();
        final o = (p[1] * m.w + p[0]) * 3;
        final want = (expected as List).cast<num>();
        for (var c = 0; c < 3; c++) {
          expect(m.scale[o + c], closeTo(want[c].toDouble(), 1.5),
              reason: 'scale($key) 通道 $c');
        }
      });
    });

    test('尺度場一律不低於下限——純色天空不會除以 0', () {
      final m = BladeGeometryService.fitLocalSky(scene, params: paramsOf());
      for (final v in m.scale) {
        expect(v, greaterThanOrEqualTo(m.minScale - 1e-6));
      }
    });
  });

  group('第三階段 — 距離與遮罩', () {
    test('天空的距離接近 0、結構的距離遠高於門檻', () {
      final m = BladeGeometryService.fitLocalSky(scene, params: paramsOf());
      final dist = BladeGeometryService.localSkyDistance(scene, m);
      final samples = ref['dist_samples'] as Map<String, dynamic>;
      samples.forEach((key, expected) {
        final p = key.split(',').map(int.parse).toList();
        final got = dist[p[1] * scene.width + p[0]];
        final want = (expected as num).toDouble();
        // 距離是三通道殘差比值的範數，對 Lab 的 ±1 量化較敏感 → 容差放寬
        expect(got, closeTo(want, math.max(1.5, want * 0.25)),
            reason: 'dist($key)：Dart $got vs Python $want');
      });
    });

    test('遮罩面積與 Python 同量級，且沒有把天空吃進來', () {
      final seg = BladeGeometryService.segmentTurbine(scene, params: paramsOf());
      final want = (ref['mask_area_frac'] as num).toDouble();
      expect(seg.maskAreaFrac, closeTo(want, 0.012),
          reason: 'Dart ${seg.maskAreaFrac} vs Python $want');
      // 真值的前景占比是上限：抓超過它太多就是把天空吃進來了
      final truthFrac =
          ((ref['truth'] as Map)['mask_area_frac'] as num).toDouble();
      expect(seg.maskAreaFrac, lessThan(truthFrac * 1.5));
      expect(seg.threshold, (ref['threshold'] as num).toDouble());
    });

    test('地平線：這張合成圖沒有地面帶，兩邊都該回 null', () {
      final seg = BladeGeometryService.segmentTurbine(scene, params: paramsOf());
      expect(seg.horizonY, ref['horizon_y']);
    });
  });

  group('第四階段 — 結構定位', () {
    late BladeStructure st;
    late Map<String, dynamic> truth;

    setUpAll(() {
      final seg = BladeGeometryService.segmentTurbine(scene, params: paramsOf());
      st = BladeStructureService.findStructure(
          seg.mask, seg.w, seg.h, horizonY: seg.horizonY);
      truth = (ref['truth'] as Map).cast<String, dynamic>();
    });

    test('輪轂位置與 Python 一致，且都接近合成真值', () {
      expect(st.ok, isTrue, reason: st.failure);
      final py = (ref['hub'] as List).cast<num>();
      final d = math.sqrt(math.pow(st.hubX - py[0], 2).toDouble() +
          math.pow(st.hubY - py[1], 2).toDouble());
      expect(d, lessThan(4.0),
          reason: 'Dart (${st.hubX.toStringAsFixed(1)}, '
              '${st.hubY.toStringAsFixed(1)}) vs Python $py');

      final gt = (truth['hub'] as List).cast<num>();
      final dTruth = math.sqrt(math.pow(st.hubX - gt[0], 2).toDouble() +
          math.pow(st.hubY - gt[1], 2).toDouble());
      final rotorR = (truth['rotor_radius_px'] as num).toDouble();
      expect(dTruth, lessThan(0.05 * rotorR),
          reason: '輪轂誤差要在轉子半徑的 5% 內（真實語料的命中判準）');
      expect(st.hubRefined, ref['hub_refined'] as bool);
    });

    test('塔架：找到、近乎垂直、寬度同量級', () {
      expect(st.towerFound, ref['tower_found'] as bool);
      expect(st.towerAngleDeg.abs(), lessThan(2.0),
          reason: '合成正視的塔架是垂直的');
      expect(st.towerWidthPx,
          closeTo((ref['tower_width_px'] as num).toDouble(), 3.0));
    });

    test('三片葉片：數量、葉尖半徑、方位角都與 Python 一致', () {
      expect(st.blades.length, ref['n_blades'] as int);
      final want = (ref['blades'] as List).cast<Map<String, dynamic>>();
      final rotorR = (truth['rotor_radius_px'] as num).toDouble();
      for (var i = 0; i < want.length; i++) {
        final b = st.blades[i];
        expect(b.tipRadiusPx,
            closeTo((want[i]['tip_radius_px'] as num).toDouble(), 0.03 * rotorR),
            reason: '第 $i 片半徑');
        expect(b.tipAngleDeg,
            closeTo((want[i]['tip_angle_deg'] as num).toDouble(), 4.0),
            reason: '第 $i 片方位角');
      }
    });

    test('三片葉尖半徑一致（同型三片必等長）——這是拍攝閘門唯一有效的判據', () {
      final spread = st.tipRadiusSpread;
      expect(spread, isNotNull);
      expect(spread!, lessThan(0.15),
          reason: '離散度 ${(spread * 100).toStringAsFixed(1)}%');
    });

    test('葉尖角度依方位排序，120° 分佈', () {
      final angles = st.blades.map((b) => b.tipAngleDeg).toList();
      for (var i = 1; i < angles.length; i++) {
        expect(angles[i], greaterThan(angles[i - 1]),
            reason: '輸出要依方位角排序，報告上「哪一片」才對得起來');
      }
      expect(angles[1] - angles[0], closeTo(120, 8));
      expect(angles[2] - angles[1], closeTo(120, 8));
    });

    test('遮罩為空時回明確失敗，不丟例外', () {
      final empty = Uint8List(100 * 100);
      final r = BladeStructureService.findStructure(empty, 100, 100);
      expect(r.ok, isFalse);
      expect(r.failure, contains('遮罩為空'));
      expect(r.blades, isEmpty);
      expect(r.tipRadiusSpread, isNull);
    });

    test('第二個轉子：這張只有一台，應回 0', () {
      final seg = BladeGeometryService.segmentTurbine(scene, params: paramsOf());
      final r = BladeStructureService.findSecondRotor(
          seg.mask, seg.w, seg.h, st, horizonY: seg.horizonY);
      expect(r[0], lessThan(0.3 * st.rotorRadiusPx),
          reason: '單台照片不該找出等大的第二個轉子');
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_geometry_compare.dart';
import 'package:induspect_ai/services/blade_pose_service.dart';

/// 姿態估計與透視補償（`blade_pose_service.dart`，對照 `blade_proto/pose.py`）。
///
/// 守：①單項估計是純幾何；②留一法擬合把單片缺陷留在殘差裡；③與 Python 在同一張合成偏軸照上
/// 得到同一個結論——原始互比標出約 240 cm 的假葉尖偏移、補償後不標記、預彎擬合回到 3 m 附近、
/// yaw 太大時半徑不補；④沒有輪轂高度或焦距就沒有姿態也沒有補償。
void main() {
  late Map<String, dynamic> ref;
  late Uint8List bytes;

  setUpAll(() {
    ref = jsonDecode(
      File('test/assets/blade_offaxis_reference.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    bytes = Uint8List.fromList(
        File('test/assets/blade_offaxis_scene.png').readAsBytesSync());
  });

  double num_(dynamic v) => (v as num).toDouble();
  List<double> nums(dynamic v) => (v as List).map((e) => (e as num).toDouble()).toList();

  group('單項估計是純幾何', () {
    test('焦距、距離、仰角、yaw', () {
      expect(BladePoseService.focalPxFrom35mm(24.0, 4000), closeTo(4000 * 24 / 36, 1e-9));
      expect(BladePoseService.distanceFromScale(60.0, 500.0, 2500.0), closeTo(300.0, 1e-9));
      expect(BladePoseService.distanceFromScale(60.0, 0.0, 2500.0), isNull);
      expect(BladePoseService.elevationFromSlant(100.0, 50.0), isNull,
          reason: '距離比高度差還短：姿態不成立');
      final got = BladePoseService.elevationFromHorizontal(100.0, 300.0)!;
      expect(got.$1, closeTo(18.16, 0.05));
      expect(got.$2, closeTo(315.7, 0.1));
      expect(BladePoseService.yawFromHubOffset(2.5, overhangM: 5.0), closeTo(30.0, 1e-9));
      expect(BladePoseService.yawFromHubOffset(9.0, overhangM: 5.0), closeTo(90.0, 1e-9),
          reason: '超過 overhang 夾在 ±90°');
      expect(BladePoseService.yawFromHubOffset(1.0, overhangM: 0.0), isNull);
    });

    test('留一法擬合把多出來的那一片留在殘差裡', () {
      final g = [2.5, -3.8, 2.0];
      final d = [3 * 2.5, 3 * -3.8 + 40.0, 3 * 2.0];
      final fit = BladePoseService.fitPrebend(d, g);
      expect(fit.wM, closeTo(3.0, 1e-9));
      expect(fit.outlierIndex, 1);
      expect(fit.residuals[1], closeTo(40.0, 1e-9));
      expect(fit.residuals[0].abs(), lessThan(1e-9));
      expect(fit.residuals[2].abs(), lessThan(1e-9));
    });
  });

  group('與 Python 的夾具對照（合成地面偏軸正視照）', () {
    test('投影基底與 Python 同一組數', () {
      final pe = ref['pose_estimate'] as Map<String, dynamic>;
      final pose = BladePoseEstimate(
        elevationDeg: num_(pe['elevation_deg']),
        yawDeg: num_(pe['yaw_deg']),
        distanceM: num_(pe['distance_m']),
        rotorTiltDeg: num_(pe['rotor_tilt_deg']),
      );
      final st = ref['structure'] as Map<String, dynamic>;
      final axes = nums(st['axis_angles_deg']);
      final radii = nums(st['radii_px'])..sort();
      final pxPerM = radii[1] / num_(ref['rotor_radius_m']);
      final comp = ref['compensated'] as Map<String, dynamic>;
      final basis = BladePoseService.deflectionBasis(axes, num_(ref['rotor_radius_m']), pose, pxPerM);
      final wantBasis = nums(comp['deflection_basis_px_per_m']);
      for (var i = 0; i < 3; i++) {
        expect(basis[i], closeTo(wantBasis[i], 0.01), reason: '第 $i 片的預彎基底');
      }
      final (ratios, along) = BladePoseService.radialBasis(axes, num_(ref['rotor_radius_m']), pose, pxPerM);
      final wantRatios = nums(comp['radius_ratios']);
      final wantAlong = nums(comp['radius_along_px_per_m']);
      for (var i = 0; i < 3; i++) {
        expect(ratios[i], closeTo(wantRatios[i], 1e-3));
        expect(along[i], closeTo(wantAlong[i], 0.01));
      }
    });

    test('★ 原始互比標出假葉尖偏移；帶輪轂高度與焦距後估出姿態、補償後不再標記', () {
      final rotorRadiusM = num_(ref['rotor_radius_m']);
      final raw = runGeometryPipeline(bytes, rotorRadiusM: rotorRadiusM);
      expect(raw.ok, isTrue, reason: raw.reasons.join('；'));
      expect(raw.metrics['view'], 'front');
      expect(raw.metrics['n_blades'], 3);
      final rawTip = raw.comparisons.singleWhere((c) => c.metric == 'tip_deflection_px');
      final wantRawTip = ref['raw']['metrics']['tip_deflection_px'] as Map<String, dynamic>;
      expect(rawTip.flagged, wantRawTip['flagged'] as bool, reason: '原始互比要標出假葉尖偏移');
      expect(rawTip.outlierIndex, wantRawTip['outlier_index']);
      expect(rawTip.outlierDeviationCm!, closeTo(num_(wantRawTip['outlier_deviation_cm']), 60.0));
      expect(raw.pose, isNull);
      expect(raw.compensation, isNull);
      expect(raw.metrics['perspective_compensated'], isFalse);
      expect(raw.metrics['pose_note'], contains('輪轂高度'));

      final out = runGeometryPipeline(bytes,
          rotorRadiusM: rotorRadiusM,
          hubHeightM: num_(ref['hub_height_m']),
          focal35mm: num_(ref['focal_35mm']));
      expect(out.ok, isTrue);
      final pe = ref['pose_estimate'] as Map<String, dynamic>;
      expect(out.pose, isNotNull);
      expect(out.pose!.usable, isTrue, reason: out.pose!.notes.join('；'));
      expect(out.pose!.elevationDeg!, closeTo(num_(pe['elevation_deg']), 0.8));
      expect(out.pose!.yawDeg!, closeTo(num_(pe['yaw_deg']), 3.0));
      expect(out.pose!.distanceM!, closeTo(num_(pe['distance_m']), 0.03 * num_(pe['distance_m'])));
      expect(out.pose!.elevationMethod, 'focal');
      expect(out.pose!.yawMethod, 'tower_offset');
      // 姿態對真值（渲染用的相機）：仰角差 < 2°、yaw 方向對量級對（overhang 先驗 5 對渲染 6）
      final cam = ref['camera_truth'] as Map<String, dynamic>;
      expect((out.pose!.elevationDeg! - num_(cam['elevation_deg'])).abs(), lessThan(2.0));
      expect(out.pose!.yawDeg!, inInclusiveRange(15.0, 32.0));

      final comp = out.compensation!;
      final wantComp = ref['compensated'] as Map<String, dynamic>;
      expect(comp.deflectionCompensated, wantComp['deflection_compensated']);
      expect(comp.radiusCompensated, wantComp['radius_compensated'],
          reason: 'yaw 估約 25° > 15°：半徑不補');
      expect(comp.prebendFitM, closeTo(num_(wantComp['prebend_fit_m']), 0.5));
      final tip = out.comparisons.singleWhere((c) => c.metric == 'tip_deflection_px');
      final wantTip = ref['compensated_metrics']['tip_deflection_px'] as Map<String, dynamic>;
      expect(tip.flagged, wantTip['flagged'] as bool, reason: '補償後不該再標記');
      expect(tip.outlierDeviationCm!.abs(), lessThan(60.0));
      final rad = out.comparisons.singleWhere((c) => c.metric == 'radius_px');
      final wantRad = ref['compensated_metrics']['radius_px'] as Map<String, dynamic>;
      expect(rad.flagged, wantRad['flagged'] as bool, reason: '半徑沒補，與原始相同');
      // 其他兩個量不動
      expect(out.comparisons.map((c) => c.metric).toSet(),
          {'tip_deflection_px', 'radius_px', 'mean_width_px', 'residual_rms_px'});
      // 帳目都在 metrics 裡
      expect(out.metrics['perspective_compensated'], isTrue);
      expect((out.metrics['pose'] as Map)['usable'], isTrue);
      expect(out.metrics['tip_deflection_raw_px'], hasLength(3));
      expect(out.metrics['prebend_fit_m'], comp.prebendFitM);
      expect(out.metrics['compensation_note'], contains('半徑未補償'));
    });

    test('沒有焦距就估不出仰角：不補償、留下原因', () {
      final out = runGeometryPipeline(bytes,
          rotorRadiusM: num_(ref['rotor_radius_m']), hubHeightM: num_(ref['hub_height_m']));
      expect(out.ok, isTrue);
      expect(out.pose, isNotNull);
      expect(out.pose!.usable, isFalse);
      expect(out.pose!.yawDeg, isNotNull, reason: 'yaw 只要塔軸就估得出來');
      expect(out.compensation, isNull);
      expect(out.metrics['perspective_compensated'], isFalse);
      expect(out.metrics['pose_note'], contains('焦距'));
    });

    test('沒有型錄直徑就沒有尺度：yaw 也估不出來', () {
      final out = runGeometryPipeline(bytes,
          hubHeightM: num_(ref['hub_height_m']), focal35mm: num_(ref['focal_35mm']));
      expect(out.compensation, isNull);
      expect(out.metrics['pose_note'], contains('型錄轉子直徑'));
    });

    test('compensate 的門：姿態不可用、不是三片、沒有半徑 → null', () {
      final out = runGeometryPipeline(bytes, rotorRadiusM: num_(ref['rotor_radius_m']));
      final unusable = const BladePoseEstimate(elevationDeg: null, yawDeg: 10.0, distanceM: null);
      expect(BladePoseService.compensate(out.profiles, unusable, 60.0), isNull);
      final pose = const BladePoseEstimate(elevationDeg: 18.0, yawDeg: 10.0, distanceM: 316.0);
      expect(BladePoseService.compensate(out.profiles, pose, null), isNull);
      expect(BladePoseService.compensate(out.profiles.take(2).toList(), pose, 60.0), isNull);
    });
  });
}

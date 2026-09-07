import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:induspect_ai/services/blade_capture_gate.dart';
import 'package:induspect_ai/services/blade_geometry_compare.dart';
import 'package:induspect_ai/services/blade_geometry_service.dart';
import 'package:induspect_ai/services/blade_structure_service.dart';

/// 幾何層（中心線／彎曲／三片互比 + 拍攝閘門）對照 Python 原型。
///
/// 參考值由 `blade_prototype/scripts/make_geometry_fixture.py` 產生，含兩組情境：
/// **健康**（同一張 PNG，逐項對照輪廓數值）與**單片偏移**（只存數值，
/// 驗「標記真的會觸發」）。兩者合起來覆蓋整條路徑的兩個方向。
void main() {
  late Map<String, dynamic> ref;
  late img.Image scene;

  setUpAll(() {
    ref = jsonDecode(
      File('test/assets/blade_geometry_reference.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    scene = img.decodePng(
        File('test/assets/blade_front_scene.png').readAsBytesSync())!;
  });

  BladeGeometryParams paramsOf() =>
      BladeGeometryParams(gridStep: ref['grid_step'] as int);

  BladeStructure structureOf() {
    final seg = BladeGeometryService.segmentTurbine(scene, params: paramsOf());
    return BladeStructureService.findStructure(seg.mask, seg.w, seg.h,
        horizonY: seg.horizonY);
  }

  group('輪廓抽取（健康那台）', () {
    late List<BladeProfile> profiles;
    late List<Map<String, dynamic>> want;

    setUpAll(() {
      profiles = BladeGeometryCompare.profilesFromStructure(structureOf())
        ..sort((a, b) => a.axisAngleDeg.compareTo(b.axisAngleDeg));
      want = (ref['profiles'] as List).cast<Map<String, dynamic>>();
    });

    test('三片都抽得出輪廓，方位角與 Python 一致', () {
      expect(profiles.length, want.length);
      for (var i = 0; i < want.length; i++) {
        expect(profiles[i].axisAngleDeg,
            closeTo((want[i]['axis_angle_deg'] as num).toDouble(), 4.0),
            reason: '第 $i 片軸線方位');
      }
    });

    test('葉長與平均弦寬與 Python 同量級', () {
      for (var i = 0; i < want.length; i++) {
        final wantR = (want[i]['radius_px'] as num).toDouble();
        expect(profiles[i].radiusPx, closeTo(wantR, 0.04 * wantR),
            reason: '第 $i 片葉長');
        final wantW = (want[i]['mean_width_px'] as num).toDouble();
        expect(profiles[i].meanWidthPx, closeTo(wantW, 0.25 * wantW),
            reason: '第 $i 片弦寬');
      }
    });

    test('健康葉片的葉尖偏移接近 0（不是憑空生出彎曲）', () {
      for (final p in profiles) {
        expect(p.tipDeflectionPx.abs(), lessThan(0.02 * p.radiusPx),
            reason: '合成的是直葉片，偏移應在葉長的 2% 內');
      }
    });

    test('輪廓陣列的長度與值域都合理', () {
      for (final p in profiles) {
        expect(p.u.length, 48);
        expect(p.center.length, 48);
        expect(p.width.length, 48);
        for (final v in p.u) {
          expect(v, inInclusiveRange(0.0, 1.0));
        }
        for (final v in p.width) {
          expect(v, greaterThan(0.0), reason: '弦寬不可能是負的');
          expect(v.isFinite, isTrue);
        }
      }
    });
  });

  group('三片互比', () {
    test('健康那台：四個量都不標記（與 Python 相同）', () {
      final cmp = BladeGeometryCompare.compareBlades(
          BladeGeometryCompare.profilesFromStructure(structureOf()));
      expect(cmp.nBlades, 3);
      expect(cmp.anyFlagged, ref['comparison']['any_flagged'] as bool);
      for (final c in cmp.comparisons) {
        expect(c.flagged, isFalse, reason: '${c.metric} 不該被標記');
        expect(c.z, lessThan(3.0), reason: '${c.metric} 的 z');
      }
    });

    test('單片注入 24 px 偏移：只有葉尖偏移被標記，且指對那一片', () {
      final d = ref['deflected'] as Map<String, dynamic>;
      final pr = (d['profiles'] as List).cast<Map<String, dynamic>>();
      // 用 Python 量到的輪廓數值直接餵互比——這一段是純算術，
      // 輪廓抽取本身已由上面健康那組對照過
      final profiles = [
        for (var i = 0; i < pr.length; i++)
          BladeProfile(
            index: i,
            axisAngleDeg: (pr[i]['axis_angle_deg'] as num).toDouble(),
            radiusPx: (pr[i]['radius_px'] as num).toDouble(),
            u: Float64List(0),
            center: Float64List(0),
            edgeLo: Float64List(0),
            edgeHi: Float64List(0),
            width: Float64List(0),
            bendCoeff: 0,
            tipDeflectionPx: (pr[i]['tip_deflection_px'] as num).toDouble(),
            residualRmsPx: (pr[i]['residual_rms_px'] as num).toDouble(),
            meanWidthPx: (pr[i]['mean_width_px'] as num).toDouble(),
            tipX: 0,
            tipY: 0,
          )
      ];
      final cmp = BladeGeometryCompare.compareBlades(profiles);
      expect(cmp.anyFlagged, isTrue);

      final wm = (d['metrics'] as Map<String, dynamic>);
      for (final c in cmp.comparisons) {
        final w = wm[c.metric] as Map<String, dynamic>;
        expect(c.flagged, w['flagged'] as bool, reason: '${c.metric} 的標記');
        expect(c.z, closeTo((w['z'] as num).toDouble(), 0.05),
            reason: '${c.metric} 的 z');
        expect(c.outlierDeviation,
            closeTo((w['outlier_deviation'] as num).toDouble(), 0.01),
            reason: '${c.metric} 的偏差');
        expect(c.othersSpread,
            closeTo((w['others_spread'] as num).toDouble(), 0.01),
            reason: '${c.metric} 的另兩片彼此差');
        if (c.flagged) {
          expect(c.outlierIndex, w['outlier_index'] as int,
              reason: '${c.metric} 要指對是哪一片');
        }
      }
    });

    test('少於兩片不互比，明說原因', () {
      final cmp = BladeGeometryCompare.compareBlades(const []);
      expect(cmp.comparisons, isEmpty);
      expect(cmp.note, contains('無法互比'));
      expect(cmp.anyFlagged, isFalse);
    });

    test('離群者要同時「z 夠大」且「明顯大於另兩片彼此差」', () {
      // 三片都散開：即使離群者 z 大，只要另兩片也散得差不多就不該標記
      final noisy = BladeGeometryCompare.compareMetric(
          'tip_deflection_px', [0.0, 10.0, 20.0], 1.0);
      expect(noisy.z, greaterThan(3.0));
      expect(noisy.flagged, isFalse,
          reason: '另兩片彼此差 20、離群者偏 10，這是三片都不一樣，不是一片離群');

      final clean = BladeGeometryCompare.compareMetric(
          'tip_deflection_px', [0.0, 0.3, 20.0], 1.0);
      expect(clean.flagged, isTrue);
      expect(clean.outlierIndex, 2);
    });

    test('NaN 不參與比較，也不產生標記', () {
      final c = BladeGeometryCompare.compareMetric(
          'radius_px', [double.nan, double.nan, 5.0], 1.0);
      expect(c.flagged, isFalse);
      expect(c.z.isNaN, isTrue);
    });
  });

  group('拍攝閘門（結構層）', () {
    test('健康那台放行，理由與警告數與 Python 相同', () {
      final seg = BladeGeometryService.segmentTurbine(scene, params: paramsOf());
      final st = BladeStructureService.findStructure(seg.mask, seg.w, seg.h,
          horizonY: seg.horizonY);
      final v = BladeStructureGate.judge(seg: seg, structure: st);
      final want = ref['capture_verdict'] as Map<String, dynamic>;
      expect(v.ok, want['ok'] as bool);
      expect(v.reasons.length, want['n_reasons'] as int, reason: '${v.reasons}');
      expect(v.warnings.length, want['n_warnings'] as int,
          reason: '${v.warnings}');
      expect((v.metrics['tip_radius_spread'] as num).toDouble(),
          closeTo((want['tip_radius_spread'] as num).toDouble(), 0.02));
    });

    test('結構定位失敗 → 拒收，並給重拍方向而不是「沒問題」', () {
      final v = BladeStructureGate.judge(error: '遮罩為空');
      expect(v.ok, isFalse);
      expect(v.reasons.single, contains('重拍'));
      expect(v.reasons.single, isNot(contains('合格')));
    });

    test('三片葉尖半徑差太多 → 拒收（閘門唯一真正有鑑別力的條件）', () {
      final st = BladeStructure(
        blades: [
          _tip(100),
          _tip(102),
          _tip(160), // 差 37%
        ],
        towerFound: true,
        hubRefined: true,
      );
      final v = BladeStructureGate.judge(structure: st, checkSecondRotor: false);
      expect(v.ok, isFalse);
      expect(v.reasons.join(), contains('三片等長'));
      expect((v.metrics['tip_radius_spread'] as num).toDouble(),
          greaterThan(BladeStructureGate.maxRadiusSpread));
    });

    test('葉片數不對 → 拒收，並說明六點鐘方位的可能', () {
      final v = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tip(100), _tip(101)],
              towerFound: true,
              hubRefined: true),
          checkSecondRotor: false);
      expect(v.ok, isFalse);
      expect(v.reasons.join(), contains('六點鐘'));
    });

    test('沒塔架、輪轂未精修 → 只警告不拒收', () {
      final v = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tip(100), _tip(101), _tip(102)],
              towerFound: false,
              hubRefined: false),
          checkSecondRotor: false);
      expect(v.ok, isTrue, reason: '這兩項只降低精度，不代表量到的是別的東西');
      expect(v.warnings.length, 2);
      expect(v.warnings.join(), contains('塔架'));
      expect(v.warnings.join(), contains('精修'));
    });

    test('門檻值與 Python 的常數相同', () {
      expect(BladeStructureGate.maxRadiusSpread, 0.15);
      expect(BladeStructureGate.maxMaskFrac, 0.15);
      expect(BladeStructureGate.minMaskFrac, 0.0015);
      expect(BladeStructureGate.secondRotorWarnRatio, 0.5);
    });
  });

  group('整條幾何管線', () {
    test('閘門放行時才有互比結果；拒收時一定是空的', () {
      final bytes = File('test/assets/blade_front_scene.png').readAsBytesSync();
      final out = runGeometryPipeline(Uint8List.fromList(bytes),
          params: paramsOf());
      expect(out.ok, isTrue, reason: out.reasons.join('；'));
      expect(out.comparisons, hasLength(4));
      expect(out.metrics['n_blades'], 3);
      expect(out.metrics['rotor_radius_px'], isNotNull);
    });

    test('壞掉的位元組 → 明確失敗，不丟例外', () {
      // `img.decodeImage` 對很短的位元組**會丟 RangeError**（在 GIF 的格式嗅探裡
      // 讀字串讀過界），不是只回 null。這條測試就是為此存在的——
      // 現場的檔案可能被截斷，而這條路徑的承諾是「明確失敗」。
      for (final bad in [
        <int>[1, 2, 3],
        <int>[],
        List<int>.filled(40, 7),
      ]) {
        final out = runGeometryPipeline(Uint8List.fromList(bad));
        expect(out.ok, isFalse, reason: '長度 ${bad.length}');
        expect(out.reasons.join(), contains('重新拍攝'));
        expect(out.comparisons, isEmpty,
            reason: '拒收時不能有互比結果——那組數字會自洽但完全錯');
      }
    });
  });
}

BladeTip _tip(double radius) => BladeTip(
      area: 500,
      tipX: 0,
      tipY: 0,
      tipRadiusPx: radius,
      tipAngleDeg: 0,
      xs: Int32List(0),
      ys: Int32List(0),
    );

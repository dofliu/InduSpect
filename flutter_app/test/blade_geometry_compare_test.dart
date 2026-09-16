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

    test('★ 型錄轉子半徑 → 由三片葉長中位數反推 cm/px，與 Python 同一個數（A4）', () {
      final profiles =
          BladeGeometryCompare.profilesFromStructure(structureOf());
      final wantCmp = ref['comparison'] as Map<String, dynamic>;
      final rotorRadiusM = (wantCmp['rotor_radius_m'] as num).toDouble();
      final cmp = BladeGeometryCompare.compareBlades(profiles,
          rotorRadiusM: rotorRadiusM);
      final wantCm = (wantCmp['cm_per_px'] as num).toDouble();
      final truthCm = (ref['truth']['cm_per_px'] as num).toDouble();
      expect(cmp.cmPerPx, isNotNull);
      // Dart 的葉長與 Python 差在 4% 內（輪廓測試那條的容忍），尺度跟著差
      expect(cmp.cmPerPx!, closeTo(wantCm, 0.04 * wantCm),
          reason: 'cm/px 要與 Python 反推的一致');
      expect(cmp.cmPerPx!, closeTo(truthCm, 0.04 * truthCm),
          reason: '合成場景的真值是 $truthCm cm/px');
      for (final c in cmp.comparisons) {
        expect(c.outlierDeviationCm, isNotNull, reason: c.metric);
        expect(c.outlierDeviationCm!,
            closeTo(c.outlierDeviation * cmp.cmPerPx!, 1e-9),
            reason: '${c.metric}：cm 只是 px × 尺度，不改任何判定');
        expect(c.toJson()['outlier_deviation_cm'], isNotNull);
      }
      expect(cmp.toJson()['cm_per_px'], cmp.cmPerPx);
    });

    test('沒有型錄半徑就沒有任何 cm 值——不猜尺度', () {
      final cmp = BladeGeometryCompare.compareBlades(
          BladeGeometryCompare.profilesFromStructure(structureOf()));
      expect(cmp.cmPerPx, isNull);
      for (final c in cmp.comparisons) {
        expect(c.outlierDeviationCm, isNull, reason: c.metric);
        expect(c.toJson().containsKey('outlier_deviation_cm'), isFalse);
      }
      expect(cmp.toJson().containsKey('cm_per_px'), isFalse,
          reason: '沒尺度時 JSON 形狀與以前完全一樣');
    });

    test('resolveScale：直接給的尺度優先；半徑或葉長不是正數就沒有尺度', () {
      expect(BladeGeometryCompare.resolveScale(12.0, 60.0, 500.0), 12.0);
      expect(BladeGeometryCompare.resolveScale(null, 60.0, 500.0),
          closeTo(12.0, 1e-12));
      expect(BladeGeometryCompare.resolveScale(null, null, 500.0), isNull);
      expect(BladeGeometryCompare.resolveScale(null, 0.0, 500.0), isNull,
          reason: '半徑 0 與 Python 的 `if rotor_radius_m:` 一樣算沒給');
      expect(BladeGeometryCompare.resolveScale(null, -60.0, 500.0), isNull);
      expect(BladeGeometryCompare.resolveScale(null, 60.0, 0.0), isNull);
      expect(BladeGeometryCompare.resolveScale(null, 60.0, double.nan), isNull);
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
      final cmp = BladeGeometryCompare.compareBlades(profiles,
          rotorRadiusM: (d['rotor_radius_m'] as num).toDouble());
      expect(cmp.anyFlagged, isTrue);
      // 同一組輪廓數值 → 同一個尺度（純算術，要到小數第四位）
      expect(cmp.cmPerPx!, closeTo((d['cm_per_px'] as num).toDouble(), 1e-4));

      final wm = (d['metrics'] as Map<String, dynamic>);
      for (final c in cmp.comparisons) {
        final w = wm[c.metric] as Map<String, dynamic>;
        expect(c.flagged, w['flagged'] as bool, reason: '${c.metric} 的標記');
        expect(c.outlierDeviationCm!,
            closeTo((w['outlier_deviation_cm'] as num).toDouble(), 0.5),
            reason: '${c.metric} 的偏差（cm）');
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

    // n = 0 與 n = 1/2 的成因不同。75 張真實照片裡 18 張是 n = 0，而 2026-09-14 之前
    // 三種都印「可能有葉片貼在塔架上，請等轉子轉開」——那會把現場的人帶去等一件不會發生的事。
    test('一片都沒定位到 → 指向取景與分割，不叫人等轉子', () {
      final v = BladeStructureGate.judge(
          structure: const BladeStructure(blades: [], towerFound: true),
          checkSecondRotor: false);
      expect(v.ok, isFalse);
      final msg = v.reasons.join();
      expect(msg, contains('一片葉片都沒有定位到'));
      expect(msg, contains('完整入鏡'));
      expect(msg, contains('分割'));
      expect(msg, isNot(contains('等轉子轉到')),
          reason: 'n = 0 時轉子轉不轉都一樣，不可以叫人等');
    });

    test('定位到超過三片 → 指向取景，不指向塔架', () {
      final v = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tip(100), _tip(101), _tip(102), _tip(99)],
              towerFound: true,
              hubRefined: true),
          checkSecondRotor: false);
      expect(v.ok, isFalse);
      final msg = v.reasons.join();
      expect(msg, contains('多於 3'));
      expect(msg, contains('不只一台風機'));
      expect(msg, isNot(contains('等轉子轉到')));
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
      expect(BladeStructureGate.sideViewMaxTiltDeg, 12.0);
    });

    // 側視（§13-12）：規格 §5.1 的側視模式原本會被「葉片數 ≠ 3」與「半徑離散」拒收。
    // 側視另走一組規則，但判定要嚴——恰好兩片、一上一下、都在垂直 ±12° 內、有塔架。
    // 對照 Python tests/test_quality.py 的同名情境。
    test('側視：一上一下兩片近垂直、有塔架 → 放行，不套三片規則，但明說不能互比', () {
      final st = BladeStructure(
          blades: [_tipAt(300, 270), _tipAt(150, 90)],
          towerFound: true,
          hubRefined: true);
      final v = BladeStructureGate.judge(structure: st, checkSecondRotor: false);
      expect(v.ok, isTrue, reason: v.reasons.join('；'));
      expect(v.metrics['view'], 'side');
      expect(v.metrics['hanging_blade_index'], 0);
      expect((v.metrics['tip_radius_spread'] as num).toDouble(),
          greaterThan(BladeStructureGate.maxRadiusSpread),
          reason: '離散度照記錄，只是不拿來判');
      expect(v.warnings.join(), contains('互比不適用'));
    });

    test('側視要一上一下：兩片都朝上不是側視，照正視規則拒收', () {
      final v = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tipAt(300, 90), _tipAt(150, 92)],
              towerFound: true,
              hubRefined: true),
          checkSecondRotor: false);
      expect(v.ok, isFalse);
      expect(v.metrics['view'], 'front');
      expect(v.reasons.join(), contains('六點鐘'));
    });

    test('斜視不是側視（真實照片 1573f056：6.6° 與 19.2°）', () {
      final v = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tipAt(277, 289.2), _tipAt(215.8, 83.4)],
              towerFound: true,
              hubRefined: true),
          checkSecondRotor: false);
      expect(v.ok, isFalse, reason: '斜視的垂掛葉片彎曲含透視分量，放行只會多一個假訊號來源');
      expect(v.metrics['view'], 'front');
    });

    test('側視要有塔架；單獨一根垂直的東西也不是側視', () {
      final noTower = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tipAt(300, 270), _tipAt(150, 90)],
              towerFound: false,
              hubRefined: true),
          checkSecondRotor: false);
      expect(noTower.ok, isFalse);
      final lone = BladeStructureGate.judge(
          structure: BladeStructure(
              blades: [_tipAt(300, 270)], towerFound: true, hubRefined: true),
          checkSecondRotor: false);
      expect(lone.ok, isFalse);
      expect(lone.metrics['view'], 'front');
    });

    test('側視門檻 12° 含邊界，與 Python 相同', () {
      expect(
          BladeStructureGate.detectSideView(BladeStructure(
              blades: [_tipAt(300, 282.0), _tipAt(150, 90)], towerFound: true)),
          0);
      expect(
          BladeStructureGate.detectSideView(BladeStructure(
              blades: [_tipAt(300, 282.5), _tipAt(150, 90)], towerFound: true)),
          isNull);
    });
  });

  group('側視（與 Python 的夾具對照）', () {
    late Map<String, dynamic> sideRef;
    setUpAll(() {
      sideRef = jsonDecode(
        File('test/assets/blade_side_reference.json').readAsStringSync(),
      ) as Map<String, dynamic>;
    });

    test('合成側視照：閘門判成側視放行、不互比、垂掛葉片與 Python 同一片同一個數', () {
      final bytes = File('test/assets/blade_side_scene.png').readAsBytesSync();
      final out = runGeometryPipeline(Uint8List.fromList(bytes));
      final want = sideRef['capture_verdict'] as Map<String, dynamic>;
      expect(out.ok, want['ok'] as bool, reason: out.reasons.join('；'));
      expect(out.metrics['view'], want['view']);
      expect(out.metrics['hanging_blade_index'], want['hanging_blade_index']);
      expect(out.metrics['n_blades'], sideRef['n_blades']);
      expect(out.comparisons, isEmpty, reason: '側視不做三片互比');
      expect(out.warnings.length, want['n_warnings'] as int,
          reason: out.warnings.join('；'));
      final hb = sideRef['hanging_blade'] as Map<String, dynamic>;
      expect((out.metrics['hanging_radius_px'] as num).toDouble(),
          closeTo((hb['radius_px'] as num).toDouble(), 2.0));
      expect((out.metrics['hanging_tip_deflection_px'] as num).toDouble(),
          closeTo((hb['tip_deflection_px'] as num).toDouble(), 1.0));
      expect(out.cmPerPx, isNull, reason: '沒給型錄半徑就沒有尺度');
      expect(out.metrics.containsKey('hanging_tip_deflection_cm'), isFalse);
    });

    test('★ 側視 + 型錄半徑：尺度由垂掛那片反推，與 Python 同一個數（A4）', () {
      final bytes = File('test/assets/blade_side_scene.png').readAsBytesSync();
      final rotorRadiusM = (sideRef['rotor_radius_m'] as num).toDouble();
      final out = runGeometryPipeline(Uint8List.fromList(bytes),
          rotorRadiusM: rotorRadiusM);
      expect(out.ok, isTrue, reason: out.reasons.join('；'));
      final wantCm = (sideRef['cm_per_px_estimated'] as num).toDouble();
      expect(out.cmPerPx!, closeTo(wantCm, 0.01 * wantCm),
          reason: '垂掛葉片葉長差 ≤ 2 px（上一條），尺度跟著差不到 1%');
      expect(out.metrics['cm_per_px'], out.cmPerPx);
      final hb = sideRef['hanging_blade'] as Map<String, dynamic>;
      expect((out.metrics['hanging_tip_deflection_cm'] as num).toDouble(),
          closeTo((hb['tip_deflection_cm'] as num).toDouble(), 20.0),
          reason: '1 px 的葉尖偏移容忍 × 15 cm/px');
      // 合成真值 15 cm/px：反推誤差是「垂掛葉片投影長度含預彎」那一點，記在報告裡
      final truthCm = (sideRef['cm_per_px'] as num).toDouble();
      expect(out.cmPerPx!, closeTo(truthCm, 0.03 * truthCm));
    });

    test('sideViewSummary 的形狀與 compareBlades 相容', () {
      final st = structureOf();
      final profiles = BladeGeometryCompare.profilesFromStructure(st);
      final s = BladeGeometryCompare.sideViewSummary(profiles, 0);
      expect(s.comparisons, isEmpty);
      expect(s.anyFlagged, isFalse);
      expect(s.view, 'side');
      expect(s.hangingBlade!['index'], 0);
      final json = s.toJson();
      expect(json['view'], 'side');
      expect(json['hanging_blade'], isA<Map<String, dynamic>>());
      expect(BladeGeometryCompare.compareBlades(profiles).toJson().containsKey('view'),
          isFalse,
          reason: '正視的 JSON 形狀不變');
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
      expect(out.cmPerPx, isNull);
      expect(out.metrics.containsKey('cm_per_px'), isFalse);
    });

    test('正視 + 型錄半徑：整條管線出 cm/px，與合成真值差 < 4%（A4）', () {
      final bytes = File('test/assets/blade_front_scene.png').readAsBytesSync();
      final rotorRadiusM =
          (ref['comparison']['rotor_radius_m'] as num).toDouble();
      final out = runGeometryPipeline(Uint8List.fromList(bytes),
          params: paramsOf(), rotorRadiusM: rotorRadiusM);
      expect(out.ok, isTrue, reason: out.reasons.join('；'));
      final truthCm = (ref['truth']['cm_per_px'] as num).toDouble();
      expect(out.cmPerPx!, closeTo(truthCm, 0.04 * truthCm));
      expect(out.metrics['cm_per_px'], out.cmPerPx);
      for (final c in out.comparisons) {
        expect(c.outlierDeviationCm, isNotNull, reason: c.metric);
      }
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

BladeTip _tipAt(double radius, double angleDeg) => BladeTip(
      area: 500,
      tipX: 0,
      tipY: 0,
      tipRadiusPx: radius,
      tipAngleDeg: angleDeg,
      xs: Int32List(0),
      ys: Int32List(0),
    );

BladeTip _tip(double radius) => BladeTip(
      area: 500,
      tipX: 0,
      tipY: 0,
      tipRadiusPx: radius,
      tipAngleDeg: 0,
      xs: Int32List(0),
      ys: Int32List(0),
    );

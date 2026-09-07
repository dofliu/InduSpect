import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_acoustic_service.dart';
import 'package:induspect_ai/services/blade_analysis_service.dart';
import 'package:induspect_ai/services/blade_dynamics_service.dart';
import 'package:induspect_ai/services/blade_geometry_compare.dart';
import 'package:induspect_ai/services/blade_ai_service.dart';
import 'package:induspect_ai/services/blade_surface_service.dart';

/// 葉片分析編排層的測試。
///
/// 這支測試守的是「不會靜靜給出錯答案」：沒驗過品質的照片不能被當成驗過、
/// 沒跑的層要在報告上講出來、AI 不能把量到的發現吃掉、離線不能讓結果消失。
void main() {
  final bytes = Uint8List.fromList(List<int>.filled(8, 1));

  BladeEdgeRoughness edge(String name, double rms) => BladeEdgeRoughness(
        edge: name,
        nSamples: 500,
        rmsPx: rms,
        inwardP95Px: rms * 2.5,
        pitCount: (rms * 30).round(),
        highFreqRatio: 0.4,
        zoneRmsPx: [rms, rms, rms],
        zoneTextureStd: const [3.0, 3.0, 3.0],
      );

  /// 假的表面層分析：前緣（畫面上緣）rms = [leRms]、後緣 = 1.0
  BladeSurfaceAnalyzer fakeSurface(double leRms, {String? le = 'top'}) =>
      (Uint8List b, {BladeSurfaceParams params = const BladeSurfaceParams()}) async =>
          BladeSurfaceAnalysis(
            ok: true,
            axisAngleDeg: 2.0,
            medianThicknessPx: 240,
            top: edge('top', leRms),
            bottom: edge('bottom', 1.0),
            leadingEdge: le,
          );

  BladeSurfaceAnalyzer failingSurface(String why) =>
      (Uint8List b, {BladeSurfaceParams params = const BladeSurfaceParams()}) async =>
          BladeSurfaceAnalysis.failed(why);

  BladeImageAnalyzer aiStub(Map<String, dynamic> reply) =>
      ({required String prompt, required Uint8List imageBytes}) async => reply;

  WtMedia segment(
    String path, {
    bool? passed = true,
    String? le = 'top',
    String? zone = 'mid',
    String? blade = 'A',
  }) =>
      WtMedia(
        path: path,
        view: WtMediaView.segment,
        zone: zone,
        bladePosition: blade,
        leadingEdge: le,
        zoom: 5,
        qualityJson: passed == null ? {} : {'ok': passed},
      );

  WtCaptureSession session(List<WtMedia> media) =>
      WtCaptureSession(sessionId: 'sess-1', assetId: 'WTG-07', media: media);

  /// 假的幾何層：閘門放行、四個量都不標記（健康那台）
  BladeGeometryAnalyzer fakeGeometry({
    bool ok = true,
    List<String> reasons = const [],
    List<MetricComparison> comparisons = const [],
  }) =>
      (Uint8List b) async => BladeGeometryOutcome(
            ok: ok,
            reasons: reasons,
            metrics: const {'n_blades': 3},
            comparisons: comparisons,
          );

  BladeProfile _profile(int index, double axisDeg, double radius) => BladeProfile(
        index: index,
        axisAngleDeg: axisDeg,
        radiusPx: radius,
        u: Float64List(4),
        center: Float64List(4),
        edgeLo: Float64List(4),
        edgeHi: Float64List(4),
        width: Float64List(4),
        bendCoeff: 0.0,
        tipDeflectionPx: 0.0,
        residualRmsPx: 0.0,
        meanWidthPx: 10.0,
        tipX: 0.0,
        tipY: 0.0,
        nContaminatedBins: 0,
      );

  /// 正下方（六點鐘）的那一片
  BladeProfile downProfile(double radius) => _profile(0, 270.0, radius);

  /// 不在正下方的其他兩片
  BladeProfile sideProfile(int index, double axisDeg) =>
      _profile(index, axisDeg, 300.0);

  MetricComparison flagged(String metric, int index, double dev) =>
      MetricComparison(
        metric: metric,
        values: const [0.0, 0.0, 20.0],
        deviations: const [0.0, 0.0, 20.0],
        outlierIndex: index,
        outlierDeviation: dev,
        othersSpread: 0.2,
        z: 13.0,
        flagged: true,
      );

  Future<BladeAnalysisOutcome> run(
    List<WtMedia> media, {
    BladeSurfaceAnalyzer? surface,
    BladeImageAnalyzer? ai,
    BladeGeometryAnalyzer? geometry,
    BladeAcousticAnalyzer? acoustic,
    BladeFrameExtractor? frameExtractor,
    bool useAi = false,
  }) =>
      BladeAnalysisService.analyzeSession(
        session: session(media),
        useAi: useAi,
        loadBytes: (_) async => bytes,
        surface: surface ?? fakeSurface(1.0),
        analyzer: ai,
        geometry: geometry ?? fakeGeometry(),
        acoustic: acoustic,
        frameExtractor: frameExtractor,
      );

  /// 假的聲學結果。只填測試會看的欄位，其餘給 NaN——真實情況下不可用時
  /// 那些欄位本來就是 NaN。
  BladeAcousticResult acousticResult({
    required bool usable,
    double rpm = double.nan,
    double bladePassHz = double.nan,
    double durationS = 8.0,
    List<double> passTimes = const [],
    List<double>? levels,
    int? whistleAt,
    List<String> notes = const [],
  }) {
    final lv = levels ?? const [double.nan, double.nan, double.nan];
    return BladeAcousticResult(
      sampleRate: 16000,
      durationS: durationS,
      bladePassHz: bladePassHz,
      rotorHz: double.nan,
      rpmFromAudio: rpm,
      periodicityConfidence: usable ? 0.8 : 0.0,
      amDepthDb: double.nan,
      asymmetryDb: double.nan,
      windDominance: 0.5,
      envelopeSnrDb: 6.0,
      usable: usable,
      passTimesS: passTimes,
      notes: notes,
      blades: usable
          ? List<BladeAcousticBlade>.generate(
              3,
              (i) => BladeAcousticBlade(
                    index: i,
                    nPasses: 2,
                    bandLevelDb: lv[i],
                    highBandRatio: 0.6,
                    tonalFreqHz: whistleAt == i ? 1800.0 : double.nan,
                    tonalProminenceDb: whistleAt == i ? 11.0 : double.nan,
                    tonalExclusive: whistleAt == i,
                  ))
          : const [],
      comparisons: usable
          ? [
              BladeGeometryCompare.compareMetric('band_level_db', lv, 0.8,
                  direction: MetricDirection.high)
            ]
          : const [],
    );
  }

  group('門檻表', () {
    test('與原型的 5.0 / 2.0 / 1.5 一致，邊界含等於', () {
      expect(BladeSurfaceTriage.severityFor(5.0), 5);
      expect(BladeSurfaceTriage.severityFor(4.99), 4);
      expect(BladeSurfaceTriage.severityFor(2.0), 4);
      expect(BladeSurfaceTriage.severityFor(1.99), 2);
      expect(BladeSurfaceTriage.severityFor(1.5), 2);
      expect(BladeSurfaceTriage.severityFor(1.49), isNull);
      expect(BladeSurfaceTriage.severityFor(0.93), isNull);
    });

    test('沒有比值或算出 NaN 時不給等級，也不當成正常', () {
      expect(BladeSurfaceTriage.severityFor(null), isNull);
      expect(BladeSurfaceTriage.severityFor(double.nan), isNull);
      expect(BladeSurfaceTriage.verdictText(null), contains('無法計算'),
          reason: '算不出比值時說「前後緣相當」是一句沒有依據的話');
      expect(BladeSurfaceTriage.verdictText(double.nan), contains('無法計算'));
      expect(BladeSurfaceTriage.verdictText(1.0), contains('本次未見'));
      expect(BladeSurfaceTriage.verdictText(1.0), isNot(contains('合格')));
    });
  });

  group('哪些照片會被分析', () {
    test('沒驗過品質的照片不分析——null 不等於通過', () async {
      final out = await run([segment('a.jpg', passed: null)]);
      expect(out.analyzedCount, 0);
      expect(out.detections, isEmpty);
      expect(out.notes.join(), contains('未通過拍攝品質閘門'));
      expect(out.notes.join(), contains('不是判定為正常'),
          reason: '「沒分析」與「分析後正常」在報告上必須分得開');
    });

    test('品質閘門擋掉的照片不分析', () async {
      final out = await run([segment('a.jpg', passed: false)]);
      expect(out.analyzedCount, 0);
      expect(out.skippedCount, 1);
    });

    test('沒接上抽幀時，影片明寫「裝置端抽幀尚未接上」而不是「未實作」', () async {
      final out = await run([
        WtMedia(path: 'front.jpg', view: WtMediaView.front, qualityJson: const {'ok': true}),
        WtMedia(path: 'clip.mp4', kind: WtMediaKind.video, view: WtMediaView.front),
        segment('seg.jpg'),
      ]);
      expect(out.analyzedCount, 2, reason: '分區段照 1 張 + 整機照 1 張');
      expect(out.layersRun, {WtLayer.surface, WtLayer.geometry});
      final summary = out.buildSummary();
      expect(summary, contains('幾何層'));
      expect(summary, contains('動態層'));
      expect(summary, contains('未進行'), reason: '動態層要明寫沒跑');
      expect(summary, contains('抽幀'),
          reason: '「沒拍」與「拍了但解不了」對現場是兩件不同的事');
    });

    test('動態層：音軌可用時產生逐片發現，並把轉速寫進備註', () async {
      final out = await run(
        [WtMedia(path: 'rec.wav', kind: WtMediaKind.audio)],
        acoustic: (_) async => acousticResult(
          usable: true,
          rpm: 12.4,
          levels: const [0.0, 4.0, 0.2],
        ),
      );
      expect(out.layersRun, contains(WtLayer.dynamic_));
      expect(out.analyzedCount, 1);
      final d = out.detections
          .where((x) => x.defectClass == 'blade_noise')
          .toList();
      expect(d.length, 1);
      expect(d.first.blade, 'B', reason: 'index 1 → 葉片 B');
      expect(d.first.layer, WtLayer.dynamic_);
      expect(d.first.severity, 2, reason: '警告級，不給不合格');
      expect(d.first.metricJson['rpm_from_audio'], 12.4);
      expect(out.notes.join(), contains('12.4 rpm'));
      // 這個場次只有音軌，所以表面層與幾何層**確實**沒跑——摘要照實說是對的。
      // （先前這裡斷言不出現「未進行」，那是我把「動態層跑了」錯當成「全都跑了」。）
      expect(out.buildSummary(), startsWith('本次分析範圍：動態層'));
      expect(out.buildSummary(), contains('表面層'));
      expect(out.buildSummary(), contains('未進行'));
      expect(out.buildSummary(), contains('沒進行不等於沒問題'));
    });

    test('動態層：音軌不可用時也留一筆（無 severity），不會被讀成「聲音沒問題」',
        () async {
      final out = await run(
        [WtMedia(path: 'rec.wav', kind: WtMediaKind.audio)],
        acoustic: (_) async => acousticResult(
            usable: false, notes: const ['風噪主導，建議站到下風處並加防風罩重錄']),
      );
      expect(out.layersRun, isNot(contains(WtLayer.dynamic_)));
      expect(out.skippedCount, 1);
      final d = out.detections.single;
      expect(d.defectClass, 'audio_unusable');
      expect(d.severity, isNull, reason: '無 severity → 不進報告的發現列表');
      expect(d.aiDescription, contains('防風罩'));
      expect(out.reportable, isEmpty);
    });

    test('動態層：三片一致時不產生發現，但要說「比過了」', () async {
      final out = await run(
        [WtMedia(path: 'rec.wav', kind: WtMediaKind.audio)],
        acoustic: (_) async =>
            acousticResult(usable: true, levels: const [0.0, 0.1, 0.2]),
      );
      expect(out.detections, isEmpty);
      expect(out.notes.join(), contains('未見單片噪音異常'));
    });

    test('動態層：獨有哨音各自一筆，且 detectionId 不互相覆蓋', () async {
      final out = await run(
        [WtMedia(path: 'rec.wav', kind: WtMediaKind.audio)],
        acoustic: (_) async => acousticResult(
          usable: true,
          levels: const [0.0, 4.0, 0.2],
          whistleAt: 1,
        ),
      );
      final ids = out.detections.map((d) => d.detectionId).toSet();
      expect(ids.length, out.detections.length, reason: 'id 不能重複');
      expect(
          out.detections.where((d) => d.defectClass == 'blade_whistle').length,
          1);
    });

    test('影片：有抽幀但沒有可用音軌 → 不知道週期，明講沒跑', () async {
      final out = await run(
        [WtMedia(path: 'clip.mp4', kind: WtMediaKind.video)],
        frameExtractor: (_, __) async => bytes,
      );
      expect(out.layersRun, isNot(contains(WtLayer.dynamic_)));
      expect(out.notes.join(), contains('葉片通過週期'));
    });

    test('影片：音軌先跑並把週期交給抽幀，動態層才成立', () async {
      final asked = <double>[];
      final out = await run(
        [
          WtMedia(path: 'rec.wav', kind: WtMediaKind.audio),
          WtMedia(path: 'clip.mp4', kind: WtMediaKind.video),
        ],
        acoustic: (_) async => acousticResult(
          usable: true,
          rpm: 24.0,
          bladePassHz: 1.2,
          durationS: 6.0,
          passTimes: const [0.35],
          levels: const [0.0, 0.1, 0.2],
        ),
        frameExtractor: (path, at) async {
          asked.add(at);
          return bytes;
        },
      );
      expect(asked, isNotEmpty, reason: '抽幀時刻要由音軌的週期決定');
      expect(asked.first, closeTo(0.35, 1e-9));
      // 1.2 Hz → 週期 0.833 s，6 秒內共 7 次通過
      expect(asked.length, 7);
      expect(out.layersRun, contains(WtLayer.dynamic_),
          reason: '音軌那一半成立了');
      // 這個假的幾何層不回輪廓，所以影片那一半量不到朝下的葉片——
      // 而它必須把「為什麼量不到」講出來，不能靜靜跳過
      expect(out.notes.join(), contains('朝下的葉片'));
    });

    test('影片：音軌給週期、幾何層給輪廓時，整條鏈產生葉尖半徑發現', () async {
      // 三片輪流通過六點鐘，第 2 順位短 40 px
      final radii = [300.0, 260.0, 300.0, 301.0, 261.0, 299.0];
      var call = 0;
      final out = await run(
        [
          WtMedia(path: 'rec.wav', kind: WtMediaKind.audio),
          WtMedia(path: 'clip.mp4', kind: WtMediaKind.video),
        ],
        acoustic: (_) async => acousticResult(
          usable: true,
          rpm: 24.0,
          bladePassHz: 1.2,
          durationS: 5.2,
          passTimes: const [0.1],
          levels: const [0.0, 0.1, 0.2],
        ),
        frameExtractor: (_, __) async => bytes,
        geometry: (_) async {
          final r = radii[call % radii.length];
          call++;
          return BladeGeometryOutcome(ok: true, profiles: [
            downProfile(r),
            sideProfile(1, 30.0),
            sideProfile(2, 150.0),
          ]);
        },
      );
      final d = out.detections
          .where((x) => x.defectClass == 'tip_radius_mismatch')
          .toList();
      expect(d.length, 1);
      expect(d.first.layer, WtLayer.dynamic_);
      expect(d.first.blade, 'B', reason: '第 2 順位');
      expect(d.first.severity, 2);
      expect(d.first.metricJson['frames_measured'], 7);
      expect(out.notes.join(), contains('聲音層'),
          reason: '兩層的葉片標籤規則要在報告上對得起來');
    });

    test('沒過品質閘門的整機照不進幾何層', () async {
      var called = 0;
      await run(
        [WtMedia(path: 'front.jpg', view: WtMediaView.front)],
        geometry: (b) async {
          called++;
          return const BladeGeometryOutcome(ok: true);
        },
      );
      expect(called, 0, reason: '`qualityOk` 是 null（沒驗過），不能當成驗過了');
    });

    test('讀不到檔案時留下紀錄，不靜靜跳過', () async {
      final out = await BladeAnalysisService.analyzeSession(
        session: session([segment('gone.jpg')]),
        useAi: false,
        loadBytes: (_) async => throw Exception('no file'),
        surface: fakeSurface(1.0),
      );
      expect(out.notes.join(), contains('讀不到檔案'));
      expect(out.analyzedCount, 0);
    });

    test('分割失敗時把原因寫進摘要', () async {
      final out = await run([segment('a.jpg')],
          surface: failingSurface('可用的邊緣樣本太少（葉片被截斷或分割失敗）'));
      expect(out.notes.join(), contains('邊緣樣本太少'));
      expect(out.detections, isEmpty);
    });
  });

  group('未超門檻的結果', () {
    test('存進資料庫供下次比對，但不進報告', () async {
      final out = await run([segment('a.jpg')], surface: fakeSurface(0.93));
      expect(out.detections, hasLength(1));
      expect(out.detections.single.severity, isNull);
      expect(out.detections.single.defectClass, 'none');
      expect(out.detections.single.metricJson['le_over_te_rms_ratio'],
          closeTo(0.93, 1e-9));
      expect(out.reportable, isEmpty,
          reason: '把「未超門檻」印成一列「待判定」會讓報告看起來有懸而未決的事項');
    });

    test('量到的比值出現在摘要裡，數字不會消失', () async {
      final out = await run([segment('a.jpg')], surface: fakeSurface(0.93));
      expect(out.buildSummary(), contains('0.93'));
    });

    test('未超門檻不送 AI', () async {
      var called = 0;
      await run(
        [segment('a.jpg')],
        surface: fakeSurface(1.0),
        useAi: true,
        ai: ({required String prompt, required Uint8List imageBytes}) async {
          called++;
          return {'defect_class': 'leading_edge_erosion', 'severity': 5};
        },
      );
      expect(called, 0);
    });
  });

  group('超過門檻的結果', () {
    test('演算法的等級與判定文字都留著（不送 AI 時）', () async {
      final out = await run([segment('a.jpg')], surface: fakeSurface(5.2));
      final d = out.detections.single;
      expect(d.severity, 5);
      expect(d.defectClass, 'leading_edge_erosion');
      expect(d.aiDescription, contains('重度侵蝕'),
          reason: '離線時報告上不能只有一個等級數字');
      expect(d.source, WtDetectionSource.geminiOfflinePending);
      expect(out.hasPendingAi, isTrue);
      expect(out.reportable, hasLength(1));
    });

    test('AI 失敗時演算法結果不消失，改標為待補', () async {
      final out = await run(
        [segment('a.jpg')],
        surface: fakeSurface(2.4),
        useAi: true,
        ai: ({required String prompt, required Uint8List imageBytes}) =>
            Future<Map<String, dynamic>>.error(Exception('離線')),
      );
      final d = out.detections.single;
      expect(d.severity, 4);
      expect(d.source, WtDetectionSource.geminiOfflinePending);
      expect(d.metricJson['pit_count'], isNotNull);
    });

    test('AI 說是正常結構時不刪掉這筆發現，把理由記下來', () async {
      final out = await run(
        [segment('a.jpg')],
        surface: fakeSurface(2.4),
        useAi: true,
        ai: aiStub({
          'defect_class': 'none',
          'severity': 1,
          'description': '看起來是合模線',
          'normal_structure_ruled_out': '不適用',
        }),
      );
      final d = out.detections.single;
      expect(d.severity, 4, reason: '演算法量到的等級是下限，AI 不能往下砍');
      expect(d.defectClass, 'leading_edge_erosion',
          reason: 'AI 說 none 時保留演算法的分類，不要讓一筆發現變成未分類');
      expect(d.aiDescription, contains('AI 認為這可能不是缺陷'));
      expect(d.aiDescription, contains('仍列為待人工確認'));
      expect(out.reportable, hasLength(1));
    });

    test('AI 看到更嚴重的東西時可以把等級拉高', () async {
      final out = await run(
        [segment('a.jpg')],
        surface: fakeSurface(1.6), // 演算法只到 severity 2
        useAi: true,
        ai: aiStub({
          'defect_class': 'lightning_damage',
          'severity': 5,
          'confidence': 0.8,
          'description': '葉尖有燒黑破口',
        }),
      );
      final d = out.detections.single;
      expect(d.severity, 5);
      expect(d.defectClass, 'lightning_damage');
      expect(d.confidence, 0.8);
      expect(d.metricJson['le_over_te_rms_ratio'], isNotNull,
          reason: '演算法的數值要跟著 AI 的判斷一起留下來');
    });

    test('所有結果都是待人工確認', () async {
      final out = await run([segment('a.jpg')], surface: fakeSurface(5.2));
      expect(out.detections.single.humanStatus, WtHumanStatus.pending);
      expect(out.detections.single.needsConfirmation, isTrue);
    });
  });

  group('幾何層（整機照）', () {
    test('閘門拒收也產生一筆偵測——現場要知道「這張不能用」', () async {
      final out = await run(
        [WtMedia(path: 'front.jpg', view: WtMediaView.front, qualityJson: const {'ok': true})],
        geometry: fakeGeometry(
            ok: false, reasons: const ['三片葉尖半徑差 37%：請重拍']),
      );
      final d = out.detections.single;
      expect(d.layer, WtLayer.geometry);
      expect(d.defectClass, 'capture_quality');
      expect(d.severity, isNull, reason: '拒收不是缺陷等級，是「量不到」');
      expect(d.aiDescription, contains('請重拍'));
      expect(out.reportable, isEmpty, reason: '沒有 severity 就不進報告列表');
      expect(out.buildSummary(), contains('請重拍'));
    });

    test('互比標記 → 一筆警告級發現，指對是哪一片', () async {
      final out = await run(
        [WtMedia(path: 'front.jpg', view: WtMediaView.front, qualityJson: const {'ok': true})],
        geometry: fakeGeometry(
            comparisons: [flagged('tip_deflection_px', 2, 20.0)]),
      );
      final d = out.detections.single;
      expect(d.layer, WtLayer.geometry);
      expect(d.defectClass, 'tip_deflection');
      expect(d.blade, 'C', reason: 'outlierIndex 2 → 第三片');
      expect(d.severity, 2,
          reason: '三片互比只給警告：不一樣的原因可能是雲遮住一段，'
              '要升級成不合格得靠近距離複檢');
      expect(d.metricJson['tip_deflection_px'], 20.0);
      expect(d.aiDescription, contains('葉尖偏移'));
      expect(out.reportable, hasLength(1));
    });

    test('互比沒有離群時不產生發現，但摘要要說「量過了」', () async {
      final out = await run(
        [WtMedia(path: 'front.jpg', view: WtMediaView.front, qualityJson: const {'ok': true})],
        geometry: fakeGeometry(comparisons: const []),
      );
      expect(out.detections, isEmpty);
      expect(out.buildSummary(), contains('未見離群'));
    });

    test('多個量同時標記 → 每個量各一筆', () async {
      final out = await run(
        [WtMedia(path: 'front.jpg', view: WtMediaView.front, qualityJson: const {'ok': true})],
        geometry: fakeGeometry(comparisons: [
          flagged('tip_deflection_px', 0, 20.0),
          flagged('radius_px', 1, -15.0),
        ]),
      );
      expect(out.detections, hasLength(2));
      expect(out.detections.map((d) => d.defectClass).toSet(),
          {'tip_deflection', 'blade_mismatch'});
      expect(out.detections.map((d) => d.detectionId).toSet(), hasLength(2),
          reason: 'detectionId 要含量名，否則兩筆會互相覆蓋');
    });

    test('側視照也走幾何層', () async {
      final out = await run(
        [WtMedia(path: 'side.jpg', view: WtMediaView.side, qualityJson: const {'ok': true})],
        geometry: fakeGeometry(comparisons: [flagged('radius_px', 0, 9.0)]),
      );
      expect(out.analyzedCount, 1);
      expect(out.detections.single.layer, WtLayer.geometry);
    });
  });

  test('沒指定前緣在哪一側時講明限制', () async {
    final out = await run([segment('a.jpg', le: null)],
        surface: fakeSurface(5.0, le: null));
    expect(out.analyzedCount, 1);
    expect(out.notes.join(), contains('未指定前緣'));
    expect(out.detections.single.severity, isNull,
        reason: '沒有前後緣比就沒有判據，不能憑絕對粗糙度下等級');
    expect(out.notes.join(), isNot(contains('前後緣粗糙度相當')),
        reason: '沒算到比值就不能說前後緣相當');
  });

  test('同一張照片重跑會得到同一個 detectionId（覆蓋而不是重複）', () async {
    final a = await run([segment('a.jpg')], surface: fakeSurface(5.2));
    final b = await run([segment('a.jpg')], surface: fakeSurface(5.2));
    expect(a.detections.single.detectionId, b.detections.single.detectionId);
  });

  test('摘要一定講明只跑了表面層', () async {
    final out = await run([segment('a.jpg')], surface: fakeSurface(1.0));
    final s = out.buildSummary();
    expect(s, contains('表面層'));
    expect(s, contains('幾何層'));
    expect(s, contains('未進行'));
    expect(s, isNot(contains('合格')));
  });
}

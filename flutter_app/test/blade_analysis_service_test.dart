import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_analysis_service.dart';
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

  Future<BladeAnalysisOutcome> run(
    List<WtMedia> media, {
    BladeSurfaceAnalyzer? surface,
    BladeImageAnalyzer? ai,
    bool useAi = false,
  }) =>
      BladeAnalysisService.analyzeSession(
        session: session(media),
        useAi: useAi,
        loadBytes: (_) async => bytes,
        surface: surface ?? fakeSurface(1.0),
        analyzer: ai,
      );

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

    test('整機照與影片保存但不分析，且在摘要裡講明', () async {
      final out = await run([
        WtMedia(path: 'front.jpg', view: WtMediaView.front, qualityJson: const {'ok': true}),
        WtMedia(path: 'clip.mp4', kind: WtMediaKind.video, view: WtMediaView.front),
        segment('seg.jpg'),
      ]);
      expect(out.analyzedCount, 1);
      final summary = out.buildSummary();
      expect(summary, contains('整轉子幾何分析尚未在 App 端實作'));
      expect(summary, contains('動態層分析尚未在 App 端實作'));
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

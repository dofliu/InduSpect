import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_asset.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_report_builder.dart';

/// 葉片報告的**安全語意**測試。
///
/// 這支測試守的不是排版，是立場：篩檢報告不下合格判定、沒檢出要講清楚代表什麼、
/// 演算法的數字要看得到、人工駁回的不列入。這些是規格 §11 的交付條件。
void main() {
  final asset = WtAsset(
    assetId: 'WTG-07',
    siteName: '彰濱風場',
    rotorDiameterM: 150,
  );

  WtCaptureSession session({List<WtMedia>? media, String title = ''}) =>
      WtCaptureSession(
        sessionId: 'sess-1',
        assetId: 'WTG-07',
        title: title,
        capturedAt: DateTime(2026, 9, 20, 9, 40),
        latitude: 24.1,
        longitude: 120.4,
        media: media ??
            [
              WtMedia(path: '/tmp/seg_a_mid.jpg', view: WtMediaView.segment),
              WtMedia(path: '/tmp/front.jpg', view: WtMediaView.front),
            ],
      );

  WtDetection erosion({
    int? severity = 4,
    WtHumanStatus human = WtHumanStatus.pending,
    String id = 'det-1',
  }) =>
      WtDetection(
        detectionId: id,
        sessionId: 'sess-1',
        layer: WtLayer.surface,
        blade: 'A',
        zone: 'mid_LE',
        defectClass: 'leading_edge_erosion',
        severity: severity,
        confidence: 0.71,
        metricJson: const {
          'le_over_te_rms_ratio': 5.2,
          'inward_p95_px': 1.52,
          'pit_count': 23,
        },
        mediaPath: '/tmp/seg_a_mid.jpg',
        humanStatus: human,
        aiDescription: '前緣塗層剝落，露出底層複材',
      );

  test('報告不出現「合格」——這是篩檢，不是驗收', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: [erosion()],
    );
    for (final item in data.items) {
      expect(BladeReportBuilder.allowedVerdicts, contains(item.verdict),
          reason: '${item.label} 的 verdict 是 ${item.verdict}');
    }
    expect(data.summaryReport, isNot(contains('合格')));
  });

  test('零檢出不留白，也不暗示沒問題', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: const [],
    );
    expect(data.items, isEmpty);
    expect(data.summaryReport, contains('未檢出超出門檻的異常'));
    expect(data.summaryReport, contains('這不等於葉片沒有問題'));
    expect(data.summaryReport, contains('無法取代無人機定檢'));
    // 沒有發現時，拍到的照片照樣要附進報告
    expect(data.extraPhotoPaths, containsAll(['/tmp/seg_a_mid.jpg', '/tmp/front.jpg']));
  });

  test('severity 對應 verdict，缺 severity 一律待判定', () {
    expect(BladeReportBuilder.verdictOf(erosion(severity: 5)), '不合格');
    expect(BladeReportBuilder.verdictOf(erosion(severity: 4)), '不合格');
    expect(BladeReportBuilder.verdictOf(erosion(severity: 3)), '警告');
    expect(BladeReportBuilder.verdictOf(erosion(severity: 2)), '警告');
    expect(BladeReportBuilder.verdictOf(erosion(severity: 1)), '待判定');
    expect(BladeReportBuilder.verdictOf(erosion(severity: null)), '待判定');
  });

  test('演算法算的數字要出現在報告上，不能只留一個等級', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: [erosion()],
    );
    final item = data.items.single;
    expect(item.value, contains('前緣/後緣粗糙度比 5.20'));
    expect(item.value, contains('往內凹 p95 1.52 px'));
    expect(item.value, contains('凹坑 23 處'));
    expect(item.value, contains('信賴度 71%'));
    // 判定依據寫的是演算法判據，不是法規——葉片檢測沒有對應法規門檻
    expect(item.standardBasis, contains('前緣與後緣互比'));
    expect(item.standardBasis, isNot(contains('規則')));
    expect(item.anomalyDescription, '前緣塗層剝落，露出底層複材');
  });

  test('幾何層的 cm 值有產生端也有顯示端：葉尖偏移／葉片長度差／尺度（A4）', () {
    final d = WtDetection(
      detectionId: 'geo-1',
      sessionId: 'S1',
      layer: WtLayer.geometry,
      blade: 'C',
      defectClass: 'tip_deflection',
      severity: 2,
      metricJson: const {
        'tip_deflection_px': 20.0,
        'tip_deflection_cm': 226.4,
        'radius_px_deviation_cm': -275.2,
        'cm_per_px': 11.32,
      },
    );
    final v = BladeReportBuilder.valueOf(d)!;
    expect(v, contains('葉尖偏移 20.0 px'));
    expect(v, contains('葉尖偏移 226 cm'));
    expect(v, contains('葉片長度差 -275 cm'));
    expect(v, contains('尺度 11.32 cm/px'), reason: 'cm 是怎麼換的要印出來');
    // 沒尺度時一個 cm 都不出現
    final noScale = WtDetection(
      detectionId: 'geo-2',
      sessionId: 'S1',
      layer: WtLayer.geometry,
      defectClass: 'tip_deflection',
      severity: 2,
      metricJson: const {'tip_deflection_px': 20.0},
    );
    expect(BladeReportBuilder.valueOf(noScale), isNot(contains('cm')));
  });

  test('標題與圖層標示：一眼看出哪一片、哪一段、哪一層', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: [erosion()],
    );
    expect(data.items.single.label, '表面層｜葉片 A · 中段前緣 · 前緣侵蝕');
    expect(data.title, 'WTG-07 葉片檢測 2026-09-20');
    expect(data.locationName, '彰濱風場');
    expect(data.recordId, 'sess-1');
  });

  group('本次作業 metadata（規格 §10.2）寫進摘要開頭', () {
    WtCaptureSession meta({
      WtTurbineState state = WtTurbineState.unknown,
      String? weather,
      String? inspector,
    }) =>
        WtCaptureSession(
          sessionId: 'sess-1',
          assetId: 'WTG-07',
          capturedAt: DateTime(2026, 9, 20, 9, 40),
          turbineState: state,
          weatherNote: weather,
          inspector: inspector,
          media: [],
        );

    test('風機狀態的標籤：unknown 是「未記錄」不是「不知道」', () {
      expect(BladeReportBuilder.turbineStateLabel(WtTurbineState.stopped), '停機');
      expect(BladeReportBuilder.turbineStateLabel(WtTurbineState.idling), '怠速');
      expect(BladeReportBuilder.turbineStateLabel(WtTurbineState.running), '運轉');
      expect(BladeReportBuilder.turbineStateLabel(WtTurbineState.unknown), '未記錄');
    });

    test('三個都沒填 → null，不印一行空的', () {
      expect(BladeReportBuilder.sessionMetaLine(meta()), isNull);
      expect(BladeReportBuilder.sessionMetaLine(meta(weather: '  ', inspector: '')), isNull,
          reason: '空白等於沒填');
    });

    test('填了什麼就寫什麼，unknown 的風機狀態不寫', () {
      expect(BladeReportBuilder.sessionMetaLine(meta(state: WtTurbineState.stopped)),
          '風機狀態：停機');
      expect(
        BladeReportBuilder.sessionMetaLine(
            meta(state: WtTurbineState.running, weather: '多雲 陣風 8 m/s', inspector: '王小明')),
        '風機狀態：運轉｜天氣：多雲 陣風 8 m/s｜檢測人員：王小明',
      );
      expect(BladeReportBuilder.sessionMetaLine(meta(weather: '晴')), '天氣：晴');
    });

    test('★ buildData 把它放在摘要最前面；沒填時摘要不變', () {
      final withMeta = BladeReportBuilder.buildData(
        asset: asset,
        session: meta(state: WtTurbineState.stopped, weather: '晴'),
        detections: const [],
      );
      expect(withMeta.summaryReport, startsWith('風機狀態：停機｜天氣：晴'));
      expect(withMeta.summaryReport, contains('未檢出超出門檻的異常'));
      expect(withMeta.summaryReport, isNot(contains('合格')));

      final without = BladeReportBuilder.buildData(
        asset: asset,
        session: meta(),
        detections: const [],
      );
      expect(without.summaryReport, startsWith('本次未檢出超出門檻的異常'));
      expect(without.summaryReport, isNot(contains('風機狀態')));
    });
  });

  test('人工駁回的發現不列入報告，但照片仍附上', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: [erosion(human: WtHumanStatus.rejected)],
    );
    expect(data.items, isEmpty, reason: '駁回 = 人工判斷不是缺陷，不該留在報告裡');
    expect(data.summaryReport, contains('未檢出超出門檻的異常'));
    expect(data.extraPhotoPaths, contains('/tmp/seg_a_mid.jpg'));
  });

  test('已被引用的照片不重複列進附件', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: [erosion()],
    );
    expect(data.items.single.photoPath, '/tmp/seg_a_mid.jpg');
    expect(data.extraPhotoPaths, isNot(contains('/tmp/seg_a_mid.jpg')));
    expect(data.extraPhotoPaths, contains('/tmp/front.jpg'));
  });

  test('自訂標題優先於自動產生的標題', () {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(title: '颱風後複檢 WTG-07'),
      detections: [erosion()],
    );
    expect(data.title, '颱風後複檢 WTG-07');
  });

  test('未知的缺陷類別與 zone 照樣顯示原始值，不吞掉資訊', () {
    final d = WtDetection(
      detectionId: 'det-x',
      sessionId: 'sess-1',
      layer: WtLayer.periphery,
      zone: 'tower_base',
      defectClass: 'something_new',
      severity: 2,
    );
    expect(BladeReportBuilder.labelOf(d), 'tower_base · something_new');
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session(),
      detections: [d],
    );
    expect(data.items.single.label, contains('周邊'));
    expect(data.items.single.verdict, '警告');
  });
}

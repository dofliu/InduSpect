import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_trend_service.dart';

/// 跨次趨勢的測試。
///
/// 守的是「不無中生有」：一個點沒有趨勢、px 值不可跨次比、駁回的點不能從線上消失、
/// 而「比值下降」不可以被說成好轉。
void main() {
  WtCaptureSession session(String id, String day) => WtCaptureSession(
        sessionId: id,
        assetId: 'WTG-07',
        capturedAt: DateTime.parse('2026-0$day'),
      );

  WtDetection det(
    String sessionId, {
    String? blade = 'A',
    String? zone = 'mid_LE',
    double? ratio,
    double? rms,
    int? severity,
    WtHumanStatus human = WtHumanStatus.pending,
    WtLayer layer = WtLayer.surface,
  }) =>
      WtDetection(
        detectionId: 'd-$sessionId-$blade-$zone',
        sessionId: sessionId,
        layer: layer,
        blade: blade,
        zone: zone,
        severity: severity,
        humanStatus: human,
        metricJson: {
          if (ratio != null) 'le_over_te_rms_ratio': ratio,
          if (rms != null) 'rms_px': rms,
        },
      );

  final s1 = session('s1', '1-05');
  final s2 = session('s2', '4-05');
  final s3 = session('s3', '7-05');

  group('序列組裝', () {
    test('依時間排序，與輸入順序無關', () {
      final series = BladeTrendService.build(
        detections: [
          det('s3', ratio: 2.4),
          det('s1', ratio: 0.9),
          det('s2', ratio: 1.6),
        ],
        sessions: [s2, s3, s1],
      );
      expect(series, hasLength(1));
      expect(series.single.points.map((p) => p.ratio).toList(),
          [0.9, 1.6, 2.4]);
    });

    test('不同葉片／區段分成不同序列', () {
      final series = BladeTrendService.build(
        detections: [
          det('s1', blade: 'A', zone: 'mid_LE', ratio: 1.0),
          det('s1', blade: 'B', zone: 'mid_LE', ratio: 1.1),
          det('s1', blade: 'A', zone: 'tip_LE', ratio: 1.2),
        ],
        sessions: [s1],
      );
      expect(series.map((s) => s.key).toSet(),
          {'A/mid_LE', 'B/mid_LE', 'A/tip_LE'});
    });

    test('只取指定的層', () {
      final series = BladeTrendService.build(
        detections: [
          det('s1', ratio: 1.0),
          det('s1', zone: 'geo', ratio: 9.0, layer: WtLayer.geometry),
        ],
        sessions: [s1],
      );
      expect(series, hasLength(1));
      expect(series.single.zone, 'mid_LE');
    });

    test('找不到拍攝時間的偵測排不進時間軸，直接略過', () {
      final series = BladeTrendService.build(
        detections: [det('s1', ratio: 1.0), det('unknown', ratio: 5.0)],
        sessions: [s1],
      );
      expect(series.single.points, hasLength(1));
    });

    test('惡化幅度大的排前面，單點的排最後', () {
      final series = BladeTrendService.build(
        detections: [
          det('s1', blade: 'A', ratio: 1.0),
          det('s2', blade: 'A', ratio: 1.2),
          det('s1', blade: 'B', ratio: 1.0),
          det('s2', blade: 'B', ratio: 3.0),
          det('s1', blade: 'C', ratio: 1.0),
        ],
        sessions: [s1, s2],
      );
      expect(series.map((s) => s.blade).toList(), ['B', 'A', 'C']);
    });
  });

  group('delta 與 maxStep', () {
    test('只有一個有比值的點時 delta 為 null，不回 0', () {
      final series = BladeTrendService.build(
        detections: [det('s1', ratio: 1.0), det('s2')],
        sessions: [s1, s2],
      );
      expect(series.single.withRatio, hasLength(1));
      expect(series.single.delta, isNull,
          reason: '回 0 會在畫面上顯示「持平」，那是無中生有');
      expect(series.single.maxStep, isNull);
    });

    test('delta 取頭尾，maxStep 取相鄰最大跳升', () {
      final series = BladeTrendService.build(
        detections: [
          det('s1', ratio: 1.0),
          det('s2', ratio: 3.0),
          det('s3', ratio: 3.2),
        ],
        sessions: [s1, s2, s3],
      );
      expect(series.single.delta, closeTo(2.2, 1e-9));
      expect(series.single.maxStep, closeTo(2.0, 1e-9),
          reason: '單調惡化與「一次衝高」在報告上意義不同');
    });
  });

  group('describe', () {
    BladeTrendSeries build(List<double?> ratios) => BladeTrendService.build(
          detections: [
            for (var i = 0; i < ratios.length; i++)
              det(['s1', 's2', 's3'][i], ratio: ratios[i]),
          ],
          sessions: [s1, s2, s3],
        ).single;

    test('沒有比值時明說沒有可比對的值', () {
      expect(BladeTrendService.describe(build([null])), contains('沒有可比對'));
    });

    test('只有一次量測時說「還看不出趨勢」', () {
      final t = BladeTrendService.describe(build([1.2]));
      expect(t, contains('只有一次量測'));
      expect(t, contains('下次到場'));
    });

    test('上升超過門檻時建議近距離複檢', () {
      final t = BladeTrendService.describe(build([1.0, 2.0]));
      expect(t, contains('上升'));
      expect(t, contains('近距離複檢'));
    });

    test('下降**不能**被說成好轉——侵蝕不會自己好', () {
      final t = BladeTrendService.describe(build([2.5, 1.0]));
      expect(t, contains('下降'));
      expect(t, contains('侵蝕不會自己好'));
      expect(t, isNot(contains('改善')));
      expect(t, isNot(contains('好轉')));
    });

    test('小幅變動說成與雜訊同級，不當成趨勢', () {
      final t = BladeTrendService.describe(build([1.00, 1.10]));
      expect(t, contains('雜訊'));
    });

    test('describe 從不輸出「合格」', () {
      for (final r in [
        [1.0, 1.05],
        [1.0, 2.0],
        [2.5, 1.0],
        [1.2],
      ]) {
        expect(BladeTrendService.describe(build(r)), isNot(contains('合格')));
      }
    });
  });

  test('人工駁回的點留在序列裡並標記，不從線上消失', () {
    final series = BladeTrendService.build(
      detections: [
        det('s1', ratio: 1.0),
        det('s2', ratio: 2.5, human: WtHumanStatus.rejected),
        det('s3', ratio: 2.6),
      ],
      sessions: [s1, s2, s3],
    );
    expect(series.single.points, hasLength(3),
        reason: '駁回的是「這是缺陷」這個判斷，量到的數值仍是那天的事實');
    expect(
        series.single.points
            .where((p) => p.humanStatus == WtHumanStatus.rejected),
        hasLength(1));
  });

  test('px 值有帶出來但只當同一次的參考（比值才是趨勢的量）', () {
    final series = BladeTrendService.build(
      detections: [det('s1', ratio: 1.0, rms: 0.11)],
      sessions: [s1],
    );
    expect(series.single.points.single.rmsPx, 0.11);
    expect(BladeTrendService.comparabilityCaveat, contains('同一段'));
  });
}

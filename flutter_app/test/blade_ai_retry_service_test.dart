import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_ai_retry_service.dart';
import 'package:induspect_ai/services/blade_ai_service.dart';

/// AI 補跑佇列的測試。
///
/// 守三件事：①人工簽核過的不能被事後補跑的 AI 改掉；②失敗一律維持待補、
/// 不寫入半套結果；③合併走與線上分析同一條規則（演算法的等級是下限）。
class _FakeStore implements BladeAiRetryStore {
  final List<WtDetection> pending;
  final Map<String, WtCaptureSession> sessions;
  final List<WtDetection> saved = [];
  int pendingCalls = 0;
  int sessionCalls = 0;

  _FakeStore({required this.pending, this.sessions = const {}});

  @override
  Future<List<WtDetection>> pendingAi({int? limit}) async {
    pendingCalls++;
    return limit == null ? pending : pending.take(limit).toList();
  }

  @override
  Future<WtCaptureSession?> session(String sessionId) async {
    sessionCalls++;
    return sessions[sessionId];
  }

  @override
  Future<void> save(WtDetection detection) async => saved.add(detection);
}

void main() {
  final bytes = Uint8List.fromList(List<int>.filled(8, 3));

  WtDetection pendingDet(
    String id, {
    String sessionId = 's1',
    String path = '/tmp/seg.jpg',
    int? severity = 4,
    WtHumanStatus human = WtHumanStatus.pending,
  }) =>
      WtDetection(
        detectionId: id,
        sessionId: sessionId,
        layer: WtLayer.surface,
        blade: 'A',
        zone: 'mid_LE',
        defectClass: 'leading_edge_erosion',
        severity: severity,
        metricJson: const {'le_over_te_rms_ratio': 2.4, 'rms_px': 0.28},
        mediaPath: path,
        source: WtDetectionSource.geminiOfflinePending,
        humanStatus: human,
        aiDescription: '前緣粗糙度明顯高於後緣，疑似侵蝕',
      );

  WtCaptureSession sessionWith(String path, {String? le = 'top'}) =>
      WtCaptureSession(
        sessionId: 's1',
        assetId: 'WTG-07',
        media: [
          WtMedia(
            path: path,
            view: WtMediaView.segment,
            zone: 'mid',
            bladePosition: 'A',
            leadingEdge: le,
            zoom: 5,
            qualityJson: const {'ok': true},
          ),
        ],
      );

  BladeImageAnalyzer stub(Map<String, dynamic> reply, {List<String>? seen}) =>
      ({required String prompt, required Uint8List imageBytes}) async {
        seen?.add(prompt);
        return reply;
      };

  test('★ 端側初判抬過的等級不是雲端覆核的下限：下限是演算法那一筆（A6）', () async {
    final local = WtDetection(
      detectionId: 'd-local',
      sessionId: 's1',
      layer: WtLayer.surface,
      blade: 'A',
      zone: 'mid_LE',
      defectClass: 'leading_edge_erosion',
      severity: 4, // 端側從演算法的 2 抬到 4
      confidence: 0.55,
      metricJson: const {
        'le_over_te_rms_ratio': 2.4,
        'ai_source': 'local_llm',
        'algorithm_severity': 2,
      },
      mediaPath: '/tmp/seg.jpg',
      source: WtDetectionSource.geminiOfflinePending,
      aiDescription: '【離線初判】前緣可見剝落',
    );
    final store = _FakeStore(
      pending: [local],
      sessions: {'s1': sessionWith('/tmp/seg.jpg')},
    );
    final out = await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: stub({
        'defect_class': 'leading_edge_erosion',
        'severity': 1,
        'confidence': 0.9,
        'description': '雲端：輕微，觀察即可',
      }),
    );
    expect(out.completed, 1);
    final saved = store.saved.single;
    expect(saved.severity, 2, reason: '雲端說 1、演算法 2、端側曾抬到 4 → 取演算法與雲端的較高者 2');
    expect(saved.source, WtDetectionSource.gemini);
    expect(saved.metricJson['ai_source'], 'cloud');
    expect(saved.metricJson.containsKey('algorithm_severity'), isFalse);
    expect(saved.aiDescription, isNot(contains('離線初判')));
    expect(saved.aiDescription, contains('雲端'));
  });

  test('補跑成功後來源轉為 gemini，演算法的數值與等級都留著', () async {
    final store = _FakeStore(
      pending: [pendingDet('d1')],
      sessions: {'s1': sessionWith('/tmp/seg.jpg')},
    );
    final out = await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: stub({
        'defect_class': 'leading_edge_erosion',
        'severity': 3,
        'confidence': 0.7,
        'description': '前緣有連續蝕點',
      }),
    );
    expect(out.completed, 1);
    expect(out.failed, 0);
    final saved = store.saved.single;
    expect(saved.source, WtDetectionSource.gemini);
    expect(saved.severity, 4, reason: '演算法量到的等級是下限，AI 不能往下砍');
    expect(saved.metricJson['le_over_te_rms_ratio'], 2.4);
    expect(saved.aiDescription, '前緣有連續蝕點');
    expect(saved.detectionId, 'd1');
  });

  test('AI 說是正常結構時不刪掉發現，走與線上分析同一條合併規則', () async {
    final store = _FakeStore(
      pending: [pendingDet('d1')],
      sessions: {'s1': sessionWith('/tmp/seg.jpg')},
    );
    await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: stub({'defect_class': 'none', 'severity': 1}),
    );
    final saved = store.saved.single;
    expect(saved.severity, 4);
    expect(saved.defectClass, 'leading_edge_erosion');
    expect(saved.aiDescription, contains('AI 認為這可能不是缺陷'));
  });

  test('AI 失敗時不寫入任何東西，維持待補', () async {
    final store = _FakeStore(
      pending: [pendingDet('d1')],
      sessions: {'s1': sessionWith('/tmp/seg.jpg')},
    );
    final out = await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: ({required String prompt, required Uint8List imageBytes}) =>
          Future<Map<String, dynamic>>.error(Exception('還是離線')),
    );
    expect(out.failed, 1);
    expect(out.completed, 0);
    expect(store.saved, isEmpty, reason: '半套結果比留著待補更糟');
  });

  test('照片檔不見了：算 missingFile 且維持待補（外接儲存可能回來）', () async {
    final store = _FakeStore(
      pending: [pendingDet('d1')],
      sessions: {'s1': sessionWith('/tmp/seg.jpg')},
    );
    final out = await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => throw Exception('no file'),
      analyzer: stub({'defect_class': 'none'}),
    );
    expect(out.missingFile, 1);
    expect(store.saved, isEmpty);
  });

  test('找不到所屬作業時算 orphaned，不當成失敗也不寫入', () async {
    final store = _FakeStore(pending: [pendingDet('d1')], sessions: const {});
    final out = await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: stub({'defect_class': 'none'}),
    );
    expect(out.orphaned, 1);
    expect(store.saved, isEmpty);
  });

  test('同一場次只查一次作業紀錄（不做 N+1）', () async {
    final store = _FakeStore(
      pending: [
        pendingDet('d1', path: '/tmp/a.jpg'),
        pendingDet('d2', path: '/tmp/b.jpg'),
        pendingDet('d3', path: '/tmp/c.jpg'),
      ],
      sessions: {'s1': sessionWith('/tmp/a.jpg')},
    );
    await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: stub({'defect_class': 'none'}),
    );
    expect(store.sessionCalls, 1);
    expect(store.saved, hasLength(3));
  });

  test('作業裡找不到該媒體時仍然補跑（少 prompt 上下文，比整筆放棄好）', () async {
    final seen = <String>[];
    final store = _FakeStore(
      pending: [pendingDet('d1', path: '/tmp/missing-record.jpg')],
      sessions: {'s1': sessionWith('/tmp/other.jpg')},
    );
    final out = await BladeAiRetryService.retryOnce(
      store: store,
      loadBytes: (_) async => bytes,
      analyzer: stub({'defect_class': 'none'}, seen: seen),
    );
    expect(out.completed, 1);
    expect(seen.single, contains('中段'));
  });

  test('批次上限會傳給 store，不會一次把額度打完', () async {
    final store = _FakeStore(
      pending: [for (var i = 0; i < 30; i++) pendingDet('d$i')],
      sessions: {'s1': sessionWith('/tmp/seg.jpg')},
    );
    await BladeAiRetryService.retryOnce(
      store: store,
      limit: 5,
      loadBytes: (_) async => bytes,
      analyzer: stub({'defect_class': 'none'}),
    );
    expect(store.saved, hasLength(5));
    expect(BladeAiRetryService.defaultBatchLimit, lessThan(50));
  });

  test('沒有待補時不做任何事（也不查作業）', () async {
    final store = _FakeStore(pending: const []);
    final out = await BladeAiRetryService.retryOnce(store: store);
    expect(out.total, 0);
    expect(out.didWork, isFalse);
    expect(store.sessionCalls, 0);
  });

  group('zoneLabelOf', () {
    test('把 zone key 翻成 AI 看得懂的敘述，並帶上前緣在哪一側', () {
      final label = BladeAiRetryService.zoneLabelOf(
        pendingDet('d1'),
        WtMedia(path: '/tmp/a.jpg', leadingEdge: 'top'),
      );
      expect(label, contains('中段'));
      expect(label, contains('上緣'));
    });

    test('沒有前緣側就只給區段，不編造', () {
      final label = BladeAiRetryService.zoneLabelOf(
        pendingDet('d1'),
        WtMedia(path: '/tmp/a.jpg'),
      );
      expect(label, '中段');
    });
  });
}

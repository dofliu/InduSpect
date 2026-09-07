import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_ai_service.dart';

/// 葉片 AI 解讀的**分工與防呆**測試。
///
/// 守三件事：
/// 1. prompt 一定帶著「這些是正常結構」清單——少了它，AI 會把每條塗裝接縫報成裂縫，
///    現場兩天內就會開始無視所有警告。
/// 2. 數值由演算法算、AI 只解讀。AI 回什麼都不能改寫演算法的數字。
/// 3. AI 回超出值域的 severity/confidence 不能原封不動存進資料庫。
void main() {
  final bytes = Uint8List.fromList(List<int>.filled(16, 7));

  BladeImageAnalyzer stub(
    Map<String, dynamic> reply, {
    List<String>? capturePrompt,
  }) =>
      ({required String prompt, required Uint8List imageBytes}) async {
        capturePrompt?.add(prompt);
        return reply;
      };

  group('buildPrompt', () {
    test('每一項正常結構都寫在 prompt 裡', () {
      final p = BladeAiService.buildPrompt(zoneLabel: '中段前緣');
      for (final s in BladeAiService.normalStructures) {
        expect(p, contains(s),
            reason: '正常結構清單少一項，AI 就會把那一項報成缺陷');
      }
      expect(BladeAiService.normalStructures.length, greaterThanOrEqualTo(5));
    });

    test('演算法的數值標記成事實，並要求保守判斷', () {
      final p = BladeAiService.buildPrompt(
        zoneLabel: '尖段前緣',
        bladeLabel: 'B',
        metrics: {'le_over_te_rms_ratio': 5.2, 'pit_count': 23},
        cmPerPx: 1.4,
        zoom: 5,
        distanceM: 50,
      );
      expect(p, contains('le_over_te_rms_ratio: 5.2'));
      expect(p, contains('pit_count: 23'));
      expect(p, contains('不要重新估算'),
          reason: 'AI 若重算數值，報告上的數字就不再可稽核');
      expect(p, contains('needs_closer_look'));
      expect(p, contains('1.40 cm/px'));
      expect(p, contains('葉片：B'));
      expect(p, contains('5.0x'));
      expect(p, contains('50 m'));
    });

    test('沒有演算法數值時明說「無」，不留空白', () {
      final p = BladeAiService.buildPrompt(zoneLabel: '根段');
      expect(p, contains('- （無）'),
          reason: '空白會讓 AI 以為數值被省略而自行填補');
      expect(p, isNot(contains('光學倍率')));
    });
  });

  group('interpret', () {
    test('演算法數值原封不動保留，AI 的排除理由另存', () async {
      final d = await BladeAiService.interpret(
        detectionId: 'det-1',
        sessionId: 'sess-1',
        imageBytes: bytes,
        zoneLabel: '中段前緣',
        bladeLabel: 'A',
        zone: 'mid_LE',
        algorithmMetrics: {'rms_px': 0.61, 'pit_count': 23},
        analyzer: stub({
          'defect_class': 'leading_edge_erosion',
          'severity': 3,
          'confidence': 0.72,
          'description': '前緣有連續蝕點',
          'normal_structure_ruled_out': '痕跡不連續，不是合模線',
          // AI 想改演算法的數字：不該生效
          'rms_px': 99.0,
        }),
      );

      expect(d.metricJson['rms_px'], 0.61,
          reason: 'AI 回傳的同名鍵不得覆蓋演算法量到的值');
      expect(d.metricJson['pit_count'], 23);
      expect(d.metricJson['normal_structure_ruled_out'],
          '痕跡不連續，不是合模線');
      expect(d.source, WtDetectionSource.gemini);
      expect(d.layer, WtLayer.surface);
      expect(d.blade, 'A');
      expect(d.zone, 'mid_LE');
      expect(d.aiDescription, '前緣有連續蝕點');
      expect(d.severity, 3);
      expect(d.humanStatus, WtHumanStatus.pending,
          reason: 'AI 初判不能自己變成已確認');
    });

    test('送出的 prompt 就是 buildPrompt 的產物', () async {
      final seen = <String>[];
      await BladeAiService.interpret(
        detectionId: 'det-2',
        sessionId: 'sess-1',
        imageBytes: bytes,
        zoneLabel: '尖段後緣',
        analyzer: stub({'defect_class': 'none'}, capturePrompt: seen),
      );
      expect(seen.single, contains('區段：尖段後緣'));
      expect(seen.single, contains(BladeAiService.normalStructures.first));
    });

    test('超出值域的 severity / confidence 被夾回範圍內', () async {
      final high = await BladeAiService.interpret(
        detectionId: 'det-3',
        sessionId: 'sess-1',
        imageBytes: bytes,
        zoneLabel: '根段',
        analyzer: stub({'severity': 9, 'confidence': 1.8}),
      );
      expect(high.severity, 5);
      expect(high.confidence, 1.0);

      final low = await BladeAiService.interpret(
        detectionId: 'det-4',
        sessionId: 'sess-1',
        imageBytes: bytes,
        zoneLabel: '根段',
        analyzer: stub({'severity': 0, 'confidence': -0.5}),
      );
      expect(low.severity, 1);
      expect(low.confidence, 0.0);
    });

    test('缺欄位或型別不對時留 null，不編造數值', () async {
      final d = await BladeAiService.interpret(
        detectionId: 'det-5',
        sessionId: 'sess-1',
        imageBytes: bytes,
        zoneLabel: '根段',
        analyzer: stub({'severity': '很嚴重', 'confidence': 'high'}),
      );
      expect(d.severity, isNull);
      expect(d.confidence, isNull);
      expect(d.defectClass, isNull);
      expect(d.aiDescription, isNull);
    });

    test('AI 失敗時例外往上丟，讓呼叫端排進離線佇列', () async {
      await expectLater(
        () => BladeAiService.interpret(
          detectionId: 'det-6',
          sessionId: 'sess-1',
          imageBytes: bytes,
          zoneLabel: '根段',
          analyzer: ({required String prompt, required Uint8List imageBytes}) =>
              Future<Map<String, dynamic>>.error(Exception('網路不通')),
        ),
        throwsA(isA<Exception>()),
        reason: '吞掉例外會讓那一筆分析悄悄消失',
      );
    });
  });
}

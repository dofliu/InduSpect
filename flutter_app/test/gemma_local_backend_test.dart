import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/analysis_result.dart';
import 'package:induspect_ai/utils/constants.dart';
import 'package:induspect_ai/services/ai/ai_backend.dart';
import 'package:induspect_ai/services/ai/gemma_local_backend.dart';
import 'package:induspect_ai/services/ai/local_model_manager.dart';

/// 端側後端與模型管理：用假執行器測到底，不碰原生。
void main() {
  final img = Uint8List.fromList([1, 2, 3]);

  group('GemmaLocalBackend', () {
    test('來源一律 localLlm', () {
      final b = GemmaLocalBackend(({required prompt, imageBytes}) async => '{}');
      expect(b.source, AiSource.localLlm);
      expect(b.source.key, 'local_llm');
    });

    test('照片判讀：把圖與項目名送進去、把四欄位接回 AnalysisResult', () async {
      String? seenPrompt;
      Uint8List? seenImg;
      final b = GemmaLocalBackend(({required prompt, imageBytes}) async {
        seenPrompt = prompt;
        seenImg = imageBytes;
        return '結果：{"equipment_type":"泵","is_anomaly":true,"condition":"漏油","anomaly":"軸封"}';
      });
      final r = await b.analyzeInspectionPhoto(
          itemId: 'i1', itemDescription: '循環泵', imageBytes: img, photoPath: '/p.jpg');
      expect(seenPrompt, contains('循環泵'));
      expect(seenImg, same(img));
      expect(r.status, AnalysisStatus.completed);
      expect(r.equipmentType, '泵');
      expect(r.isAnomaly, isTrue);
      expect(r.readings, isEmpty);
    });

    test('模型回不出 JSON → 丟 LocalVlmUnusableException，不回假的正常結果', () {
      final b = GemmaLocalBackend(({required prompt, imageBytes}) async => '我看不清楚這張圖');
      expect(
        () => b.analyzeInspectionPhoto(itemId: 'i', itemDescription: 'x', imageBytes: img, photoPath: 'p'),
        throwsA(isA<LocalVlmUnusableException>()),
      );
    });

    test('總結報告：純文字，空的就丟', () async {
      final b = GemmaLocalBackend(({required prompt, imageBytes}) async => '  整體正常，建議下月複檢。 ');
      expect(await b.generateSummaryReport('[]'), '整體正常，建議下月複檢。');
      final empty = GemmaLocalBackend(({required prompt, imageBytes}) async => '   ');
      expect(() => empty.generateSummaryReport('[]'), throwsA(isA<LocalVlmUnusableException>()));
    });

    test('自訂 prompt（葉片線形狀）回 map', () async {
      final b = GemmaLocalBackend(({required prompt, imageBytes}) async => '```json {"defect_class":"erosion","severity":2}```');
      final m = await b.analyzeImageWithPrompt(prompt: 'p', imageBytes: img);
      expect(m['defect_class'], 'erosion');
      expect(m['severity'], 2);
    });
  });

  group('LocalModelManager', () {
    LocalModelManager mk({
      Future<void> Function(LocalModelSource, {void Function(int)? onProgress})? installer,
      bool installed = false,
    }) =>
        LocalModelManager(
          installer: installer ?? (s, {onProgress}) async {},
          probe: (_) async => installed,
          remover: (_) async {},
        );

    test('refresh 問原生：裝了就 ready', () async {
      final m = mk(installed: true);
      await m.refresh();
      expect(m.isReady, isTrue);
      final n = mk(installed: false);
      await n.refresh();
      expect(n.state, LocalModelState.notInstalled);
    });

    test('安裝過程回報進度、成功變 ready', () async {
      final m = mk(installer: (s, {onProgress}) async {
        onProgress?.call(10);
        onProgress?.call(150); // 亂值要被夾住
      });
      final seen = <int>[];
      m.addListener(() => seen.add(m.progress));
      expect(await m.install(const LocalModelSource.file('/m.litertlm')), isTrue);
      expect(m.isReady, isTrue);
      expect(seen, contains(10));
      expect(seen.every((p) => p <= 100), isTrue);
    });

    test('安裝失敗留原因、狀態 failed，不是 ready', () async {
      final m = mk(installer: (s, {onProgress}) async => throw Exception('磁碟滿'));
      expect(await m.install(const LocalModelSource.network('https://x/m.litertlm')), isFalse);
      expect(m.state, LocalModelState.failed);
      expect(m.error, contains('磁碟滿'));
    });

    test('同時只允許一個安裝', () async {
      var started = 0;
      final m = mk(installer: (s, {onProgress}) async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      final a = m.install(const LocalModelSource.file('/a'));
      final b = m.install(const LocalModelSource.file('/b'));
      expect(await b, isFalse);
      expect(await a, isTrue);
      expect(started, 1);
    });

    test('移除後回 notInstalled', () async {
      final m = mk(installed: true);
      await m.refresh();
      await m.remove();
      expect(m.state, LocalModelState.notInstalled);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/standards_engine.dart';

/// StandardsEngine（Tier 0 離線判定引擎）測試
///
/// 判定語意移植自 backend/tests/test_unit_conversion_judgment.py 與
/// test_judgment_service.py 的關鍵案例 — Dart 引擎必須與後端
/// judge-readings 給出一致結果，離線/雲端判定才可互換。
void main() {
  late StandardsEngine engine;

  setUpAll(() {
    // 測試直接讀取內嵌 asset 的來源檔（flutter test 的 CWD 為 flutter_app/）
    final jsonStr =
        File('assets/standards/inspection_standards.json').readAsStringSync();
    engine = StandardsEngine.fromJsonString(jsonStr);
  });

  group('標準資料載入', () {
    test('56 條標準、四大類別數量正確', () {
      expect(engine.standards.length, 56);
      final counts = <String, int>{};
      for (final s in engine.standards) {
        counts[s['category'] as String] =
            (counts[s['category'] as String] ?? 0) + 1;
      }
      expect(counts['electrical'], 15);
      expect(counts['fire'], 15);
      expect(counts['mechanical'], 15);
      expect(counts['pressure'], 11);
    });

    test('版本欄位存在', () {
      expect(engine.version, isNotEmpty);
      expect(engine.version, isNot('unknown'));
    });
  });

  group('normalizeUnit 單位正規化', () {
    test('溫度變體', () {
      expect(StandardsEngine.normalizeUnit('℃'), '°C');
      expect(StandardsEngine.normalizeUnit('degC'), '°C');
      expect(StandardsEngine.normalizeUnit('°c'), '°C');
      expect(StandardsEngine.normalizeUnit('C'), '°C');
    });

    test('電阻變體', () {
      expect(StandardsEngine.normalizeUnit('Mohm'), 'MΩ');
      expect(StandardsEngine.normalizeUnit('kOhm'), 'kΩ');
      expect(StandardsEngine.normalizeUnit('ohm'), 'Ω');
    });

    test('壓力變體與空白', () {
      expect(StandardsEngine.normalizeUnit('kg/cm2'), 'kgf/cm²');
      expect(StandardsEngine.normalizeUnit('  MΩ  '), 'MΩ');
      expect(StandardsEngine.normalizeUnit(null), '');
      expect(StandardsEngine.normalizeUnit(''), '');
    });

    test('未知單位原樣回傳', () {
      expect(StandardsEngine.normalizeUnit('XYZ'), 'XYZ');
    });
  });

  group('convertValue 同維度換算', () {
    test('kΩ → MΩ（安全 bug 的核心案例）', () {
      final (v, ok) = StandardsEngine.convertValue(500, 'kΩ', 'MΩ');
      expect(ok, true);
      expect(v, closeTo(0.5, 1e-9));
    });

    test('mA → A 與 A → mA', () {
      expect(StandardsEngine.convertValue(50, 'mA', 'A').$1, closeTo(0.05, 1e-9));
      expect(StandardsEngine.convertValue(0.05, 'A', 'mA').$1, closeTo(50, 1e-9));
    });

    test('溫度仿射換算 °F → °C', () {
      final (v, ok) = StandardsEngine.convertValue(212, '°F', '°C');
      expect(ok, true);
      expect(v, closeTo(100.0, 1e-9));
    });

    test('壓力 kgf/cm² → kPa', () {
      final (v, ok) = StandardsEngine.convertValue(1, 'kgf/cm2', 'kPa');
      expect(ok, true);
      expect(v, closeTo(98.0665, 1e-6));
    });

    test('同單位直接回傳', () {
      final (v, ok) = StandardsEngine.convertValue(52.3, 'MΩ', 'Mohm');
      expect(ok, true);
      expect(v, 52.3);
    });

    test('維度不相容 → 不可換算', () {
      expect(StandardsEngine.convertValue(5, 'MΩ', 'A').$2, false);
      expect(StandardsEngine.convertValue(5, '°C', 'kPa').$2, false);
    });

    test('非數值/空單位 → 不可換算', () {
      expect(StandardsEngine.convertValue('abc', 'kΩ', 'MΩ').$2, false);
      expect(StandardsEngine.convertValue(5, '', 'MΩ').$2, false);
    });
  });

  group('findMatchingStandard 匹配', () {
    test('絕緣電阻 → elec_insulation_lv 系列', () {
      final std = engine.findMatchingStandard('絕緣電阻 R相',
          unit: 'MΩ', equipmentType: '低壓配電設備');
      expect(std, isNotNull);
      expect(std!['inspection_item'], contains('絕緣電阻'));
    });

    test('不相干欄位不得假陽性匹配', () {
      final std = engine.findMatchingStandard('某不存在的項目',
          unit: 'X', equipmentType: '電氣');
      expect(std, isNull);
    });
  });

  group('autoJudge 自動判定（與後端 judge-readings 同語意）', () {
    test('絕緣電阻 52.3 MΩ → pass', () {
      final j = engine.autoJudge('絕緣電阻', 52.3, unit: 'MΩ', equipmentType: '電氣');
      expect(j['judgment'], 'pass');
      expect(j['confidence'], 0.98);
      expect(j['regulation'], isNotEmpty);
      expect(j['source'], 'local');
    });

    test('絕緣電阻 0.5 MΩ → fail', () {
      final j = engine.autoJudge('絕緣電阻', 0.5, unit: 'MΩ', equipmentType: '電氣');
      expect(j['judgment'], 'fail');
    });

    test('絕緣電阻 500 kΩ → 換算 0.5 MΩ → fail（單位防呆）', () {
      final j = engine.autoJudge('絕緣電阻', 500, unit: 'kΩ', equipmentType: '電氣');
      expect(j['judgment'], 'fail');
      expect(j['converted_unit'], 'MΩ');
      expect(j['converted_value'], closeTo(0.5, 1e-9));
      // 原始讀數保留，供 UI 顯示「500kΩ → 0.5MΩ」
      expect(j['measured_value'], 500);
      expect(j['unit'], 'kΩ');
    });

    test('絕緣電阻 1.5 MΩ → warning（合格但低於警告閾值 2.0）', () {
      final j = engine.autoJudge('絕緣電阻', 1.5, unit: 'MΩ', equipmentType: '電氣');
      expect(j['judgment'], 'warning');
      expect(j['confidence'], 0.7);
    });

    test('接地電阻 85 Ω → warning（lte 100 但超過警告閾值 80）', () {
      final j = engine.autoJudge('接地電阻', 85, unit: 'Ω', equipmentType: '電氣');
      expect(j['judgment'], 'warning');
    });

    test('接地電阻 120 Ω → fail', () {
      final j = engine.autoJudge('接地電阻', 120, unit: 'Ω', equipmentType: '電氣');
      expect(j['judgment'], 'fail');
    });

    test('無匹配標準 → unknown、confidence 0', () {
      final j = engine.autoJudge('某不存在的項目', 3.14, unit: 'X');
      expect(j['judgment'], 'unknown');
      expect(j['confidence'], 0.0);
      expect(j['standard_id'], isNull);
    });
  });

  group('judgeReadingsLocally 批次判定（端點同構回傳）', () {
    test('頂層合約 + 同序 + summary 計數', () {
      final readings = [
        {'field_name': '絕緣電阻 R相', 'value': 52.3, 'unit': 'MΩ'},
        {'field_name': '絕緣電阻 S相', 'value': 0.5, 'unit': 'MΩ'},
        {'field_name': '某不存在的項目', 'value': 3.14, 'unit': 'X'},
      ];
      final result =
          engine.judgeReadingsLocally(readings, equipmentType: '電氣');

      expect(result['success'], true);
      expect(result['source'], 'local');

      final judgments = result['judgments'] as List;
      expect(judgments.length, readings.length);
      // 同序（呼叫端以索引回填）
      for (int i = 0; i < readings.length; i++) {
        expect((judgments[i] as Map)['field_name'], readings[i]['field_name']);
      }
      expect((judgments[0] as Map)['judgment'], 'pass');
      expect((judgments[1] as Map)['judgment'], 'fail');
      expect((judgments[2] as Map)['judgment'], 'unknown');

      final summary = result['summary'] as Map;
      expect(summary['total_readings'], 3);
      expect(summary['pass_count'], 1);
      expect(summary['fail_count'], 1);
      expect(summary['unknown_count'], 1);

      final warnings = (result['warnings'] as List).cast<String>();
      expect(warnings.any((w) => w.contains('不合格')), true);
    });

    test('空清單', () {
      final result = engine.judgeReadingsLocally([], equipmentType: '電氣');
      expect(result['success'], true);
      expect(result['judgments'], isEmpty);
      expect((result['summary'] as Map)['total_readings'], 0);
    });
  });
}

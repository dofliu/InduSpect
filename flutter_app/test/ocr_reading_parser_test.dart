import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/ocr_reading_parser.dart';
import 'package:induspect_ai/services/standards_engine.dart';

/// OcrReadingParser（Tier 1a 可測試核心）測試
///
/// 案例模擬 ML Kit 對數位錶/銘牌的真實輸出：多行、夾雜型號/日期雜訊、
/// 全形字元、常見單位誤讀（Ω → Q）。
void main() {
  group('基本數值 + 單位', () {
    test('小數 + 空格 + 單位', () {
      final r = OcrReadingParser.bestReading('12.5 MΩ');
      expect(r, isNotNull);
      expect(r!.value, 12.5);
      expect(r.unit, 'MΩ');
    });

    test('數值黏著單位（無空格）', () {
      final r = OcrReadingParser.bestReading('350mA');
      expect(r!.value, 350);
      expect(r.unit, 'mA');
    });

    test('負值（壓力錶負壓）', () {
      final r = OcrReadingParser.bestReading('-0.2 MPa');
      expect(r!.value, -0.2);
      expect(r.unit, 'MPa');
    });

    test('千分位逗號', () {
      final r = OcrReadingParser.bestReading('1,250 rpm');
      expect(r!.value, 1250);
      expect(r.unit, 'rpm');
    });

    test('百分比', () {
      final r = OcrReadingParser.bestReading('80%');
      expect(r!.value, 80);
      expect(r.unit, '%');
    });

    test('溫度 ℃ 與 °C 變體', () {
      expect(OcrReadingParser.bestReading('75.5°C')!.unit, '°C');
      expect(OcrReadingParser.bestReading('75.5℃')!.unit, '°C');
    });

    test('無數字 → null', () {
      expect(OcrReadingParser.bestReading('狀況良好 OK'), isNull);
      expect(OcrReadingParser.bestReading(''), isNull);
    });
  });

  group('OCR 誤讀與全形正規化', () {
    test('Ω 被讀成 Q：MQ → MΩ、kQ → kΩ', () {
      expect(OcrReadingParser.bestReading('12.5 MQ')!.unit, 'MΩ');
      expect(OcrReadingParser.bestReading('500 kQ')!.unit, 'kΩ');
    });

    test('mQ 保留為 mΩ（毫歐），不得大小寫折疊成 MΩ', () {
      final r = OcrReadingParser.bestReading('50 mQ');
      expect(r!.unit, 'mΩ');
    });

    test('全形數字與小數點', () {
      final r = OcrReadingParser.bestReading('１２．５ＭΩ'.replaceAll('Ｍ', 'M'));
      expect(r!.value, 12.5);
      expect(r.unit, 'MΩ');
    });

    test('未知單位字串 → 視為無單位、數值保留', () {
      final r = OcrReadingParser.bestReading('42.7 XYZUNIT');
      expect(r!.value, 42.7);
      expect(r.unit, '');
    });
  });

  group('雜訊過濾', () {
    test('年份型整數（銘牌製造年）不入候選', () {
      expect(OcrReadingParser.parse('2026'), isEmpty);
      expect(OcrReadingParser.parse('MFG 2023'), isEmpty);
    });

    test('型號/序號黏著的數字不入候選（SN12345、IP54）', () {
      expect(OcrReadingParser.parse('SN12345'), isEmpty);
      expect(OcrReadingParser.parse('IP54'), isEmpty);
    });

    test('日期斜線後的數字不入候選', () {
      final all = OcrReadingParser.parse('2026/08/31');
      expect(all, isEmpty);
    });
  });

  group('bestReading 優先序（多行儀表文字）', () {
    const meterText = '''
INSULATION TESTER
2026
12.5 MΩ
50
''';

    test('期望單位命中優先', () {
      final r = OcrReadingParser.bestReading(meterText, expectedUnit: 'MΩ');
      expect(r!.value, 12.5);
      expect(r.unit, 'MΩ');
    });

    test('期望單位以正規化比較（Mohm 亦命中 MΩ）', () {
      final r = OcrReadingParser.bestReading(meterText, expectedUnit: 'Mohm');
      expect(r!.value, 12.5);
    });

    test('無期望單位時取第一個帶已知單位者', () {
      final r = OcrReadingParser.bestReading(meterText);
      expect(r!.value, 12.5);
      expect(r.unit, 'MΩ');
    });

    test('全無單位時偏好帶小數者', () {
      final r = OcrReadingParser.bestReading('88\n12.5\n7');
      expect(r!.value, 12.5);
    });

    test('display 格式：整數不帶小數點', () {
      expect(OcrReadingParser.bestReading('350mA')!.display, '350 mA');
      expect(OcrReadingParser.bestReading('12.5 MΩ')!.display, '12.5 MΩ');
    });
  });

  group('StandardsEngine.isKnownUnit', () {
    test('換算表單位/別名/常見單位為 true', () {
      expect(StandardsEngine.isKnownUnit('MΩ'), true);
      expect(StandardsEngine.isKnownUnit('Mohm'), true);
      expect(StandardsEngine.isKnownUnit('℃'), true);
      expect(StandardsEngine.isKnownUnit('%'), true);
      expect(StandardsEngine.isKnownUnit('rpm'), true);
    });

    test('未知字串/空白為 false', () {
      expect(StandardsEngine.isKnownUnit('XYZUNIT'), false);
      expect(StandardsEngine.isKnownUnit(''), false);
      expect(StandardsEngine.isKnownUnit(null), false);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/ai/local_vlm_prompt.dart';

/// 端側模型的輸出寬容解析。底線只有一條：分不出來不准倒向正常。
void main() {
  group('extractJsonObject', () {
    test('前後夾字與 ```json 都吃得下', () {
      const raw = '好的，以下是結果：```json\n{"a":1,"b":{"c":"}"}}\n```謝謝';
      expect(extractJsonObject(raw), '{"a":1,"b":{"c":"}"}}');
    });
    test('字串裡的大括號不算', () {
      expect(extractJsonObject('{"x":"{not closed"}'), '{"x":"{not closed"}');
    });
    test('沒有物件回 null', () {
      expect(extractJsonObject('沒有 JSON'), isNull);
      expect(extractJsonObject('{"never closed":1'), isNull);
    });
  });

  group('parseLocalInspectionJson', () {
    test('四欄位齊全 → 與雲端同形狀', () {
      final m = parseLocalInspectionJson(
          '{"equipment_type":"馬達","is_anomaly":true,"condition":"外殼鏽蝕","anomaly":"底座鏽蝕約 10 cm"}')!;
      expect(m['equipment_type'], '馬達');
      expect(m['is_anomaly'], isTrue);
      expect(m['condition_assessment'], '外殼鏽蝕');
      expect(m['anomaly_description'], '底座鏽蝕約 10 cm');
      expect(m['readings'], isEmpty);
    });

    test('端側不做讀值：模型硬塞 readings 也不收', () {
      final m = parseLocalInspectionJson(
          '{"equipment_type":"錶","is_anomaly":false,"condition":"ok","readings":{"溫度":{"value":75,"unit":"°C"}}}')!;
      expect(m['readings'], isEmpty, reason: '縮到 768 px 的圖讀不準數字；讀值交給全解析度 OCR');
    });

    test('is_anomaly 缺、但有異常描述 → 當異常', () {
      final m = parseLocalInspectionJson('{"condition":"有滲漏","anomaly":"法蘭滲油"}')!;
      expect(m['is_anomaly'], isTrue);
    });

    test('is_anomaly 缺、也沒有異常描述 → 不算異常（沒有證據不編）', () {
      final m = parseLocalInspectionJson('{"equipment_type":"閥","condition":"外觀正常"}')!;
      expect(m['is_anomaly'], isFalse);
      expect(m['anomaly_description'], isNull);
    });

    test('is_anomaly 用字串「是」也認得', () {
      expect(parseLocalInspectionJson('{"is_anomaly":"是","condition":"x"}')!['is_anomaly'], isTrue);
      expect(parseLocalInspectionJson('{"is_anomaly":"否","condition":"x"}')!['is_anomaly'], isFalse);
    });

    test('is_anomaly=false 時異常描述丟掉，避免矛盾', () {
      final m = parseLocalInspectionJson('{"is_anomaly":false,"condition":"ok","anomaly":"殘留字"}')!;
      expect(m['anomaly_description'], isNull);
    });

    test('一個可用欄位都沒有 → null，呼叫端走備援', () {
      expect(parseLocalInspectionJson('{"foo":1}'), isNull);
      expect(parseLocalInspectionJson('不是 JSON'), isNull);
      expect(parseLocalInspectionJson('{"broken":'), isNull);
    });

    test('雲端欄位名也接受（condition_assessment / anomaly_description）', () {
      final m = parseLocalInspectionJson(
          '{"condition_assessment":"良好","anomaly_description":"","is_anomaly":false}')!;
      expect(m['condition_assessment'], '良好');
    });
  });

  test('prompt 只要四個欄位、明講不要編數值', () {
    final p = LocalVlmPrompt.inspection('軸承溫度');
    expect(p, contains('軸承溫度'));
    expect(p, contains('"equipment_type"'));
    expect(p, contains('"is_anomaly"'));
    expect(p, isNot(contains('readings')), reason: '端側 prompt 不要求讀值');
    expect(p, contains('不確定就把 is_anomaly 設為 true'));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/screens/form_inspection_screen.dart';

/// 讀數對欄位的映射守門。
///
/// 這批測試存在的原因是一個已出貨的假陽性：`_findBestReadingMatch` 的關鍵字比對
/// 寫成了交叉乘積——只要**欄位名**命中某一組關鍵字就回傳**當下那一筆讀數**，
/// 不管那筆讀數是什麼量。於是「軸承溫度」欄位會被填進「A 相電流 12.4 A」，
/// 而且下游還會拿它去對「≤70 °C」判成合格，連法規依據都印出來。
void main() {
  Map<String, dynamic> r(double v, String unit) => {'value': v, 'unit': unit};

  group('量綱閘門', () {
    test('電流讀數不得填進溫度欄位', () {
      final match = findBestReadingMatch(
        '軸承溫度',
        {'A相電流': r(12.4, 'A')},
        expectedUnit: '°C',
      );
      expect(match, isNull, reason: '量綱不合的讀數寧可不填，也不要填錯一個會被判成合格的值');
    });

    test('唯一一筆讀數也要過量綱這一關', () {
      // 「只有一筆就直接用」是原本的最後手段，但單位對不上時它正是最危險的那條路。
      expect(
        findBestReadingMatch('絕緣電阻', {'讀值': r(220.0, 'V')}, expectedUnit: 'MΩ'),
        isNull,
      );
    });

    test('同量綱但不同倍率的讀數照收（kΩ 對 MΩ）', () {
      final match =
          findBestReadingMatch('絕緣電阻', {'絕緣電阻': r(1500.0, 'kΩ')}, expectedUnit: 'MΩ');
      expect(match, isNotNull);
      expect(match!['value'], 1500.0);
      expect(match['unit'], 'kΩ', reason: '換算交給 StandardsEngine，這裡只負責挑對的那一筆');
    });

    test('讀數沒帶單位時不否決，由名稱決定', () {
      final match = findBestReadingMatch(
        '軸承溫度',
        {'軸承溫度': {'value': 68.0}},
        expectedUnit: '°C',
      );
      expect(match, isNotNull);
      expect(match!['value'], 68.0);
    });
  });

  group('名稱與關鍵字比對', () {
    test('名稱完全對得上時直接取', () {
      final match = findBestReadingMatch(
        '軸承溫度',
        {'軸承溫度': r(68.0, '°C'), 'A相電流': r(12.4, 'A')},
        expectedUnit: '°C',
      );
      expect(match!['value'], 68.0);
    });

    test('關鍵字要兩邊同一組才算命中', () {
      // 修好之前：'溫度' 這一組因為欄位名命中就成立，於是回傳了電流那筆。
      final match = findBestReadingMatch(
        '馬達溫度',
        {'定子溫度': r(75.0, '°C')},
        expectedUnit: '°C',
      );
      expect(match!['value'], 75.0);
    });

    test('欄位名命中關鍵字、讀數名沒命中 → 不算命中', () {
      // 兩筆讀數，讓「只有一筆」那條退路不會蓋掉這裡要測的規則。
      final match = findBestReadingMatch(
        '馬達溫度',
        {'不相干的東西': r(3.0, '°C'), '另一個': r(4.0, '°C')},
        expectedUnit: '°C',
      );
      expect(match, isNull);
    });

    test('有標準時，唯一一筆沒帶單位的讀數不敢用', () {
      // 它會被送去判定。沒有單位就無從確認量綱，
      // 用了就可能出現「3.0 ≤ 70 °C 合格」這種憑空成立的判定。
      expect(
        findBestReadingMatch('馬達溫度', {'讀值': {'value': 3.0}}, expectedUnit: '°C'),
        isNull,
      );
    });

    test('沒有對應標準時，唯一一筆讀數照樣採用', () {
      // 刻意的取捨：沒有標準代表這個值不會被拿去判定，填錯只是一個人看得到、
      // 改得掉的欄位；丟掉它反而是白白損失。真正危險的是「有標準而量綱不合」，
      // 那一條在上面的閘門測試裡擋住了。
      final match = findBestReadingMatch(
        '振動速度',
        {'振動值': r(2.1, 'mm/s')},
        expectedUnit: null,
      );
      expect(match!['value'], 2.1);
    });

    test('沒有期望單位、只有一筆且名稱對得上 → 取', () {
      final match =
          findBestReadingMatch('轉速', {'轉速': r(1450.0, 'rpm')}, expectedUnit: null);
      expect(match!['value'], 1450.0);
    });

    test('多筆讀數時挑量綱對的那一筆', () {
      final match = findBestReadingMatch(
        '一次側電壓',
        {'A相電流': r(12.4, 'A'), '線電壓': r(380.0, 'V'), '油溫': r(55.0, '°C')},
        expectedUnit: 'V',
      );
      expect(match!['value'], 380.0);
    });

    test('空的 readings 回 null', () {
      expect(findBestReadingMatch('軸承溫度', const {}, expectedUnit: '°C'), isNull);
    });

    test('讀數值不是 Map 的髒資料不會炸', () {
      expect(
        () => findBestReadingMatch('軸承溫度', {'軸承溫度': 68.0}, expectedUnit: '°C'),
        returnsNormally,
      );
    });
  });
}

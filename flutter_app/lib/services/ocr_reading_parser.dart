import 'standards_engine.dart';

/// 從 OCR 文字中抽出的一筆數值讀值
class OcrReading {
  final double value;

  /// 正規化後的單位（無法辨識單位時為空字串）
  final String unit;

  /// 命中的原始文字片段（除錯與稽核用）
  final String raw;

  const OcrReading({required this.value, required this.unit, required this.raw});

  /// 顯示字串（供填入 manualValue）：整數不帶小數點
  String get display {
    final v = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    return unit.isEmpty ? v : '$v $unit';
  }

  @override
  String toString() => 'OcrReading($display, raw: "$raw")';
}

/// OCR 讀值解析器（Tier 1a 的可測試核心）
///
/// 職責：把 ML Kit（或任何 OCR）輸出的原始文字，解析為候選數值讀值，
/// 並依「期望單位 > 已知單位 > 帶小數 > 先出現」的優先序挑出最佳讀值。
/// OCR 引擎本身是薄 adapter（meter_ocr_service.dart），全部判斷邏輯在此，
/// 因此可在無裝置環境下完整單元測試。
class OcrReadingParser {
  OcrReadingParser._();

  /// 全形 → 半形（數字、小數點、負號、常見符號）
  static String _normalizeText(String text) {
    final buf = StringBuffer();
    for (final code in text.runes) {
      // 全形數字 ０-９ (0xFF10-0xFF19) → 0-9
      if (code >= 0xFF10 && code <= 0xFF19) {
        buf.writeCharCode(code - 0xFF10 + 0x30);
      } else if (code == 0xFF0E || code == 0x3002) {
        // ．、。 → .
        buf.write('.');
      } else if (code == 0xFF0C) {
        // ， → ,
        buf.write(',');
      } else if (code == 0xFF0D || code == 0x2212) {
        // －、− → -
        buf.write('-');
      } else if (code == 0xFF05) {
        // ％ → %
        buf.write('%');
      } else {
        buf.writeCharCode(code);
      }
    }
    return buf.toString();
  }

  /// 常見 OCR 單位誤讀修正（僅處理無歧義的型態；
  /// 注意 mΩ/MΩ 差 10^9，絕不做大小寫折疊）
  static String _fixUnitOcrErrors(String unit) {
    var u = unit.trim();
    // 尾端黏到的標點
    u = u.replaceAll(RegExp(r'[.,:;)]+$'), '');
    // Ω 常被讀成 Q / 0hm / ohm 變體
    u = u
        .replaceAll('MQ', 'MΩ')
        .replaceAll('GQ', 'GΩ')
        .replaceAll('kQ', 'kΩ')
        .replaceAll('KQ', 'kΩ')
        .replaceAll('mQ', 'mΩ')
        .replaceAll('uQ', 'μΩ')
        .replaceAll('0hm', 'ohm')
        .replaceAll('0HM', 'OHM');
    // 單獨的 Q → Ω（unit token 語境下無其他合理解讀）
    if (u == 'Q') u = 'Ω';
    return u;
  }

  /// 數值 + 選配單位。單位字元集涵蓋 Ω/μ/°/℃/℉/%/²/³ 與斜線複合單位（m³/h）
  static final RegExp _numUnit = RegExp(
    r'(-?\d{1,3}(?:,\d{3})+(?:\.\d+)?|-?\d+(?:\.\d+)?)[ \t]*'
    r'([A-Za-zΩμ°℃℉%²³]{1,8}(?:/[A-Za-z²³]{1,4})?)?',
  );

  /// 解析文字中的全部候選讀值（保序）
  static List<OcrReading> parse(String text) {
    final normalized = _normalizeText(text);
    final readings = <OcrReading>[];

    for (final m in _numUnit.allMatches(normalized)) {
      // 前一個字元若是英數/連字號/斜線 → 多半是型號、序號或日期的一部分，跳過
      // （例："SN12345"、"IP54"、"2026/08/31" 的月日）
      if (m.start > 0) {
        final prev = normalized[m.start - 1];
        if (RegExp(r'[A-Za-z0-9\-#/·]').hasMatch(prev)) continue;
      }

      final numStr = m.group(1)!.replaceAll(',', '');
      final value = double.tryParse(numStr);
      if (value == null) continue;

      var unit = _fixUnitOcrErrors(m.group(2) ?? '');
      final known = StandardsEngine.isKnownUnit(unit);
      if (!known) unit = '';

      // 無單位的年份型整數（1900-2100）多為銘牌/日期雜訊，跳過
      final isInteger = value == value.roundToDouble();
      if (unit.isEmpty && isInteger && value >= 1900 && value <= 2100) {
        continue;
      }

      readings.add(OcrReading(
        value: value,
        unit: unit.isEmpty ? '' : StandardsEngine.normalizeUnit(unit),
        raw: normalized.substring(m.start, m.end).trim(),
      ));
    }

    return readings;
  }

  /// 挑選最佳讀值。
  ///
  /// 優先序：
  /// 1. 單位與 [expectedUnit] 同（正規化後比較）
  /// 2. 帶已知單位者
  /// 3. 帶小數者（儀表讀值多有小數；整數常是刻度/編號雜訊）
  /// 4. 第一個候選
  static OcrReading? bestReading(String text, {String? expectedUnit}) {
    final candidates = parse(text);
    if (candidates.isEmpty) return null;

    if (expectedUnit != null && expectedUnit.trim().isNotEmpty) {
      final want = StandardsEngine.normalizeUnit(expectedUnit);
      for (final c in candidates) {
        if (c.unit == want) return c;
      }
    }

    for (final c in candidates) {
      if (c.unit.isNotEmpty) return c;
    }

    for (final c in candidates) {
      if (c.value != c.value.roundToDouble()) return c;
    }

    return candidates.first;
  }
}

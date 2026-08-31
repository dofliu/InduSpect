import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 法規標準判定引擎（Tier 0 離線判定）
///
/// 移植自 backend/app/data/inspection_standards.py 與
/// backend/app/services/judgment_service.py — 純規則邏輯、零 AI、零網路。
///
/// 標準資料的單一來源是後端 Python 檔，經 `backend/scripts/export_standards.py`
/// 匯出為 `assets/standards/inspection_standards.json` 內嵌到 App；
/// 後端 `tests/test_standards_json_sync.py` 守門確保兩者一致。
///
/// 判定語意必須與後端 `judge-readings` 端點完全一致（回傳欄位同名同義），
/// 使離線判定結果可與雲端判定互換；本地產生的 judgment 額外帶 `source: local`。
class StandardsEngine {
  final List<Map<String, dynamic>> standards;
  final String version;

  StandardsEngine({required this.standards, required this.version});

  static StandardsEngine? _cached;

  /// 從內嵌 asset 載入（App 執行期使用；結果快取）
  static Future<StandardsEngine> load() async {
    if (_cached != null) return _cached!;
    final jsonStr =
        await rootBundle.loadString('assets/standards/inspection_standards.json');
    _cached = StandardsEngine.fromJsonString(jsonStr);
    return _cached!;
  }

  /// 從 JSON 字串建立（測試用，或未來由後端拉取更新版標準）
  factory StandardsEngine.fromJsonString(String jsonStr) {
    final payload = jsonDecode(jsonStr) as Map<String, dynamic>;
    final list = (payload['standards'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return StandardsEngine(
      standards: list,
      version: payload['version'] as String? ?? 'unknown',
    );
  }

  // ============ 單位正規化與換算（對應 inspection_standards.py） ============

  /// 變體寫法 → 標準寫法（區分大小寫，優先比對）
  static const Map<String, String> _unitAliases = {
    '℃': '°C', 'C': '°C',
    '℉': '°F', 'F': '°F',
    'Mohm': 'MΩ', 'MOhm': 'MΩ', 'MΩ': 'MΩ',
    'kohm': 'kΩ', 'kOhm': 'kΩ', 'Kohm': 'kΩ',
    'Gohm': 'GΩ', 'GOhm': 'GΩ',
    'ohm': 'Ω', 'Ohm': 'Ω', 'OHM': 'Ω',
    'uΩ': 'μΩ', 'uohm': 'μΩ',
    'uA': 'μA', 'uV': 'μV', 'um': 'μm',
    'kgf/cm2': 'kgf/cm²', 'kg/cm²': 'kgf/cm²', 'kg/cm2': 'kgf/cm²',
    'cd/m2': 'cd/m²', 'm3/h': 'm³/h', 'm3/min': 'CMM',
  };

  /// 不分大小寫的變體（小寫鍵）
  static const Map<String, String> _unitAliasesCi = {
    'degc': '°C', '°c': '°C', 'oc': '°C', 'deg c': '°C',
    'degf': '°F', '°f': '°F', 'of': '°F', 'deg f': '°F',
  };

  /// 同維度換算：單位 → (維度, 對基準單位的倍率)；value_in_base = value * factor
  static const Map<String, (String, double)> _conversionFactors = {
    // 電阻，基準 Ω
    'Ω': ('resistance', 1.0),
    'mΩ': ('resistance', 1e-3),
    'μΩ': ('resistance', 1e-6),
    'kΩ': ('resistance', 1e3),
    'MΩ': ('resistance', 1e6),
    'GΩ': ('resistance', 1e9),
    // 電流，基準 A
    'A': ('current', 1.0),
    'mA': ('current', 1e-3),
    'μA': ('current', 1e-6),
    'kA': ('current', 1e3),
    // 電壓，基準 V
    'V': ('voltage', 1.0),
    'mV': ('voltage', 1e-3),
    'kV': ('voltage', 1e3),
    // 壓力，基準 kPa
    'Pa': ('pressure', 1e-3),
    'kPa': ('pressure', 1.0),
    'MPa': ('pressure', 1e3),
    'bar': ('pressure', 100.0),
    'mbar': ('pressure', 0.1),
    'kgf/cm²': ('pressure', 98.0665),
    'psi': ('pressure', 6.894757),
    'atm': ('pressure', 101.325),
    // 時間，基準 s
    's': ('time', 1.0),
    'ms': ('time', 1e-3),
    'min': ('time', 60.0),
    'h': ('time', 3600.0),
    // 長度，基準 mm
    'mm': ('length', 1.0),
    'cm': ('length', 10.0),
    'm': ('length', 1000.0),
    'μm': ('length', 1e-3),
    'km': ('length', 1e6),
    // 速度，基準 mm/s
    'mm/s': ('velocity', 1.0),
    'cm/s': ('velocity', 10.0),
    'm/s': ('velocity', 1000.0),
  };

  /// 將單位變體寫法正規化為標準寫法。無對應者原樣回傳（去空白）。
  static String normalizeUnit(String? unit) {
    if (unit == null) return '';
    final u = unit.trim();
    if (u.isEmpty) return '';
    final exact = _unitAliases[u];
    if (exact != null) return exact;
    final ci = _unitAliasesCi[u.toLowerCase()];
    if (ci != null) return ci;
    return u;
  }

  /// 將 value 由 fromUnit 換算為 toUnit。
  /// 回傳 (convertedValue, ok)：ok=false 表示無法換算（單位空白、非數值、維度不相容）。
  static (double?, bool) convertValue(
      dynamic value, String? fromUnit, String? toUnit) {
    final fu = normalizeUnit(fromUnit);
    final tu = normalizeUnit(toUnit);
    if (fu.isEmpty || tu.isEmpty) return (null, false);

    final v = _toDouble(value);
    if (v == null) return (null, false);

    if (fu == tu) return (v, true);

    // 溫度為仿射換算，需特別處理
    const temps = {'°C', '°F'};
    if (temps.contains(fu) && temps.contains(tu)) {
      if (fu == '°F' && tu == '°C') return ((v - 32.0) * 5.0 / 9.0, true);
      if (fu == '°C' && tu == '°F') return (v * 9.0 / 5.0 + 32.0, true);
      return (v, true);
    }

    final a = _conversionFactors[fu];
    final b = _conversionFactors[tu];
    if (a != null && b != null && a.$1 == b.$1) {
      final base = v * a.$2;
      return (base / b.$2, true);
    }

    return (null, false);
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  // ============ 標準匹配與判定（對應 InspectionStandardsDB） ============

  /// 根據欄位名稱、單位、設備類型模糊匹配最佳標準。
  ///
  /// 與後端相同的匹配邏輯：欄位名稱相關性（inspection_item 或 keyword 命中）
  /// 為必要條件；單位/設備類型僅作加分。無匹配回傳 null。
  Map<String, dynamic>? findMatchingStandard(
    String fieldName, {
    String unit = '',
    String equipmentType = '',
  }) {
    final fieldLower = fieldName.toLowerCase().trim();
    // (score, index, standard) — index 保留 Python 穩定排序語意（同分取前者）
    final candidates = <(int, int, Map<String, dynamic>)>[];

    for (int i = 0; i < standards.length; i++) {
      final std = standards[i];
      final item = (std['inspection_item'] as String?) ?? '';

      int nameScore = 0;
      if (item.isNotEmpty &&
          (fieldName.contains(item) || item.contains(fieldName))) {
        nameScore += 10;
      }
      for (final kw in (std['keywords'] as List? ?? const [])) {
        if (fieldLower.contains(kw.toString().toLowerCase())) {
          nameScore += 3;
        }
      }

      if (nameScore == 0) continue;

      int score = nameScore;

      final stdUnit = (std['unit'] as String?) ?? '';
      if (unit.isNotEmpty &&
          stdUnit.isNotEmpty &&
          normalizeUnit(unit) == normalizeUnit(stdUnit)) {
        score += 5;
      }

      final stdEquip = (std['equipment_type'] as String?) ?? '';
      if (equipmentType.isNotEmpty) {
        if (stdEquip.contains(equipmentType)) {
          score += 4;
        } else if (stdEquip.isNotEmpty && equipmentType.contains(stdEquip)) {
          score += 3;
        }
      }

      candidates.add((score, i, std));
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
    });
    return candidates.first.$3;
  }

  /// 根據標準值判定量測值。回傳 {judgment, standard_text, regulation}。
  Map<String, dynamic> judgeValue(
      Map<String, dynamic> standard, dynamic measuredValue) {
    final condition = standard['pass_condition'] as String?;
    final passVal = standard['pass_value'];
    final warningVal = standard['warning_value'];
    final unit = (standard['unit'] as String?) ?? '';
    final regulation = (standard['regulation'] as String?) ?? '';

    if (passVal == null) {
      return {
        'judgment': 'unknown',
        'standard_text': unit.isNotEmpty ? '依設計值 ($unit)' : '依設計值',
        'regulation': regulation,
      };
    }

    // in_set 比較（文字值）
    if (condition == 'in_set') {
      final valueStr = measuredValue.toString().trim();
      final allowed = (passVal as List).map((e) => e.toString()).toList();
      final isPass = allowed.contains(valueStr);
      return {
        'judgment': isPass ? 'pass' : 'fail',
        'standard_text': '必須為: ${allowed.join('/')}',
        'regulation': regulation,
      };
    }

    final standardText = _formatStandardText(condition, passVal, unit);

    final numVal = _toDouble(measuredValue);
    if (numVal == null) {
      return {
        'judgment': 'unknown',
        'standard_text': standardText,
        'regulation': regulation,
      };
    }

    Map<String, dynamic> result(String judgment) => {
          'judgment': judgment,
          'standard_text': standardText,
          'regulation': regulation,
        };

    switch (condition) {
      case 'gte':
        final threshold = (passVal as num).toDouble();
        if (numVal >= threshold) {
          if (warningVal != null && numVal < (warningVal as num).toDouble()) {
            return result('warning');
          }
          return result('pass');
        }
        return result('fail');

      case 'lte':
        final threshold = (passVal as num).toDouble();
        if (numVal <= threshold) {
          if (warningVal != null && numVal > (warningVal as num).toDouble()) {
            return result('warning');
          }
          return result('pass');
        }
        return result('fail');

      case 'range':
        final list = passVal as List;
        final minVal = (list[0] as num).toDouble();
        final maxVal = (list[1] as num).toDouble();
        if (numVal >= minVal && numVal <= maxVal) return result('pass');
        return result('fail');

      case 'eq':
        final target = (passVal as num).toDouble();
        if ((numVal - target).abs() < 0.001) return result('pass');
        return result('fail');
    }

    return result('unknown');
  }

  String _formatStandardText(String? condition, dynamic passVal, String unit) {
    switch (condition) {
      case 'gte':
        return '≥$passVal $unit'.trim();
      case 'lte':
        return '≤$passVal $unit'.trim();
      case 'range':
        final list = passVal as List;
        return '${list[0]}~${list[1]} $unit'.trim();
      case 'eq':
        return '=$passVal $unit'.trim();
      case 'in_set':
        return (passVal as List).map((e) => e.toString()).join('|');
    }
    return passVal.toString();
  }

  // ============ 自動判定（對應 JudgmentService.auto_judge） ============

  /// 單筆讀數自動判定。回傳格式與後端 judge-readings 的 judgment 完全同構，
  /// 額外帶 `source: local` 標記判定來源（稽核用）。
  Map<String, dynamic> autoJudge(
    String fieldName,
    dynamic measuredValue, {
    String unit = '',
    String equipmentType = '',
  }) {
    final standard = findMatchingStandard(
      fieldName,
      unit: unit,
      equipmentType: equipmentType,
    );

    if (standard == null) {
      return {
        'field_name': fieldName,
        'measured_value': measuredValue,
        'unit': unit,
        'judgment': 'unknown',
        'standard_text': '',
        'regulation': '',
        'confidence': 0.0,
        'standard_id': null,
        'converted_value': null,
        'converted_unit': null,
        'source': 'local',
      };
    }

    // 判定前先把讀數換算成標準單位，避免單位數量級不一致造成誤判
    // （例：500 kΩ = 0.5 MΩ 應為不合格，若不換算會誤判為合格）
    final stdUnit = (standard['unit'] as String?) ?? '';
    dynamic valueForJudge = measuredValue;
    bool converted = false;
    if (unit.isNotEmpty && stdUnit.isNotEmpty) {
      final (cv, ok) = convertValue(measuredValue, unit, stdUnit);
      if (ok && cv != null) {
        valueForJudge = cv;
        converted = normalizeUnit(unit) != normalizeUnit(stdUnit);
      }
    }

    final result = judgeValue(standard, valueForJudge);
    final judgment = result['judgment'] as String;
    final confidence = (judgment == 'pass' || judgment == 'fail') ? 0.98 : 0.7;

    return {
      'field_name': fieldName,
      'measured_value': measuredValue,
      'unit': unit.isNotEmpty ? unit : stdUnit,
      'judgment': judgment,
      'standard_text': result['standard_text'],
      'regulation': result['regulation'],
      'confidence': confidence,
      'standard_id': standard['standard_id'],
      'converted_value': converted ? valueForJudge : null,
      'converted_unit': converted ? stdUnit : null,
      'source': 'local',
    };
  }

  /// 批次判定 — 回傳格式與後端 POST /api/auto-fill/judge-readings 同構：
  /// {success, judgments, warnings, summary}，judgments 與輸入同序（呼叫端以索引回填）。
  Map<String, dynamic> judgeReadingsLocally(
    List<Map<String, dynamic>> readings, {
    String equipmentType = '',
  }) {
    final judgments = <Map<String, dynamic>>[];
    final warnings = <String>[];
    int passCount = 0, failCount = 0, warningCount = 0, unknownCount = 0;

    for (final r in readings) {
      final j = autoJudge(
        (r['field_name'] ?? '').toString(),
        r['value'],
        unit: (r['unit'] ?? '').toString(),
        equipmentType: equipmentType,
      );
      judgments.add(j);

      switch (j['judgment']) {
        case 'pass':
          passCount++;
          break;
        case 'fail':
          failCount++;
          warnings.add(
              '不合格: ${j['field_name']} = ${j['measured_value']}${j['unit'] ?? ''}，標準: ${j['standard_text'] ?? ''}');
          break;
        case 'warning':
          warningCount++;
          warnings.add(
              '警告: ${j['field_name']} = ${j['measured_value']}${j['unit'] ?? ''} 接近不合格');
          break;
        default:
          unknownCount++;
      }
    }

    return {
      'success': true,
      'judgments': judgments,
      'warnings': warnings,
      'summary': {
        'total_readings': readings.length,
        'pass_count': passCount,
        'fail_count': failCount,
        'warning_count': warningCount,
        'unknown_count': unknownCount,
      },
      'source': 'local',
      'standards_version': version,
    };
  }
}

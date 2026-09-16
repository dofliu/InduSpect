import 'dart:convert';

/// 端側 VLM 的 prompt 與解析。全部是純函式，測得到。
///
/// 雲端 prompt 要求十幾個欄位的 JSON；2B 等級的模型會漏欄位、會在 JSON 外面加話。
/// 這裡刻意只要**四個欄位**，讀值不要——讀值交給全解析度的 OCR（Tier 1a），
/// 模型看的是縮到 768 px 的圖，錶面數字只剩幾個像素高。
class LocalVlmPrompt {
  LocalVlmPrompt._();

  /// 系統指令：短、明確、只講格式。
  static const String systemInstruction =
      '你是工業設備巡檢助理。只回傳一個 JSON 物件，不要 markdown、不要說明文字。';

  /// 單張定檢照片的判讀。
  static String inspection(String itemDescription) => '''
檢查項目：$itemDescription
看這張照片，回答四件事，用這個 JSON 格式（值用繁體中文）：
{"equipment_type":"設備類型","is_anomaly":false,"condition":"一句話描述狀況","anomaly":"若有異常寫在哪裡、多嚴重；沒有就空字串"}
注意：不確定就把 is_anomaly 設為 true。不要編造數值讀數。''';

  /// 總結報告：純文字，不要 JSON。
  static String summary(String recordsJson) => '''
以下是一次巡檢的逐項結果（JSON）。請用繁體中文寫一段 150 字以內的總結：
先講有沒有異常與在哪些項目，再講建議。不要重複列出每一項。
$recordsJson''';
}

/// 端側模型吐出來的四欄位 JSON → 與雲端同形狀的 map。
///
/// 寬容到什麼程度是有底線的：**解不出 `is_anomaly` 就當異常**——
/// 這與分類表「疑似分不出來時不准倒向 healthy」是同一條原則。
/// 回 null 代表連一個可用的欄位都沒有，呼叫端該走下一層備援。
Map<String, dynamic>? parseLocalInspectionJson(String raw) {
  final text = extractJsonObject(raw);
  if (text == null) return null;
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final m = Map<String, dynamic>.from(decoded);

  final equipment = _str(m['equipment_type']);
  final condition = _str(m['condition'] ?? m['condition_assessment']);
  final anomaly = _str(m['anomaly'] ?? m['anomaly_description']);
  final isAnomaly = _bool(m['is_anomaly']);
  if (equipment == null && condition == null && anomaly == null && isAnomaly == null) {
    return null;
  }

  // 分不出來就當異常，交給人看——不是當正常。
  final anomalyFlag = isAnomaly ?? (anomaly != null && anomaly.isNotEmpty);
  return <String, dynamic>{
    'equipment_type': equipment ?? '',
    // 讀值一律空：端側不做讀值（見檔頭）。就算模型硬塞了 readings 也不收。
    'readings': <String, dynamic>{},
    'condition_assessment': condition ?? '',
    'is_anomaly': anomalyFlag,
    'anomaly_description': anomalyFlag ? (anomaly ?? '') : null,
    'estimated_size': null,
  };
}

/// 從夾雜文字的回應裡挖出第一個平衡的 `{…}`。
/// 小模型常在 JSON 前後加話、或包在 ```json 裡；這裡都要吃得下。
String? extractJsonObject(String raw) {
  var s = raw.replaceAll('```json', '').replaceAll('```', '');
  final start = s.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (inString) {
      if (c == '\\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return s.substring(start, i + 1);
    }
  }
  return null;
}

String? _str(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

bool? _bool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (t == 'true' || t == 'yes' || t == '是' || t == '有') return true;
    if (t == 'false' || t == 'no' || t == '否' || t == '無') return false;
  }
  return null;
}

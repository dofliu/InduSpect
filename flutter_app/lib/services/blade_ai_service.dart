import 'dart:typed_data';

import '../models/wt_detection.dart';
import 'gemini_service.dart';

/// 影像解讀的注入點。`GeminiService` 是私有建構子的單例，無法子類化去假造，
/// 所以這裡收一個函式而不是收一個物件——測試可以直接餵回一段 JSON。
typedef BladeImageAnalyzer = Future<Map<String, dynamic>> Function({
  required String prompt,
  required Uint8List imageBytes,
});

/// 葉片影像的 AI 解讀（規格 §5.5 / §6）。
///
/// **AI 不算數字，只解讀。** 粗糙度、比值、凹坑數全部由 `blade_surface_service`
/// 算出來，AI 拿到的是「候選裁切 + 區段標籤 + 演算法量到的數值」，任務是判斷那是
/// 真缺陷還是正常結構，並給一個保守的等級與描述。這樣分工的理由是：數值要可重現、
/// 可稽核，而「這道痕是塗裝接縫還是裂縫」需要常識。
class BladeAiService {
  BladeAiService._();

  /// 葉片上這些東西**是正常結構**，不是缺陷。不寫進 prompt 的話，
  /// AI 會把每一條接縫都報成裂縫，現場就會開始無視所有警告。
  static const List<String> normalStructures = [
    '塗裝接縫、模具合模線（沿葉片長度的規則直線）',
    'LEP（前緣保護膜）的邊緣，會有一條清楚的階差',
    'VG 板（渦流產生器）與鋸齒尾緣等附加件',
    '排水孔、避雷接點、標記貼紙與編號噴漆',
    '雲影、塔架陰影、葉片自身的陰影',
    '鏡頭髒污與感光元件塵點（會固定出現在同一個畫面位置）',
  ];

  static String buildPrompt({
    required String zoneLabel,
    String? bladeLabel,
    Map<String, dynamic> metrics = const {},
    double? cmPerPx,
    double? zoom,
    double? distanceM,
  }) {
    final ctx = <String>[];
    if (bladeLabel != null) ctx.add('葉片：$bladeLabel');
    ctx.add('區段：$zoneLabel');
    if (zoom != null) ctx.add('光學倍率：${zoom.toStringAsFixed(1)}x');
    if (distanceM != null) ctx.add('估計距離：${distanceM.toStringAsFixed(0)} m');
    if (cmPerPx != null) {
      ctx.add('影像尺度：${cmPerPx.toStringAsFixed(2)} cm/px'
          '（小於此尺寸的缺陷在這張照片上物理上看不見）');
    }
    final metricLines = metrics.entries
        .map((e) => '- ${e.key}: ${e.value}')
        .join('\n');

    return '''
你是風力機葉片目視檢測的協助者。以下影像是**手機在地面拍攝**的葉片區段照。

拍攝條件：
${ctx.map((c) => '- $c').join('\n')}

演算法已量到的數值（這些是事實，不要重新估算）：
${metricLines.isEmpty ? '- （無）' : metricLines}

以下是葉片上的**正常結構**，不得報成缺陷：
${normalStructures.map((s) => '- $s').join('\n')}

請保守判斷。手機地面拍攝屬 Level 1 篩檢，看不到髮絲裂縫與早期蝕點；
看不清楚就回報 needs_closer_look，不要猜。

只輸出 JSON，格式如下：
{
  "defect_class": "leading_edge_erosion | trailing_edge_crack | surface_roughness | lightning_damage | attachment_missing | none | needs_closer_look",
  "severity": 1,
  "confidence": 0.0,
  "description": "看到什麼，用一句話講，不要重複上面的數值",
  "normal_structure_ruled_out": "說明你為什麼認為這不是上列的正常結構；若判定為 none 則寫『不適用』"
}

severity：1 = 觀察即可、2–3 = 列入追蹤、4 = 需近距離複檢、5 = 需立即處置。
confidence：0–1，看不清楚就給低分。
''';
  }

  /// 送一張候選裁切給 Gemini 解讀，回傳一筆偵測結果。
  ///
  /// [algorithmMetrics] 是演算法量到的數值——會一併寫進 `metricJson`，
  /// 所以報告上看得到「數字是誰算的、判斷是誰下的」。
  static Future<WtDetection> interpret({
    required String detectionId,
    required String sessionId,
    required Uint8List imageBytes,
    required String zoneLabel,
    String? bladeLabel,
    String? zone,
    String? mediaPath,
    Map<String, dynamic> algorithmMetrics = const {},
    double? cmPerPx,
    double? zoom,
    double? distanceM,
    BladeImageAnalyzer? analyzer,
  }) async {
    final analyze = analyzer ?? GeminiService().analyzeImageWithPrompt;
    final json = await analyze(
      prompt: buildPrompt(
        zoneLabel: zoneLabel,
        bladeLabel: bladeLabel,
        metrics: algorithmMetrics,
        cmPerPx: cmPerPx,
        zoom: zoom,
        distanceM: distanceM,
      ),
      imageBytes: imageBytes,
    );

    return WtDetection(
      detectionId: detectionId,
      sessionId: sessionId,
      layer: WtLayer.surface,
      blade: bladeLabel,
      zone: zone,
      defectClass: json['defect_class'] as String?,
      severity: _clampSeverity(json['severity']),
      confidence: _clampConfidence(json['confidence']),
      // 演算法的數值 + AI 的補充理由都留著。前者是稽核依據，
      // 後者是「為什麼不是接縫」的說明，兩者都不能只留一個。
      metricJson: {
        ...algorithmMetrics,
        if (json['normal_structure_ruled_out'] != null)
          'normal_structure_ruled_out': json['normal_structure_ruled_out'],
      },
      mediaPath: mediaPath,
      source: WtDetectionSource.gemini,
      aiDescription: json['description'] as String?,
    );
  }

  static int? _clampSeverity(dynamic v) {
    if (v is num) return v.round().clamp(1, 5);
    return null;
  }

  static double? _clampConfidence(dynamic v) {
    if (v is num) return v.toDouble().clamp(0.0, 1.0);
    return null;
  }
}

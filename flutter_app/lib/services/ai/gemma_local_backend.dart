import 'dart:convert';
import 'dart:typed_data';

import '../../models/analysis_result.dart';
import 'ai_backend.dart';
import 'local_vlm_prompt.dart';

/// 端側模型的最小形狀：一段文字（可帶一張圖）進、一段文字出。
///
/// `flutter_gemma` 的綁定在 `flutter_gemma_runner.dart`；這裡收函式不收物件，
/// 測試可以直接餵回一段 JSON，不用碰原生。
typedef LocalVlmRunner = Future<String> Function({
  required String prompt,
  Uint8List? imageBytes,
});

/// 端側模型沒有回可用內容。呼叫端據此走下一層備援（OCR／手動）。
class LocalVlmUnusableException implements Exception {
  const LocalVlmUnusableException(this.reason);
  final String reason;
  @override
  String toString() => 'LocalVlmUnusableException: $reason';
}

/// Tier 1b：裝置端 VLM（Gemma 3n）。
///
/// 三條不可退化：①`source` 一律 `localLlm`，呼叫端要把它寫進結果；
/// ②**不產生讀值**（`readings` 永遠空）；③解不出可用 JSON 就丟例外，
/// 不回一個「看起來正常」的空結果。
class GemmaLocalBackend implements AiBackend {
  GemmaLocalBackend(this._run);

  final LocalVlmRunner _run;

  @override
  AiSource get source => AiSource.localLlm;

  @override
  Future<AnalysisResult> analyzeInspectionPhoto({
    required String itemId,
    required String itemDescription,
    required Uint8List imageBytes,
    required String photoPath,
  }) async {
    final raw = await _run(
      prompt: LocalVlmPrompt.inspection(itemDescription),
      imageBytes: imageBytes,
    );
    final json = parseLocalInspectionJson(raw);
    if (json == null) {
      throw const LocalVlmUnusableException('端側模型沒有回可解析的 JSON');
    }
    return AnalysisResult.fromGeminiJson(itemId, photoPath, json);
  }

  @override
  Future<String> generateSummaryReport(String recordsJson) async {
    final text = (await _run(prompt: LocalVlmPrompt.summary(recordsJson))).trim();
    if (text.isEmpty) {
      throw const LocalVlmUnusableException('端側模型沒有回總結文字');
    }
    return text;
  }

  @override
  Future<Map<String, dynamic>> analyzeImageWithPrompt({
    required String prompt,
    required Uint8List imageBytes,
    String mimeType = 'image/jpeg',
  }) async {
    final raw = await _run(prompt: prompt, imageBytes: imageBytes);
    final text = extractJsonObject(raw);
    if (text == null) {
      throw const LocalVlmUnusableException('端側模型沒有回 JSON 物件');
    }
    final decoded = parseLooseJson(text);
    if (decoded == null) {
      throw const LocalVlmUnusableException('端側模型回的 JSON 解不開');
    }
    return decoded;
  }
}

/// `jsonDecode` 包一層：失敗回 null 而不是丟。
Map<String, dynamic>? parseLooseJson(String text) {
  try {
    final v = jsonDecode(text);
    return v is Map ? Map<String, dynamic>.from(v) : null;
  } catch (_) {
    return null;
  }
}

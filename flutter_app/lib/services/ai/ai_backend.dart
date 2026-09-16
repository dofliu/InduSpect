import 'dart:typed_data';

import '../../models/analysis_result.dart';

/// 結果是誰判的。寫進 `aiResult['source']`，報告與 PDF 要印出來——
/// 端側初判與雲端精判不能長得一樣。
enum AiSource {
  /// 雲端 Gemini（Tier 2）
  cloud,

  /// 裝置端 VLM（Tier 1b），結果一律標「離線初判」
  localLlm,

  /// 裝置端 OCR（Tier 1a；既有路徑，這裡只為了名字統一）
  ocr,
}

extension AiSourceLabel on AiSource {
  /// 存進 JSON 的穩定字串；改了會讓既有紀錄對不上。
  String get key => switch (this) {
        AiSource.cloud => 'cloud',
        AiSource.localLlm => 'local_llm',
        AiSource.ocr => 'ocr',
      };

  String get label => switch (this) {
        AiSource.cloud => '雲端 AI',
        AiSource.localLlm => '離線初判（裝置端 AI）',
        AiSource.ocr => '裝置端 OCR',
      };
}

/// 定檢與葉片兩條線用到的 AI 只有這三件事。
///
/// 抽成介面是為了讓「誰來判」變成可以切換、可以測的決定：
/// 雲端 Gemini（現況）與裝置端 Gemma 3n（Tier 1b）都實作它，
/// 畫面只認得 `AiBackend`，選層交給 `chooseAiTier`。
abstract class AiBackend {
  AiSource get source;

  /// 定檢照片的結構化判讀（設備類型／讀值／狀況／異常）。
  Future<AnalysisResult> analyzeInspectionPhoto({
    required String itemId,
    required String itemDescription,
    required Uint8List imageBytes,
    required String photoPath,
  });

  /// 檢測結果 JSON → 總結報告文字。
  Future<String> generateSummaryReport(String recordsJson);

  /// 自訂 prompt 看一張圖、回 JSON。葉片線的 `BladeImageAnalyzer` 形狀。
  Future<Map<String, dynamic>> analyzeImageWithPrompt({
    required String prompt,
    required Uint8List imageBytes,
    String mimeType = 'image/jpeg',
  });
}

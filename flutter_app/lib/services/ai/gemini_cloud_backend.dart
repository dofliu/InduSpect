import 'dart:typed_data';

import '../../models/analysis_result.dart';
import '../gemini_service.dart';
import 'ai_backend.dart';

/// Tier 2：雲端 Gemini。只是把既有的 singleton 包成 `AiBackend`，行為不變。
class GeminiCloudBackend implements AiBackend {
  GeminiCloudBackend(this._service);

  final GeminiService _service;

  @override
  AiSource get source => AiSource.cloud;

  @override
  Future<AnalysisResult> analyzeInspectionPhoto({
    required String itemId,
    required String itemDescription,
    required Uint8List imageBytes,
    required String photoPath,
  }) =>
      _service.analyzeInspectionPhoto(
        itemId: itemId,
        itemDescription: itemDescription,
        imageBytes: imageBytes,
        photoPath: photoPath,
      );

  @override
  Future<String> generateSummaryReport(String recordsJson) =>
      _service.generateSummaryReport(recordsJson);

  @override
  Future<Map<String, dynamic>> analyzeImageWithPrompt({
    required String prompt,
    required Uint8List imageBytes,
    String mimeType = 'image/jpeg',
  }) =>
      _service.analyzeImageWithPrompt(
        prompt: prompt,
        imageBytes: imageBytes,
        mimeType: mimeType,
      );
}

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// io 平台的 ML Kit Text Recognition 實作
///
/// - Android/iOS：離線 OCR（latin script 模型涵蓋數字與單位字母，體積最小）
/// - Windows/Linux 桌面：plugin 無原生實作 → MissingPluginException → 回 null
Future<String?> recognizeText(String imagePath) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final inputImage = InputImage.fromFilePath(imagePath);
    final result = await recognizer.processImage(inputImage);
    final text = result.text.trim();
    return text.isEmpty ? null : text;
  } catch (e) {
    debugPrint('MeterOcr 不可用或辨識失敗: $e');
    return null;
  } finally {
    try {
      await recognizer.close();
    } catch (_) {}
  }
}

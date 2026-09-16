import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import 'ai_tier_policy.dart';
import 'gemma_local_backend.dart';
import 'local_model_manager.dart';

/// 全 App **唯一**碰 `flutter_gemma` 的檔案。
///
/// 上游 API 換版時只改這裡；`GemmaLocalBackend`／`LocalModelManager` 只認得
/// `LocalVlmRunner`／`LocalModelInstaller` 那幾個函式形狀。
/// 這一檔在測試環境沒有原生可跑，所以**沒有單元測試**；它的正確性靠實機。
class FlutterGemmaRunner {
  FlutterGemmaRunner._();

  /// `.litertlm` 的上下文窗；圖 + 精簡 prompt + 四欄位回覆，2048 綽綽有餘。
  static const int _maxTokens = 2048;

  /// 回覆上限：四欄位 JSON 或 150 字總結，512 夠；小模型偶爾會一直講，這裡是煞車。
  static const int _maxOutputTokens = 512;

  /// 給 `GemmaLocalBackend` 的執行器。每次呼叫開一個 chat，用完關掉——
  /// 定檢照片彼此獨立，不需要對話歷史，留著只會吃掉上下文窗。
  static LocalVlmRunner runner({PreferredBackend backend = PreferredBackend.gpu}) {
    return ({required String prompt, Uint8List? imageBytes}) async {
      final model = await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: backend,
        supportImage: imageBytes != null,
        maxNumImages: imageBytes != null ? 1 : null,
      );
      final chat = await model.createChat(
        systemInstruction: _systemInstruction,
        maxOutputTokens: _maxOutputTokens,
        supportImage: imageBytes != null,
      );
      await chat.addQueryChunk(imageBytes == null
          ? Message.text(text: prompt, isUser: true)
          : Message.withImage(text: prompt, imageBytes: imageBytes, isUser: true));
      final response = await chat.generateChatResponse();
      return switch (response) {
        TextResponse(:final token) => token,
        _ => '',
      };
    };
  }

  static const String _systemInstruction =
      '你是工業設備巡檢助理。只回傳一個 JSON 物件或一段純文字，依指示而定；不要 markdown。';

  /// 給 `LocalModelManager` 的三個縫。
  static LocalModelInstaller get installer => (source, {onProgress}) async {
        var builder = FlutterGemma.installModel(
          modelType: ModelType.gemmaIt, // Gemma 3n 走 gemmaIt（README ModelType 表）
          fileType: ModelFileType.litertlm,
        );
        final staged = source.isFile
            ? builder.fromFile(source.path!)
            : builder.fromNetwork(source.url!, token: source.token);
        await staged
            .withProgress((p) => onProgress?.call(p.round()))
            .install();
      };

  static LocalModelProbe get probe => (modelId) => FlutterGemma.isModelInstalled(modelId);

  static LocalModelRemover get remover => (modelId) => FlutterGemma.uninstallModel(modelId);

  /// `main()` 呼叫一次。沒有這一步 `getActiveModel()` 會丟「add the engine package」。
  static Future<void> initialize() => FlutterGemma.initialize(
        inferenceEngines: const [LiteRtLmEngine()],
      );

  static LocalModelManager buildManager() => LocalModelManager(
        installer: installer,
        probe: probe,
        remover: remover,
        modelId: LocalModelRequirements.modelId,
      );
}

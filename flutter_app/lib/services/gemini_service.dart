import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../models/analysis_result.dart';
import '../utils/constants.dart';

/// Gemini AI 服務
/// 基於 aimodel.md 文檔中的提示工程策略
class GeminiService {
  static final GeminiService _instance = GeminiService._internal();
  factory GeminiService() => _instance;
  GeminiService._internal();

  late final GenerativeModel _flashModel;
  late final GenerativeModel _proModel;
  bool _initialized = false;
  String? _currentApiKey;

  /// 初始化 Gemini 服務
  /// [apiKey] 如果提供，使用此 API key；否則從 .env 讀取
  void init({String? apiKey}) {
    final effectiveApiKey = apiKey ?? dotenv.env['GEMINI_API_KEY'];

    if (effectiveApiKey == null || effectiveApiKey.isEmpty) {
      throw Exception(
        'GEMINI_API_KEY not found. Please provide API key or add it to .env file.',
      );
    }

    // 如果 API key 變更，重新初始化
    if (_initialized && _currentApiKey == effectiveApiKey) return;

    _currentApiKey = effectiveApiKey;

    // Flash 模型：用於圖像分析（快速、成本低）
    _flashModel = GenerativeModel(
      model: AppConstants.geminiFlashModel,
      apiKey: effectiveApiKey,
      generationConfig: GenerationConfig(
        temperature: 0.2, // 較低溫度，更穩定的輸出
        topP: 0.8,
        topK: 40,
        maxOutputTokens: 2048,
      ),
    );

    // Pro 模型：用於報告生成（高複雜度推理）
    _proModel = GenerativeModel(
      model: AppConstants.geminiProModel,
      apiKey: effectiveApiKey,
      generationConfig: GenerationConfig(
        temperature: 0.4, // 略高溫度，更有創意
        topP: 0.9,
        topK: 50,
        maxOutputTokens: 4096,
      ),
    );

    _initialized = true;
  }

  /// 動態創建模型（支援不同的模型選擇）
  GenerativeModel _createModel(String modelName, String apiKey) {
    return GenerativeModel(
      model: modelName,
      apiKey: apiKey,
      generationConfig: GenerationConfig(
        temperature: 0.2,
        topP: 0.8,
        topK: 40,
        maxOutputTokens: 2048,
      ),
    );
  }

  // ========== Prompt 範本 ==========

  /// 範本一：從定檢表照片提取檢查項目
  String _getChecklistExtractionPrompt() {
    return '''
您是一位專業的工業巡檢 AI。請分析提供的定檢表照片。

任務指令：
1. 識別照片中所有的巡檢項目和檢查點。
2. 提取每個檢查項目的描述文字。
3. 按順序組織這些項目。
4. 忽略表頭、日期、簽名等非檢查項目內容。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 結構必須如下：
{
  "items": [
    "檢查項目1的描述",
    "檢查項目2的描述",
    ...
  ]
}

注意事項：
- 僅回傳純 JSON，不要包含任何其他文字
- 確保 items 是字符串數組
- 如果無法識別任何項目，回傳空數組 []
''';
  }

  /// 範本二：標準設備巡檢分析
  String _getStandardInspectionPrompt(String itemDescription) {
    return '''
您是一位專業的工業巡檢 AI。請分析提供的設備巡檢點圖像。

檢查項目：$itemDescription

任務指令：
1. 識別圖像中的主要設備類型 (例如：泵、閥門、壓力錶、馬達、管路、電氣設備等)。

2. **重要：仔細識別並提取所有數值類資料到 readings 物件**，包括：
   - 儀表讀數（溫度、壓力、速度、流量、電流、電壓、頻率等）
   - 物理測量值（尺寸、距離、厚度、角度等）
   - 狀態指標（百分比、計數、時間、週期等）
   - 每個數值必須獨立記錄，格式：{"欄位名稱": {"value": 數值, "unit": "單位"}}
   - 即使定檢表中沒有特別要求，只要照片中有數值，都應該提取

3. 仔細評估設備的整體狀況，重點描述任何磨損、生鏽、腐蝕、洩漏、裂縫或物理損壞的跡象。如果狀況良好，請註明「狀況良好」。

4. 根據您的評估，判斷是否存在需要關注的異常情況（is_anomaly: true/false）。

5. 如果發現異常，請詳細描述異常的特徵、位置和嚴重程度。

6. 如果圖像中包含信用卡或其他已知尺寸的參照物，並且存在需要測量的異常（如裂縫、凹陷），請嘗試估算異常特徵的真實尺寸。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 結構必須如下：
{
  "equipment_type": "string",
  "readings": {
    "溫度": {"value": 75.5, "unit": "°C"},
    "壓力": {"value": 2.5, "unit": "MPa"},
    "油位": {"value": 80, "unit": "%"}
  },
  "condition_assessment": "string",
  "is_anomaly": boolean,
  "anomaly_description": "string or null",
  "estimated_size": "string or null"
}

注意事項：
- 僅回傳純 JSON，不要包含任何其他文字、markdown 標記或程式碼區塊標記
- **積極提取所有可見的數值資料**，這對檢測報告非常重要
- condition_assessment 限制在100字內，清楚描述狀況
- 如果無儀表讀數，readings 可以是 null 或空物件 {}
- estimated_size 僅在有參照物且發現可測量異常時提供
- 信用卡標準尺寸：85.6mm × 53.98mm
- **重要：所有文字內容（equipment_type、condition_assessment、anomaly_description）必須使用繁體中文**
''';
  }

  /// 範本三：快速分析模式（無預定檢查項目）
  String _getQuickAnalysisPrompt() {
    return '''
您是一位專業的工業設備檢測 AI。請分析提供的設備圖像。

任務指令：
1. 識別圖像中的主要設備或場景類型。
2. **重要：仔細識別並提取所有數值類資料**，包括：
   - 儀表讀數（溫度、壓力、速度、電流、電壓等）
   - 物理測量值（尺寸、距離、角度等）
   - 狀態指標（百分比、次數、時間等）
   - 將每個數值獨立記錄在 readings 中
3. 評估設備狀況，識別任何異常。
4. 如果有參照物，估算異常尺寸。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 結構必須如下：
{
  "equipment_type": "string",
  "readings": {
    "溫度": {"value": 75.5, "unit": "°C"},
    "壓力": {"value": 2.5, "unit": "MPa"}
  },
  "condition_assessment": "string",
  "is_anomaly": boolean,
  "anomaly_description": "string or null",
  "estimated_size": "string or null"
}

注意事項：
- 僅回傳純 JSON，不要包含任何其他文字、markdown 標記或程式碼區塊標記
- condition_assessment 必須簡潔，限制在50字內
- 積極尋找並提取照片中所有數值資料到 readings
- 如果無儀表讀數，readings 可以是 null 或空物件 {}
- estimated_size 僅在有參照物且發現可測量異常時提供
- 信用卡標準尺寸：85.6mm × 53.98mm
- **重要：所有文字內容必須使用繁體中文**
''';
  }

  /// 範本四：高階主管摘要報告生成
  String _getReportGenerationPrompt(String recordsJson) {
    return '''
您是一位經驗豐富的工廠營運經理 AI 助理。

背景資料：
以下是一個 JSON 陣列，包含了某次設施巡檢中每個檢查點的數據。每個物件代表一個巡檢點的發現。

$recordsJson

任務指令：
請基於上述數據，生成一份專業的高階主管級巡檢摘要報告。報告應包含以下部分：

1. **總體概述** (2-3 句話)
   - 本次巡檢涵蓋的範圍（檢查了多少個點、主要設備類型）
   - 整體設備狀況的簡要評價

2. **關鍵發現** (條列式，每點 1-2 句話)
   - 列出所有被標記為異常 (is_anomaly: true) 的項目
   - 對於每個異常，說明：設備類型、異常描述、潛在影響
   - 按嚴重程度排序（最嚴重的在前）

3. **數據摘要**
   - 總檢查點數
   - 正常點數 vs 異常點數
   - 如果有儀表讀數，提及關鍵讀數的範圍或趨勢

4. **建議措施** (2-3 點)
   - 針對發現的異常，提出具體的後續行動建議
   - 優先級排序

輸出格式：
請以清晰、結構化的 Markdown 格式輸出報告，使用 ##、### 標題和項目符號列表。
語言：繁體中文。
語氣：專業、客觀、簡潔。

不要回傳 JSON，直接回傳 Markdown 格式的報告內容。
''';
  }

  // ========== API 呼叫方法 ==========

  /// 分析定檢表照片，提取檢查項目列表
  Future<List<String>> extractChecklistItems(Uint8List imageBytes) async {
    if (!_initialized) init();

    try {
      final prompt = TextPart(_getChecklistExtractionPrompt());
      final imagePart = DataPart('image/jpeg', imageBytes);

      final response = await _flashModel.generateContent([
        Content.multi([prompt, imagePart])
      ]).timeout(AppConstants.apiTimeout);

      final responseText = response.text?.trim() ?? '';
      print('Checklist extraction response: $responseText');

      // 清理響應文本（移除可能的 markdown 標記）
      String cleanedText = responseText
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final jsonData = jsonDecode(cleanedText);

      if (jsonData['items'] is List) {
        return (jsonData['items'] as List).map((e) => e.toString()).toList();
      }

      throw Exception('Invalid response format: items not found');
    } catch (e) {
      print('Error extracting checklist items: $e');
      rethrow;
    }
  }

  /// 分析單張巡檢照片
  Future<AnalysisResult> analyzeInspectionPhoto({
    required String itemId,
    required String itemDescription,
    required Uint8List imageBytes,
    required String photoPath,
  }) async {
    if (!_initialized) init();

    try {
      final prompt = TextPart(_getStandardInspectionPrompt(itemDescription));
      final imagePart = DataPart('image/jpeg', imageBytes);

      final response = await _flashModel.generateContent([
        Content.multi([prompt, imagePart])
      ]).timeout(AppConstants.apiTimeout);

      // 安全地提取回應文本
      String responseText = '';
      try {
        if (response.candidates != null && response.candidates!.isNotEmpty) {
          final candidate = response.candidates!.first;
          if (candidate.content.parts != null && candidate.content.parts!.isNotEmpty) {
            for (final part in candidate.content.parts!) {
              if (part is TextPart && part.text != null) {
                responseText += part.text;
              }
            }
          }
        }
        if (responseText.isEmpty) {
          responseText = response.text?.trim() ?? '';
        }
      } catch (e) {
        print('⚠️ Error extracting response text: $e');
        throw Exception('AI 回應格式異常，請重試');
      }

      print('Analysis response: $responseText');

      // 清理響應文本
      String cleanedText = responseText
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final jsonData = jsonDecode(cleanedText);

      return AnalysisResult.fromGeminiJson(itemId, photoPath, jsonData);
    } catch (e) {
      print('Error analyzing inspection photo: $e');
      return AnalysisResult(
        itemId: itemId,
        photoPath: photoPath,
        analysisError: e.toString(),
        status: AnalysisStatus.error,
      );
    }
  }

  /// 快速分析模式（無預定檢查項目）
  Future<AnalysisResult> quickAnalyze({
    required String itemId,
    required Uint8List imageBytes,
    required String photoPath,
  }) async {
    if (!_initialized) init();

    try {
      final prompt = TextPart(_getQuickAnalysisPrompt());
      final imagePart = DataPart('image/jpeg', imageBytes);

      print('📸 Quick analysis started for item: $itemId');

      final response = await _flashModel.generateContent([
        Content.multi([prompt, imagePart])
      ]).timeout(AppConstants.apiTimeout);

      print('✅ Quick analysis response received');

      // 安全地提取回應文本
      String responseText = '';
      try {
        // 檢查是否有候選回應
        if (response.candidates != null && response.candidates!.isNotEmpty) {
          final candidate = response.candidates!.first;
          if (candidate.content.parts != null && candidate.content.parts!.isNotEmpty) {
            // 提取所有文本部分
            for (final part in candidate.content.parts!) {
              if (part.text != null) {
                responseText += part.text!;
              }
            }
          }
        }

        // 如果沒有從 candidates 獲取到文本，嘗試使用 response.text
        if (responseText.isEmpty) {
          responseText = response.text?.trim() ?? '';
        }
      } catch (e) {
        print('⚠️ Error extracting response text: $e');
        // 如果提取失敗，返回錯誤
        throw Exception('AI 回應格式異常，請重試');
      }

      print('📝 Response length: ${responseText.length} characters');
      print('📄 Response text: $responseText');

      if (responseText.isEmpty) {
        throw Exception('AI 回應為空，請重試');
      }

      String cleanedText = responseText
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      print('🧹 Cleaned text: $cleanedText');

      final jsonData = jsonDecode(cleanedText);

      print('✅ JSON parsed successfully');

      return AnalysisResult.fromGeminiJson(itemId, photoPath, jsonData);
    } catch (e) {
      print('❌ Error in quick analysis: $e');
      print('❌ Error type: ${e.runtimeType}');
      return AnalysisResult(
        itemId: itemId,
        photoPath: photoPath,
        analysisError: '快速分析失敗：$e',
        status: AnalysisStatus.error,
      );
    }
  }

  /// 生成巡檢摘要報告（使用 Pro 模型）
  Future<String> generateSummaryReport(String recordsJson) async {
    if (!_initialized) init();

    try {
      final prompt = TextPart(_getReportGenerationPrompt(recordsJson));

      final response = await _proModel.generateContent([
        Content.text(prompt.text)
      ]).timeout(AppConstants.apiTimeout);

      // 安全地提取回應文本
      String responseText = '';
      try {
        if (response.candidates != null && response.candidates!.isNotEmpty) {
          final candidate = response.candidates!.first;
          if (candidate.content.parts != null && candidate.content.parts!.isNotEmpty) {
            for (final part in candidate.content.parts!) {
              if (part is TextPart && part.text != null) {
                responseText += part.text;
              }
            }
          }
        }
        if (responseText.isEmpty) {
          responseText = response.text?.trim() ?? '';
        }
      } catch (e) {
        print('⚠️ Error extracting response text: $e');
        return '無法生成報告：回應格式異常';
      }

      return responseText.trim().isEmpty ? '無法生成報告' : responseText.trim();
    } catch (e) {
      print('Error generating summary report: $e');
      return '報告生成失敗：$e';
    }
  }

  /// 重新分析（帶補充提示）
  Future<AnalysisResult> reanalyzeWithPrompt({
    required String itemId,
    required String itemDescription,
    required Uint8List imageBytes,
    required String photoPath,
    required String supplementalPrompt,
  }) async {
    if (!_initialized) init();

    try {
      final basePrompt = _getStandardInspectionPrompt(itemDescription);
      final fullPrompt = '''
$basePrompt

用戶補充要求：
$supplementalPrompt

請特別注意用戶的補充要求，並在分析中考慮這些指示。
''';

      final prompt = TextPart(fullPrompt);
      final imagePart = DataPart('image/jpeg', imageBytes);

      final response = await _flashModel.generateContent([
        Content.multi([prompt, imagePart])
      ]).timeout(AppConstants.apiTimeout);

      // 安全地提取回應文本
      String responseText = '';
      try {
        if (response.candidates != null && response.candidates!.isNotEmpty) {
          final candidate = response.candidates!.first;
          if (candidate.content.parts != null && candidate.content.parts!.isNotEmpty) {
            for (final part in candidate.content.parts!) {
              if (part is TextPart && part.text != null) {
                responseText += part.text;
              }
            }
          }
        }
        if (responseText.isEmpty) {
          responseText = response.text?.trim() ?? '';
        }
      } catch (e) {
        print('⚠️ Error extracting response text: $e');
        throw Exception('AI 回應格式異常，請重試');
      }

      String cleanedText = responseText
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final jsonData = jsonDecode(cleanedText);

      return AnalysisResult.fromGeminiJson(itemId, photoPath, jsonData);
    } catch (e) {
      print('Error in reanalysis: $e');
      return AnalysisResult(
        itemId: itemId,
        photoPath: photoPath,
        analysisError: e.toString(),
        status: AnalysisStatus.error,
      );
    }
  }
}

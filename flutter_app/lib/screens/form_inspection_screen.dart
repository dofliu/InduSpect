import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../models/inspection_template.dart';
import '../models/template_field.dart';
import '../models/form_inspection_record.dart';
import '../services/gemini_service.dart';
import '../services/local_template_creator.dart';
import '../services/backend_api_service.dart';
import '../services/file_save_service.dart';
import '../services/database_service.dart';
import '../services/location_service.dart';
import '../services/photo_service.dart';
import '../services/connectivity_service.dart';
import '../services/standards_engine.dart';
import '../services/image_quality_service.dart';
import '../widgets/image_quality_dialog.dart';
import '../services/meter_ocr_service.dart';
import '../services/ocr_reading_parser.dart';
import '../services/pdf_report_service.dart';
import '../screens/guided_capture_screen.dart';
import '../utils/constants.dart';

/// 表單檢測填寫模式
enum InspectionMode {
  photo, // 拍照 AI 分析模式（預設）
  manual, // 純文字手動填寫模式
}

/// 表單檢測工作流程畫面
///
/// 完整流程：
/// 1. 上傳定檢表 (Excel/Word)
/// 2. 分析表單結構
/// 3. 逐項引導拍照 → AI 分析 → 自動填入
/// 4. 預覽確認結果
/// 5. 產生填好的原始格式表單
class FormInspectionScreen extends StatefulWidget {
  const FormInspectionScreen({super.key});

  @override
  State<FormInspectionScreen> createState() => _FormInspectionScreenState();
}

enum FormInspectionStep {
  uploadForm, // Step 1: 上傳定檢表
  inspecting, // Step 2: 逐項檢測 (拍照或手動)
  preview, // Step 3: 預覽結果
  exporting, // Step 4: 產生表單
  done, // 完成
}

/// 單一檢測項目的狀態
class InspectionItemState {
  final String fieldId;
  final String label;
  final String fieldType;
  String? photoPath;
  Uint8List? photoBytes;
  Map<String, dynamic>? aiResult;
  String? manualValue;
  bool isCompleted;
  bool isAnalyzing;
  // 法規標準判定結果（後端 judge-readings 回傳）：
  // {judgment: pass/fail/warning/unknown, standard_text, regulation, converted_value, converted_unit, ...}
  Map<String, dynamic>? standardJudgment;
  // 離線或判定失敗時標記為「待判定」，恢復網路後可重新判定
  bool standardJudgmentPending;
  // 每個項目持有自己的 controller，避免 build 時重建導致游標跳位
  late final TextEditingController manualController;

  InspectionItemState({
    required this.fieldId,
    required this.label,
    required this.fieldType,
    this.photoPath,
    this.photoBytes,
    this.aiResult,
    this.manualValue,
    this.isCompleted = false,
    this.isAnalyzing = false,
    this.standardJudgment,
    this.standardJudgmentPending = false,
  }) {
    manualController = TextEditingController(text: manualValue ?? '');
  }

  /// 取得此項目的填入值（AI 結果或手動填入）
  String? get displayValue {
    if (aiResult != null) {
      final condition = aiResult!['condition_assessment'] as String?;
      final isAnomaly = aiResult!['is_anomaly'] as bool?;
      if (isAnomaly == true) {
        return '異常: ${aiResult!['anomaly_description'] ?? condition ?? ''}';
      }
      return condition ?? '正常';
    }
    return manualValue;
  }

  /// 法規標準的判定碼（pass/fail/warning/unknown），無判定時回傳 null
  String? get judgmentCode {
    final code = standardJudgment?['judgment'] as String?;
    if (code == null || code == 'unknown') return null;
    return code;
  }

  /// 法規依據文字（標準 + 法規名稱），供前端透明顯示判定來源
  String? get standardBasis {
    if (standardJudgment == null) return null;
    final std = (standardJudgment!['standard_text'] as String?)?.trim() ?? '';
    if (std.isEmpty) return null;
    final reg = (standardJudgment!['regulation'] as String?)?.trim() ?? '';
    return reg.isEmpty ? '標準 $std' : '標準 $std（$reg）';
  }

  /// 單位換算說明（原始讀數 → 換算成標準單位），無換算時回傳 null
  String? get conversionNote {
    final cv = standardJudgment?['converted_value'];
    if (cv == null) return null;
    final cu = standardJudgment?['converted_unit'] ?? '';
    final mv = standardJudgment?['measured_value'];
    final mu = standardJudgment?['unit'] ?? '';
    return '換算: $mv$mu → $cv$cu';
  }

  /// 取得此項目的判定結果
  ///
  /// 量測欄位若已取得法規標準判定，以標準判定為準（合格/不合格/警告）；
  /// 離線待判定時顯示「待判定」；否則落回 AI 異常判定或手動填寫狀態。
  String get verdict {
    switch (judgmentCode) {
      case 'pass':
        return '合格';
      case 'fail':
        return '不合格';
      case 'warning':
        return '警告';
    }
    if (standardJudgmentPending) {
      return '待判定';
    }
    if (aiResult != null) {
      return (aiResult!['is_anomaly'] == true) ? '不合格' : '合格';
    }
    if (manualValue != null && manualValue!.isNotEmpty) {
      return '已填寫';
    }
    return '未檢測';
  }
}

/// 依判定結果回傳對應顏色（不合格紅、警告橘、待判定灰、其餘綠）
Color verdictColor(String verdict) {
  switch (verdict) {
    case '不合格':
      return Colors.red;
    case '警告':
      return Colors.orange;
    case '待判定':
    case '未檢測':
      return Colors.grey;
    default:
      return Colors.green;
  }
}

class _FormInspectionScreenState extends State<FormInspectionScreen> {
  FormInspectionStep _currentStep = FormInspectionStep.uploadForm;
  InspectionMode _mode = InspectionMode.photo;

  // 上傳的原始檔案
  PlatformFile? _uploadedFile;
  String? _fileName;

  // 分析出的結構
  Map<String, dynamic>? _templateJson;
  InspectionTemplate? _template;

  // 檢測項目狀態
  List<InspectionItemState> _inspectionItems = [];

  // 所有填寫的資料 (fieldId -> value)
  final Map<String, dynamic> _filledData = {};

  // AI 摘要報告
  String? _summaryReport;
  bool _isGeneratingReport = false;
  bool _isExportingPdf = false;

  // 持久化 & GPS
  final DatabaseService _dbService = DatabaseService();
  FormInspectionRecord? _currentRecord;
  String _inspectionTitle = '';
  final TextEditingController _titleController = TextEditingController();
  LocationData? _locationData;
  bool _isLocating = false;

  // 匯出的文件路徑（用於分享）
  String? _exportedFilePath;

  // 服務
  final ImagePicker _imagePicker = ImagePicker();
  GeminiService? _geminiService;
  final BackendApiService _backendApi = BackendApiService();

  bool _isLoading = false;
  String? _errorMessage;

  // 法規標準判定進行中
  bool _isJudging = false;

  // 批次分析進度追蹤
  bool _isBatchAnalyzing = false;
  int _batchTotal = 0;
  int _batchCompleted = 0;
  int _batchErrors = 0;
  String _batchCurrentItem = '';
  bool _autoReportTriggered = false;

  @override
  void initState() {
    super.initState();
    _initGemini();
  }

  @override
  void dispose() {
    _titleController.dispose();
    // 釋放所有檢測項目的 controller
    for (final item in _inspectionItems) {
      item.manualController.dispose();
    }
    super.dispose();
  }

  void _initGemini() {
    try {
      _geminiService = GeminiService();
      _geminiService!.init();
    } catch (e) {
      debugPrint('Gemini 初始化失敗: $e (可使用手動模式)');
      _geminiService = null;
    }
  }

  // ========== Step 1: 上傳表單 ==========

  Future<void> _pickAndAnalyzeForm() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls', 'docx'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);

    if (bytes == null) {
      _showError('無法讀取檔案內容');
      return;
    }

    setState(() {
      _uploadedFile = file;
      _fileName = file.name;
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 嘗試後端分析，失敗則本地分析
      Map<String, dynamic> response;
      try {
        final api = BackendApiService();
        response = await api.createTemplateFromFile(
          file: file,
          templateName: file.name.replaceAll(RegExp(r'\.(xlsx|xls|docx)$'), ''),
        );
      } catch (_) {
        response = {'success': false};
      }

      if (response['success'] != true) {
        // 後端不可用 → 本地解析備援。明確告知使用者（AI 欄位分類與原格式回填品質可能較低）
        _showNotice(BackendApiService().isExplicitlyConfigured
            ? '後端無法連線，已改用本機解析表單（匯出時可能無法回填原始格式）'
            : '尚未設定後端位址（BACKEND_API_URL），已改用本機解析表單（匯出時可能無法回填原始格式）');
        final localCreator = LocalTemplateCreator();
        response = await localCreator.createTemplateFromBytes(
          bytes: bytes,
          fileName: file.name,
          templateName: file.name.replaceAll(RegExp(r'\.(xlsx|xls|docx)$'), ''),
        );
      }

      if (response['success'] != true) {
        _showError('分析表單失敗：${response['error'] ?? '未知錯誤'}');
        return;
      }

      _templateJson = response['template'] as Map<String, dynamic>;
      _template = InspectionTemplate.fromJson(_templateJson!);

      // 從模板建立檢測項目列表
      _buildInspectionItems();

      // 產生預設標題
      final now = DateTime.now();
      final dateStr = DateFormat('MM/dd HH:mm').format(now);
      final baseName = _fileName?.replaceAll(RegExp(r'\.\w+$'), '') ?? '檢測';
      _inspectionTitle = '$baseName - $dateStr';
      _titleController.text = _inspectionTitle;

      // 開始 GPS 定位（背景執行，不阻塞）
      _captureLocation();

      setState(() {
        _isLoading = false;
        _currentStep = FormInspectionStep.inspecting;
      });

      // 建立 draft 記錄存入 SQLite
      await _createDraftRecord();
    } catch (e) {
      _showError('分析表單時發生錯誤: $e');
    }
  }

  /// 從模板建立需要檢測的項目列表
  void _buildInspectionItems() {
    _inspectionItems = [];

    for (final section in _template!.sections) {
      for (final field in section.fields) {
        // 跳過照片欄位和簽名欄位（這些不是要檢測的項目）
        if (field.fieldType == FieldType.photo ||
            field.fieldType == FieldType.photoMultiple ||
            field.fieldType == FieldType.signature) {
          continue;
        }

        _inspectionItems.add(InspectionItemState(
          fieldId: field.fieldId,
          label: field.label,
          fieldType: field.fieldType.toString().split('.').last,
        ));
      }
    }
  }

  // ========== GPS & 持久化 ==========

  /// 背景擷取 GPS 位置，完成後回寫 draft 紀錄
  Future<void> _captureLocation() async {
    setState(() => _isLocating = true);
    try {
      _locationData = await LocationService().getCurrentPosition();
      // GPS 完成後更新已建立的 draft 紀錄
      if (_locationData != null && _currentRecord != null) {
        _currentRecord = _currentRecord!.copyWith(
          latitude: _locationData!.latitude,
          longitude: _locationData!.longitude,
          locationName: _locationData!.locationName,
        );
        await _dbService.saveFormRecord(_currentRecord!);
      }
    } catch (_) {}
    if (mounted) setState(() => _isLocating = false);
  }

  /// 建立 draft 記錄
  Future<void> _createDraftRecord() async {
    final record = FormInspectionRecord(
      recordId: const Uuid().v4(),
      title: _inspectionTitle,
      sourceFileName: _fileName,
      templateJson: _templateJson != null ? jsonEncode(_templateJson) : null,
      filledData: Map.from(_filledData),
      status: FormRecordStatus.draft,
      latitude: _locationData?.latitude,
      longitude: _locationData?.longitude,
      locationName: _locationData?.locationName,
    );

    final id = await _dbService.saveFormRecord(record);
    _currentRecord = record.copyWith(id: id);
  }

  /// 儲存目前進度到 SQLite
  Future<void> _saveDraft() async {
    if (_currentRecord == null) return;

    // 收集 AI 結果與法規判定（判定為稽核依據，隨紀錄持久化 — Issue #44）
    final aiResults = <String, dynamic>{};
    final standardJudgments = <String, dynamic>{};
    final photoPaths = <String>[];
    for (final item in _inspectionItems) {
      if (item.aiResult != null) aiResults[item.fieldId] = item.aiResult;
      if (item.standardJudgment != null) {
        standardJudgments[item.fieldId] = item.standardJudgment;
      }
      if (item.photoPath != null) photoPaths.add(item.photoPath!);
    }

    _currentRecord = _currentRecord!.copyWith(
      title: _inspectionTitle,
      filledData: Map.from(_filledData),
      aiResults: aiResults,
      standardJudgments: standardJudgments,
      photoPaths: photoPaths,
      latitude: _locationData?.latitude ?? _currentRecord!.latitude,
      longitude: _locationData?.longitude ?? _currentRecord!.longitude,
      locationName: _locationData?.locationName ?? _currentRecord!.locationName,
    );

    await _dbService.saveFormRecord(_currentRecord!);
  }

  // ========== GuidedCapture 整合 ==========

  /// 批次 AI 並行分析上限（Issue #14：避免 OOM）
  static const int _maxConcurrentAnalysis = 3;

  /// 啟動批次引導式拍照
  Future<void> _launchGuidedCapture() async {
    // 將 inspectionItems 轉為 photoTasks 格式
    final photoTasks = <Map<String, dynamic>>[];
    for (int i = 0; i < _inspectionItems.length; i++) {
      final item = _inspectionItems[i];
      if (item.isCompleted) continue; // 跳過已完成的
      photoTasks.add({
        'task_id': item.fieldId,
        'display_name': item.label,
        'photo_hint': _getSmartPhotoHint(item.label, item.fieldType),
        'field_name': item.label,
        'field_type': item.fieldType,
        'sequence': i + 1,
      });
    }

    if (photoTasks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('所有項目已完成，無需拍照')),
        );
      }
      return;
    }

    final bindings = await Navigator.push<List<PhotoBinding>>(
      context,
      MaterialPageRoute(
        builder: (_) => GuidedCaptureScreen(
          photoTasks: photoTasks,
          equipmentName: _template?.templateName ?? '',
          allowSkip: true,
        ),
      ),
    );

    if (bindings == null || bindings.isEmpty) return;

    // 啟動批次分析進度追蹤
    setState(() {
      _isBatchAnalyzing = true;
      _batchTotal = bindings.length;
      _batchCompleted = 0;
      _batchErrors = 0;
      _batchCurrentItem = '';
    });

    // Issue #14: 使用 concurrency limit 控制並行分析數量
    final futures = <Future<void>>[];
    int running = 0;

    for (final binding in bindings) {
      final index = _inspectionItems.indexWhere((i) => i.fieldId == binding.taskId);
      if (index < 0) {
        if (mounted) setState(() => _batchCompleted++);
        continue;
      }

      final item = _inspectionItems[index];
      final imageBytes = binding.photoBytes ?? await File(binding.filePath).readAsBytes();

      setState(() {
        item.photoPath = binding.filePath;
        item.photoBytes = imageBytes;
        item.isAnalyzing = true;
        _batchCurrentItem = item.label;
      });

      // 控制並行數量：等待直到有空位
      if (running >= _maxConcurrentAnalysis) {
        await Future.any(futures);
      }

      running++;
      final future = _runAIAnalysis(item, imageBytes, binding.filePath).whenComplete(() {
        running--;
        if (mounted) {
          setState(() {
            _batchCompleted++;
            if (!item.isCompleted) _batchErrors++;
          });
        }
      });
      futures.add(future);
    }

    // 等待所有分析完成
    await Future.wait(futures);

    if (mounted) {
      setState(() => _isBatchAnalyzing = false);
    }

    // 批次分析完成後，對量測欄位執行法規標準判定（自動帶出合格/不合格/警告）
    await _runStandardJudgment();
  }

  /// 一鍵自動檢測：引導拍照 → 批次 AI 分析 → 自動進入預覽
  Future<void> _startAutoInspection() async {
    await _launchGuidedCapture();

    if (_completedCount > 0 && mounted) {
      setState(() => _currentStep = FormInspectionStep.preview);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('自動檢測完成！已完成 $_completedCount/${_inspectionItems.length} 項，請確認結果'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 根據欄位名稱和類型產生智慧拍照提示
  String _getSmartPhotoHint(String label, String fieldType) {
    final lower = label.toLowerCase();
    if (lower.contains('溫度') || lower.contains('temperature')) {
      return '請正面拍攝溫度計或溫度顯示器，確保數值清晰可讀';
    }
    if (lower.contains('壓力') || lower.contains('pressure')) {
      return '請正面拍攝壓力錶，確保指針位置和刻度清晰可見';
    }
    if (lower.contains('電壓') || lower.contains('voltage') ||
        lower.contains('電流') || lower.contains('current')) {
      return '請拍攝電氣儀表面板，確保所有讀數清晰可見';
    }
    if (lower.contains('絕緣') || lower.contains('insulation')) {
      return '請拍攝絕緣電阻測試結果，確保數值和單位清晰';
    }
    if (lower.contains('外觀') || lower.contains('appearance')) {
      return '請拍攝設備整體外觀，注意是否有裂痕、鏽蝕、漏油等異常';
    }
    if (lower.contains('漏') || lower.contains('leak') || lower.contains('洩漏')) {
      return '請拍攝可能滲漏的位置，包含接頭、密封處和地面痕跡';
    }
    if (lower.contains('振動') || lower.contains('vibration')) {
      return '請拍攝振動監測器讀數或設備運轉狀態';
    }
    if (lower.contains('油') || lower.contains('oil') || lower.contains('潤滑')) {
      return '請拍攝油位視窗或油品顏色，確認油位高度';
    }
    if (lower.contains('噪音') || lower.contains('noise') || lower.contains('聲音')) {
      return '請拍攝設備運轉狀態，並在備註中描述異常聲響';
    }
    if (lower.contains('鏽') || lower.contains('腐蝕') || lower.contains('corrosion')) {
      return '請近距離拍攝鏽蝕或腐蝕區域，可放置信用卡作為尺寸參照';
    }
    if (fieldType == 'number' || fieldType == 'measurement') {
      return '請拍攝「$label」的儀表或量測設備，確保讀數清晰';
    }
    if (fieldType == 'radio') {
      return '請拍攝「$label」的實際狀態，AI 將自動判定合格/不合格';
    }
    return '請拍攝「$label」的照片，確保光線充足、畫面清晰';
  }

  // ========== Step 2: 逐項檢測 ==========

  /// 拍照並 AI 分析當前項目
  Future<void> _captureAndAnalyze(int index) async {
    final item = _inspectionItems[index];

    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1920,
      maxHeight: 1080,
      imageQuality: 85,
    );

    if (image == null) return;

    final imageBytes = await image.readAsBytes();

    // 品質閘門：不合格先問要不要重拍（純本機判斷，離線同樣有效）
    if (!await _passesQualityGate(imageBytes)) return _captureAndAnalyze(index);

    setState(() {
      item.photoPath = image.path;
      item.photoBytes = imageBytes;
      item.isAnalyzing = true;
    });

    await _runAIAnalysis(item, imageBytes, image.path);
    if (item.isCompleted) await _runStandardJudgment(onlyItem: item);
  }

  /// 拍照品質閘門：回傳 false 代表使用者選擇重拍
  Future<bool> _passesQualityGate(Uint8List bytes) async {
    final quality = await ImageQualityService.assess(bytes);
    if (quality.isAcceptable || !mounted) return true;
    final retake = await showImageQualityWarning(context, quality);
    return !retake;
  }

  /// 從相簿選取照片
  Future<void> _pickFromGallery(int index) async {
    final item = _inspectionItems[index];

    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1080,
      imageQuality: 85,
    );

    if (image == null) return;

    final imageBytes = await image.readAsBytes();

    if (!await _passesQualityGate(imageBytes)) return _pickFromGallery(index);

    setState(() {
      item.photoPath = image.path;
      item.photoBytes = imageBytes;
      item.isAnalyzing = true;
    });

    await _runAIAnalysis(item, imageBytes, image.path);
    if (item.isCompleted) await _runStandardJudgment(onlyItem: item);
  }

  /// 執行 AI 分析並更新項目狀態
  Future<void> _runAIAnalysis(
    InspectionItemState item,
    Uint8List imageBytes,
    String photoPath,
  ) async {
    if (_geminiService != null) {
      // 先確認「真的」連得到網路：廠區常見連上 AP 卻沒有 uplink，
      // 只看介面狀態會讓每張照片都空等 Gemini 逾時（60 秒 × N 張）。
      // 探測不通就直接走裝置端 OCR 備援。
      if (!await ConnectivityService().checkConnection()) {
        final ocrHandled = await _tryOcrFallback(item, photoPath);
        if (mounted) setState(() => item.isAnalyzing = false);
        if (!ocrHandled) {
          _pendingAnalysisErrors.add(item.label);
          _debouncedShowAnalysisErrors();
        }
        return;
      }

      try {
        final analysisResult = await _geminiService!.analyzeInspectionPhoto(
          itemId: item.fieldId,
          itemDescription: item.label,
          imageBytes: imageBytes,
          photoPath: photoPath,
        );

        if (analysisResult.status == AnalysisStatus.error) {
          throw Exception(analysisResult.analysisError ?? 'AI 分析失敗');
        }

        // 將 AnalysisResult 轉為 Map 供顯示和映射使用
        final resultMap = <String, dynamic>{
          'equipment_type': analysisResult.equipmentType,
          'readings': analysisResult.readings,
          'condition_assessment': analysisResult.conditionAssessment,
          'is_anomaly': analysisResult.isAnomaly,
          'anomaly_description': analysisResult.anomalyDescription,
          'estimated_size': analysisResult.aiEstimatedSize,
        };

        setState(() {
          item.aiResult = resultMap;
          item.isAnalyzing = false;
          item.isCompleted = true;
          _mapAIResultToField(item, resultMap);
        });

        // 自動存檔
        _saveDraft();
      } catch (e) {
        debugPrint('AI 分析失敗: $e');
        // Tier 1a：AI 不可用（多為離線）→ 裝置端 OCR 讀值備援（數位錶/銘牌）
        final ocrHandled = await _tryOcrFallback(item, photoPath);
        setState(() {
          item.isAnalyzing = false;
        });
        if (!ocrHandled) {
          // Issue #15: 收集錯誤，避免 SnackBar 連續彈出
          _pendingAnalysisErrors.add(item.label);
          _debouncedShowAnalysisErrors();
        }
      }
    } else {
      setState(() {
        item.isAnalyzing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI 服務未初始化，請手動填寫'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  /// Tier 1a：AI 不可用時的裝置端 OCR 讀值備援（數位錶/銘牌）。
  ///
  /// 成功抽到讀值 → 合成標記 source=ocr 的最小 aiResult（readings 為真實
  /// OCR 讀值），下游的欄位映射、Tier 0 判定與持久化全部照常生效；
  /// 抽不到或 OCR 不可用 → 回傳 false，走原本的失敗提示路徑。
  Future<bool> _tryOcrFallback(InspectionItemState item, String photoPath) async {
    try {
      final text = await MeterOcrService().recognizeText(photoPath);
      if (text == null || text.trim().isEmpty) return false;

      // 期望單位：從欄位對應的法規標準推測（找不到就不設限）
      final expectedUnit = (await StandardsEngine.load())
          .findMatchingStandard(item.label)?['unit'] as String?;
      final reading =
          OcrReadingParser.bestReading(text, expectedUnit: expectedUnit);
      if (reading == null) return false;

      final resultMap = <String, dynamic>{
        'equipment_type': '',
        'readings': {
          item.label: {'value': reading.value, 'unit': reading.unit},
        },
        'condition_assessment': '裝置端 OCR 讀值（離線初判），請人工確認',
        'is_anomaly': false,
        'anomaly_description': null,
        'estimated_size': null,
        'source': 'ocr',
      };

      setState(() {
        item.aiResult = resultMap;
        item.isCompleted = true;
        _mapAIResultToField(item, resultMap);
      });
      _saveDraft();
      _showNotice('離線：以裝置端 OCR 讀得「${reading.display}」（${item.label}），請確認讀值',
          color: Colors.blueGrey);
      return true;
    } catch (e) {
      debugPrint('OCR 備援失敗: $e');
      return false;
    }
  }

  // Issue #15: 彙整 AI 錯誤訊息，避免 SnackBar 連續彈出
  final List<String> _pendingAnalysisErrors = [];
  Timer? _errorDebounceTimer;

  void _debouncedShowAnalysisErrors() {
    _errorDebounceTimer?.cancel();
    _errorDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted || _pendingAnalysisErrors.isEmpty) return;
      final count = _pendingAnalysisErrors.length;
      final names = _pendingAnalysisErrors.take(3).join('、');
      final suffix = count > 3 ? ' 等 $count 項' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('AI 分析失敗：$names$suffix\n請嘗試手動填寫'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 4),
        ),
      );
      _pendingAnalysisErrors.clear();
    });
  }

  /// 將 AI 分析結果映射到表單欄位
  void _mapAIResultToField(InspectionItemState item, Map<String, dynamic> result) {
    final fieldId = item.fieldId;

    // 根據欄位類型映射
    if (item.fieldType == 'radio') {
      // 判定欄位：合格/不合格
      final isAnomaly = result['is_anomaly'] as bool? ?? false;
      _filledData[fieldId] = isAnomaly ? 'fail' : 'pass';
    } else if (item.fieldType == 'number' || item.fieldType == 'measurement') {
      // 量測欄位：嘗試從 readings 中提取
      final readings = result['readings'] as Map<String, dynamic>?;
      if (readings != null && readings.isNotEmpty) {
        // 找到最匹配的讀數
        final bestMatch = _findBestReadingMatch(item.label, readings);
        if (bestMatch != null) {
          _filledData[fieldId] = bestMatch['value'];
        }
      }
    } else {
      // 文字欄位：使用狀況評估
      final condition = result['condition_assessment'] as String?;
      if (condition != null) {
        _filledData[fieldId] = condition;
      }
    }
  }

  /// 從 AI readings 中找到最匹配的讀數
  Map<String, dynamic>? _findBestReadingMatch(
    String fieldLabel,
    Map<String, dynamic> readings,
  ) {
    // 完全匹配
    for (final entry in readings.entries) {
      if (fieldLabel.contains(entry.key) || entry.key.contains(fieldLabel)) {
        if (entry.value is Map) {
          return Map<String, dynamic>.from(entry.value as Map);
        }
      }
    }

    // 關鍵字匹配
    final keywords = {
      '溫度': ['溫度', 'temperature', '°C'],
      '電壓': ['電壓', 'voltage', 'V'],
      '電流': ['電流', 'current', 'A'],
      '壓力': ['壓力', 'pressure', 'MPa', 'kPa'],
      '絕緣': ['絕緣', 'insulation', 'MΩ'],
      '頻率': ['頻率', 'frequency', 'Hz'],
      '轉速': ['轉速', 'rpm'],
    };

    for (final entry in readings.entries) {
      for (final kwEntry in keywords.entries) {
        final kwList = kwEntry.value;
        if (kwList.any((kw) => fieldLabel.contains(kw) || entry.key.contains(kw))) {
          if (entry.value is Map) {
            return Map<String, dynamic>.from(entry.value as Map);
          }
        }
      }
    }

    // 如果只有一個讀數，直接使用
    if (readings.length == 1) {
      final val = readings.values.first;
      if (val is Map) return Map<String, dynamic>.from(val);
    }

    return null;
  }

  /// 從項目的 AI 結果中萃取可供法規判定的數值讀數
  ///
  /// 回傳 {'value': double, 'unit': String}；若無數值讀數則回傳 null。
  Map<String, dynamic>? _extractNumericReading(InspectionItemState item) {
    final result = item.aiResult;
    if (result == null) return null;
    final readings = result['readings'];
    if (readings is! Map || readings.isEmpty) return null;

    final best = _findBestReadingMatch(
      item.label,
      Map<String, dynamic>.from(readings),
    );
    if (best == null) return null;

    final num? value = _toNum(best['value']);
    if (value == null) return null;

    return {'value': value.toDouble(), 'unit': (best['unit'] ?? '').toString()};
  }

  /// 寬鬆數值轉換：接受 num 或可解析的字串（去除非數字字元）
  num? _toNum(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw;
    final str = raw.toString();
    final parsed = num.tryParse(str);
    if (parsed != null) return parsed;
    // 字串可能夾帶單位（例："52.3 MΩ"），抽取第一個數字
    final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(str);
    if (match != null) return num.tryParse(match.group(0)!);
    return null;
  }

  /// 法規標準判定：將量測類項目的 AI 讀數送後端依法規標準自動判定
  ///
  /// 用於「一鍵自動檢測」批次分析後與單項分析後，為量測欄位帶出
  /// 合格/不合格/警告與法規依據（後端判定前會自動換算單位）。
  /// 離線或失敗時，相關項目標記為「待判定」（standardJudgmentPending）。
  ///
  /// [onlyItem] 不為 null 時僅判定該項目，否則判定所有含數值讀數的項目。
  Future<void> _runStandardJudgment({InspectionItemState? onlyItem}) async {
    final source = onlyItem != null ? [onlyItem] : _inspectionItems;

    final readings = <Map<String, dynamic>>[];
    final targets = <InspectionItemState>[];
    String equipmentType = '';

    for (final item in source) {
      if (item.aiResult == null) continue;
      if (equipmentType.isEmpty) {
        final et = item.aiResult!['equipment_type'] as String?;
        if (et != null && et.isNotEmpty) equipmentType = et;
      }
      final reading = _extractNumericReading(item);
      if (reading == null) continue;
      readings.add({
        'field_name': item.label,
        'value': reading['value'],
        'unit': reading['unit'],
      });
      targets.add(item);
    }

    if (readings.isEmpty) return;

    if (mounted) setState(() => _isJudging = true);
    try {
      final result = await _backendApi.judgeReadings(
        readings: readings,
        equipmentType: equipmentType,
      );

      if (result['success'] == true && result['judgments'] is List) {
        final judgments = (result['judgments'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        // 後端保證 judgments 與輸入 readings 同序
        for (int i = 0; i < targets.length && i < judgments.length; i++) {
          targets[i].standardJudgment = judgments[i];
          targets[i].standardJudgmentPending = false;
        }
        _saveDraft();
      } else {
        // 離線或後端失敗 → Tier 0 本地判定引擎（內建法規標準庫），
        // 僅在本地引擎也失敗時才標記「待判定」
        await _applyLocalJudgment(
          targets,
          readings,
          equipmentType,
          offline: result['error'] == 'offline',
        );
      }
    } catch (e) {
      debugPrint('標準判定失敗: $e');
      await _applyLocalJudgment(targets, readings, equipmentType, offline: false);
    } finally {
      if (mounted) setState(() => _isJudging = false);
    }
  }

  /// Tier 0 離線判定：後端不可用時以內建法規標準庫（StandardsEngine）判定。
  /// 判定結果帶 source=local 供稽核區別；本地引擎也失敗時退回「待判定」。
  Future<void> _applyLocalJudgment(
    List<InspectionItemState> targets,
    List<Map<String, dynamic>> readings,
    String equipmentType, {
    required bool offline,
  }) async {
    try {
      final engine = await StandardsEngine.load();
      final result =
          engine.judgeReadingsLocally(readings, equipmentType: equipmentType);
      final judgments = (result['judgments'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      // 引擎保證 judgments 與輸入 readings 同序
      for (int i = 0; i < targets.length && i < judgments.length; i++) {
        targets[i].standardJudgment = judgments[i];
        targets[i].standardJudgmentPending = false;
      }
      _saveDraft();
      _showNotice(
        offline
            ? '目前離線，已使用內建法規標準庫（${engine.version}）完成判定'
            : '後端判定失敗，已使用內建法規標準庫（${engine.version}）完成判定',
        color: Colors.blueGrey,
      );
    } catch (e) {
      // 本地引擎失敗（asset 缺失等）→ 維持原本的「待判定」補償路徑
      debugPrint('本地標準判定失敗: $e');
      for (final item in targets) {
        if (item.standardJudgment == null) {
          item.standardJudgmentPending = true;
        }
      }
      if (offline) {
        _showNotice('目前離線，量測項目標記為「待判定」，恢復網路後可重新判定');
      }
    }
  }

  /// 手動填寫欄位值
  void _setManualValue(int index, String value) {
    setState(() {
      final item = _inspectionItems[index];
      item.manualValue = value;
      item.isCompleted = value.isNotEmpty;
      _filledData[item.fieldId] = value;
    });
    _saveDraft();
  }

  // ========== Step 3: 預覽 ==========

  void _goToPreview() {
    setState(() {
      _currentStep = FormInspectionStep.preview;
    });
  }

  // ========== Step 4: 匯出 ==========

  Future<void> _exportFilledForm() async {
    setState(() {
      _currentStep = FormInspectionStep.exporting;
      _isLoading = true;
    });

    try {
      // 嘗試透過後端回填原始文件
      if (_uploadedFile != null) {
        try {
          final api = BackendApiService();

          // Step 1: 分析結構
          final structureResult = await api.analyzeFileStructure(_uploadedFile!);

          if (structureResult['success'] == true) {
            final fieldMap = List<Map<String, dynamic>>.from(
              structureResult['field_map'] ?? [],
            );

            // Step 2: 映射欄位
            final inspectionResults = _inspectionItems
                .where((item) => item.isCompleted)
                .map((item) => <String, dynamic>{
                      'field_label': item.label,
                      'value': _filledData[item.fieldId],
                      'ai_result': item.aiResult,
                    })
                .toList();

            final mapResult = await api.mapFieldsWithAI(
              fieldMap: fieldMap,
              inspectionResults: inspectionResults,
            );

            if (mapResult['success'] == true) {
              final mappings = List<Map<String, dynamic>>.from(
                mapResult['mappings'] ?? [],
              );
              final fillValues = mappings
                  .map((m) => <String, dynamic>{
                        'field_id': m['field_id'],
                        'value': m['suggested_value'] ?? '',
                      })
                  .toList();

              // Step 3: 執行回填
              final filledBytes = await api.executeAutoFill(
                file: _uploadedFile!,
                fieldMap: fieldMap,
                fillValues: fillValues,
              );

              if (filledBytes != null) {
                // Issue #18: 使用 app 文件目錄代替 systemTemp，避免被 OS 清除
                final appDir = await getApplicationDocumentsDirectory();
                final dir = Directory('${appDir.path}/induspect_exports');
                if (!await dir.exists()) await dir.create(recursive: true);
                final outputPath = '${dir.path}/filled_$_fileName';
                await File(outputPath).writeAsBytes(filledBytes);
                _exportedFilePath = outputPath;

                // 更新資料庫
                await _updateRecordAsExported();

                setState(() {
                  _isLoading = false;
                  _currentStep = FormInspectionStep.done;
                });
                return;
              }
            }
          }
        } catch (e) {
          debugPrint('後端回填失敗，使用本地匯出: $e');
        }
        // 走到這裡表示原格式回填未完成（離線、後端錯誤或映射失敗）— 明確告知，不無聲降級
        _showNotice('無法回填原始表格格式（後端不可用或回填失敗），將改匯出 JSON 檢測摘要');
      }

      // 後端不可用時，匯出為 JSON 摘要
      _exportedFilePath = await _exportAsJsonSummary();

      // 更新資料庫
      await _updateRecordAsExported();

      setState(() {
        _isLoading = false;
        _currentStep = FormInspectionStep.done;
      });
    } catch (e) {
      _showError('匯出失敗: $e');
    }
  }

  /// 更新紀錄為已匯出
  Future<void> _updateRecordAsExported() async {
    if (_currentRecord == null) return;
    _currentRecord = _currentRecord!.copyWith(
      status: FormRecordStatus.exported,
      filledDocumentPath: _exportedFilePath,
      summaryReport: _summaryReport,
    );
    await _dbService.saveFormRecord(_currentRecord!);
  }

  /// 匯出為 JSON 摘要檔案，回傳檔案路徑
  Future<String?> _exportAsJsonSummary() async {
    final summary = {
      'inspection_date': DateTime.now().toIso8601String(),
      'source_file': _fileName,
      'template_name': _template?.templateName ?? '',
      'mode': _mode.name,
      'total_items': _inspectionItems.length,
      'completed_items': _inspectionItems.where((i) => i.isCompleted).length,
      'results': _inspectionItems.map((item) {
        return {
          'field_id': item.fieldId,
          'label': item.label,
          'value': _filledData[item.fieldId],
          'verdict': item.verdict,
          'standard_judgment': item.standardJudgment,
          'standard_basis': item.standardBasis,
          'has_photo': item.photoPath != null,
          'ai_result': item.aiResult,
        };
      }).toList(),
    };

    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(summary),
    );

    final outputName = '${_fileName?.replaceAll(RegExp(r'\.\w+$'), '')}_inspection_result.json';

    // Issue #18: 使用 app 文件目錄，避免被 OS 清除
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/induspect_exports');
    if (!await dir.exists()) await dir.create(recursive: true);
    final outputPath = '${dir.path}/$outputName';
    await File(outputPath).writeAsBytes(jsonBytes);
    return outputPath;
  }

  // ========== AI 摘要報告 ==========

  /// 產生 AI 總結報告
  Future<void> _generateSummaryReport() async {
    if (_geminiService == null) {
      setState(() {
        _summaryReport = '⚠️ AI 服務未初始化，無法產生摘要報告。';
      });
      return;
    }

    setState(() {
      _isGeneratingReport = true;
    });

    try {
      // 將檢測結果轉為 JSON 供 AI 分析
      final recordsData = _inspectionItems
          .where((item) => item.isCompleted)
          .map((item) => {
                'item_description': item.label,
                'field_type': item.fieldType,
                'value': _filledData[item.fieldId],
                'equipment_type': item.aiResult?['equipment_type'] ?? '',
                'condition_assessment': item.aiResult?['condition_assessment'] ?? item.manualValue ?? '',
                'is_anomaly': item.aiResult?['is_anomaly'] ?? false,
                'anomaly_description': item.aiResult?['anomaly_description'] ?? '',
                'readings': item.aiResult?['readings'] ?? {},
                'verdict': item.verdict,
                'standard_basis': item.standardBasis ?? '',
              })
          .toList();

      final recordsJson = const JsonEncoder.withIndent('  ').convert(recordsData);
      final report = await _geminiService!.generateSummaryReport(recordsJson);

      setState(() {
        _summaryReport = report;
        _isGeneratingReport = false;
      });

      // 存入資料庫
      if (_currentRecord != null) {
        _currentRecord = _currentRecord!.copyWith(summaryReport: report);
        await _dbService.saveFormRecord(_currentRecord!);
      }
    } catch (e) {
      setState(() {
        _summaryReport = '報告生成失敗：$e';
        _isGeneratingReport = false;
      });
    }
  }

  // ========== UI 工具方法 ==========

  void _showError(String message) {
    setState(() {
      _isLoading = false;
      _errorMessage = message;
    });
  }

  /// 非致命提示（降級、備援路徑）— 讓使用者知道系統走了替代方案，而非無聲降級（P0-4）
  void _showNotice(String message, {Color color = Colors.orange}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  int get _completedCount => _inspectionItems.where((i) => i.isCompleted).length;

  // ========== Build UI ==========

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_getAppBarTitle()),
        actions: _buildAppBarActions(),
      ),
      body: Stack(
        children: [
          _errorMessage != null ? _buildErrorView() : _buildCurrentStep(),
          if (_isBatchAnalyzing) _buildBatchAnalysisOverlay(),
        ],
      ),
    );
  }

  /// 批次分析進度覆蓋層
  Widget _buildBatchAnalysisOverlay() {
    final progress = _batchTotal > 0 ? _batchCompleted / _batchTotal : 0.0;

    return Container(
      color: Colors.black54,
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.smart_toy, size: 48, color: AppColors.primary),
                const SizedBox(height: 16),
                const Text(
                  'AI 批次分析中',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '正在分析: $_batchCurrentItem',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 12,
                    backgroundColor: Colors.grey[200],
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$_batchCompleted / $_batchTotal 項完成',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                if (_batchErrors > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '$_batchErrors 項分析失敗',
                    style: const TextStyle(fontSize: 13, color: Colors.red),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  '請耐心等待，AI 正在逐項分析照片...',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getAppBarTitle() {
    switch (_currentStep) {
      case FormInspectionStep.uploadForm:
        return '表單檢測';
      case FormInspectionStep.inspecting:
        return _template?.templateName ?? '逐項檢測';
      case FormInspectionStep.preview:
        return '預覽結果';
      case FormInspectionStep.exporting:
        return '產生表單';
      case FormInspectionStep.done:
        return '完成';
    }
  }

  List<Widget> _buildAppBarActions() {
    final actions = <Widget>[];

    if (_currentStep == FormInspectionStep.inspecting) {
      // 切換模式按鈕
      actions.add(
        PopupMenuButton<InspectionMode>(
          icon: Icon(
            _mode == InspectionMode.photo ? Icons.camera_alt : Icons.edit,
          ),
          onSelected: (mode) => setState(() => _mode = mode),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: InspectionMode.photo,
              child: Row(
                children: [
                  Icon(Icons.camera_alt,
                      color: _mode == InspectionMode.photo ? AppColors.primary : null),
                  const SizedBox(width: 8),
                  const Text('拍照分析模式'),
                ],
              ),
            ),
            PopupMenuItem(
              value: InspectionMode.manual,
              child: Row(
                children: [
                  Icon(Icons.edit,
                      color: _mode == InspectionMode.manual ? AppColors.primary : null),
                  const SizedBox(width: 8),
                  const Text('純文字填寫模式'),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 預覽步驟：重新執行法規標準判定（離線恢復後可用）
    if (_currentStep == FormInspectionStep.preview) {
      actions.add(
        IconButton(
          tooltip: '重新依法規判定',
          icon: const Icon(Icons.rule),
          onPressed: _isJudging ? null : () => _runStandardJudgment(),
        ),
      );
    }

    return actions;
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case FormInspectionStep.uploadForm:
        return _buildUploadView();
      case FormInspectionStep.inspecting:
        return _buildInspectionView();
      case FormInspectionStep.preview:
        return _buildPreviewView();
      case FormInspectionStep.exporting:
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在產生表單...', style: TextStyle(fontSize: 16)),
              SizedBox(height: 8),
              Text('將檢測結果回填至原始表單格式',
                  style: TextStyle(color: Colors.grey)),
            ],
          ),
        );
      case FormInspectionStep.done:
        return _buildDoneView();
    }
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_errorMessage!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                  _currentStep = FormInspectionStep.uploadForm;
                });
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重新開始'),
            ),
          ],
        ),
      ),
    );
  }

  // ========== Step 1 UI: 上傳表單 ==========

  Widget _buildUploadView() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在分析「$_fileName」...', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text('辨識表單欄位與結構',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.upload_file, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 24),
            const Text(
              '上傳定檢表',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '支援 Excel (.xlsx) 和 Word (.docx) 格式',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _pickAndAnalyzeForm,
              icon: const Icon(Icons.file_upload),
              label: const Text('選擇定檢表檔案'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    '流程說明',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _buildFlowStep('1', '上傳定檢表', '系統自動辨識表單結構'),
                  _buildFlowStep('2', '逐項拍照檢測', '一鍵自動或逐項拍照 → AI 自動分析'),
                  _buildFlowStep('3', '預覽確認', '確認所有檢測結果'),
                  _buildFlowStep('4', '產生報告', '自動匯出定檢表與 AI 總結報告'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlowStep(String num, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.primary,
            child: Text(num, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ========== Step 2 UI: 逐項檢測 ==========

  Widget _buildInspectionView() {
    return Column(
      children: [
        // 標題 + GPS 狀態
        _buildTitleBar(),

        // 進度條
        _buildProgressBar(),

        // 模式指示器
        _buildModeIndicator(),

        // 項目列表
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _inspectionItems.length,
            itemBuilder: (context, index) {
              return _buildInspectionItemCard(index);
            },
          ),
        ),

        // 底部操作列
        _buildInspectionBottomBar(),
      ],
    );
  }

  Widget _buildTitleBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '檢測標題',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: (value) {
                _inspectionTitle = value;
              },
            ),
          ),
          const SizedBox(width: 8),
          // GPS 狀態
          if (_isLocating)
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              _locationData != null ? Icons.location_on : Icons.location_off,
              color: _locationData != null ? Colors.green : Colors.grey,
              size: 20,
            ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final total = _inspectionItems.length;
    final completed = _completedCount;
    final percentage = total > 0 ? (completed / total * 100) : 0.0;

    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.white,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('檢測進度', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('$completed / $total 項 (${percentage.toStringAsFixed(0)}%)'),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: total > 0 ? completed / total : 0,
              minHeight: 8,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation(
                completed == total ? Colors.green : AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: _mode == InspectionMode.photo ? Colors.blue[50] : Colors.orange[50],
      child: Row(
        children: [
          Icon(
            _mode == InspectionMode.photo ? Icons.camera_alt : Icons.edit,
            size: 18,
            color: _mode == InspectionMode.photo ? Colors.blue : Colors.orange,
          ),
          const SizedBox(width: 8),
          Text(
            _mode == InspectionMode.photo
                ? '拍照分析模式 — 點擊項目旁的相機按鈕拍照'
                : '手動填寫模式 — 直接輸入檢測結果',
            style: TextStyle(
              fontSize: 12,
              color: _mode == InspectionMode.photo ? Colors.blue[700] : Colors.orange[700],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectionItemCard(int index) {
    final item = _inspectionItems[index];

    Color statusColor;
    IconData statusIcon;
    if (item.isAnalyzing) {
      statusColor = Colors.blue;
      statusIcon = Icons.hourglass_top;
    } else if (item.isCompleted) {
      final v = item.verdict;
      statusColor = verdictColor(v);
      statusIcon = v == '不合格'
          ? Icons.error
          : v == '警告'
              ? Icons.warning_amber
              : v == '待判定'
                  ? Icons.hourglass_empty
                  : Icons.check_circle;
    } else {
      statusColor = Colors.grey;
      statusIcon = Icons.circle_outlined;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: item.isCompleted ? statusColor.withValues(alpha: 0.3) : Colors.grey[300]!,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 標題行
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),

                // 操作按鈕
                if (_mode == InspectionMode.photo) ...[
                  if (item.isAnalyzing)
                    const SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    // 拍照按鈕
                    IconButton(
                      icon: const Icon(Icons.camera_alt, color: AppColors.primary),
                      onPressed: () => _captureAndAnalyze(index),
                      tooltip: '拍照分析',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    // 相簿按鈕
                    IconButton(
                      icon: const Icon(Icons.photo_library, color: Colors.grey),
                      onPressed: () => _pickFromGallery(index),
                      tooltip: '從相簿選取',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ],
                ],
              ],
            ),

            // 照片預覽 + AI 結果
            if (item.photoPath != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(item.photoPath!),
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ],

            // AI 分析結果
            if (item.aiResult != null) ...[
              const SizedBox(height: 8),
              Builder(builder: (context) {
              final vColor = verdictColor(item.verdict);
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: vColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.smart_toy, size: 16, color: AppColors.primary),
                        const SizedBox(width: 4),
                        const Text('AI 分析結果',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: vColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            item.verdict,
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.displayValue ?? '',
                      style: const TextStyle(fontSize: 13),
                    ),
                    // 法規標準依據（量測欄位判定來源）
                    if (item.standardBasis != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.gavel, size: 13, color: vColor),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.conversionNote != null
                                  ? '${item.standardBasis}\n${item.conversionNote}'
                                  : item.standardBasis!,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[700]),
                            ),
                          ),
                        ],
                      ),
                    ],
                    // 顯示讀數
                    if (item.aiResult!['readings'] != null &&
                        (item.aiResult!['readings'] as Map).isNotEmpty) ...[
                      const Divider(height: 12),
                      ...((item.aiResult!['readings'] as Map).entries.map((e) {
                        final val = e.value is Map ? e.value : {'value': e.value};
                        return Text(
                          '${e.key}: ${val['value']} ${val['unit'] ?? ''}',
                          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                        );
                      })),
                    ],
                  ],
                ),
              );
            }),
            ],

            // 手動填寫 (手動模式或作為 AI 補充)
            if (_mode == InspectionMode.manual ||
                (!item.isCompleted && !item.isAnalyzing)) ...[
              const SizedBox(height: 8),
              TextField(
                decoration: InputDecoration(
                  hintText: _getFieldHint(item),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  isDense: true,
                ),
                controller: item.manualController,
                onChanged: (value) => _setManualValue(index, value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getFieldHint(InspectionItemState item) {
    switch (item.fieldType) {
      case 'number':
      case 'measurement':
        return '輸入數值...';
      case 'radio':
        return '合格 / 不合格';
      default:
        return '輸入檢測結果...';
    }
  }

  Widget _buildInspectionBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 跳過所有 (手動模式用)
          if (_mode == InspectionMode.manual)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  // 將所有未填欄位標記為不適用
                  setState(() {
                    for (final item in _inspectionItems) {
                      if (!item.isCompleted) {
                        item.manualValue = 'N/A';
                        item.isCompleted = true;
                        _filledData[item.fieldId] = 'N/A';
                      }
                    }
                  });
                },
                icon: const Icon(Icons.skip_next),
                label: const Text('全部填 N/A'),
              ),
            ),
          if (_mode == InspectionMode.manual) const SizedBox(width: 12),

          // 自動檢測 + 批次拍照按鈕（拍照模式時顯示）
          if (_mode == InspectionMode.photo) ...[
            ElevatedButton.icon(
              onPressed: _isBatchAnalyzing ? null : _startAutoInspection,
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('自動檢測'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(width: 4),
            OutlinedButton.icon(
              onPressed: _isBatchAnalyzing ? null : _launchGuidedCapture,
              icon: const Icon(Icons.burst_mode, size: 18),
              label: const Text('批次'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              ),
            ),
            const SizedBox(width: 4),
          ],

          // 預覽/完成按鈕
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _completedCount > 0 ? _goToPreview : null,
              icon: const Icon(Icons.preview),
              label: Text('預覽結果 ($_completedCount/${_inspectionItems.length})'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: _completedCount == _inspectionItems.length
                    ? Colors.green
                    : AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ========== Step 3 UI: 預覽 ==========

  Widget _buildPreviewView() {
    final completed = _inspectionItems.where((i) => i.isCompleted).toList();
    final incomplete = _inspectionItems.where((i) => !i.isCompleted).toList();
    // 依法規標準判定（含 AI 異常）統計不合格 / 警告數量
    final failCount = completed.where((i) => i.verdict == '不合格').length;
    final warningCount = completed.where((i) => i.verdict == '警告').length;
    final pendingCount = completed.where((i) => i.verdict == '待判定').length;

    return Column(
      children: [
        // 統計摘要
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.blue[50],
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStat('已完成', '${completed.length}', Colors.green),
              _buildStat('未完成', '${incomplete.length}', Colors.grey),
              _buildStat('不合格', '$failCount', Colors.red),
              _buildStat('警告', '$warningCount', Colors.orange),
            ],
          ),
        ),

        // 標準判定進行中 / 待判定提示
        if (_isJudging)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            color: Colors.teal[50],
            child: const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('依法規標準判定中…', style: TextStyle(fontSize: 12)),
              ],
            ),
          )
        else if (pendingCount > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            color: Colors.orange[50],
            child: Row(
              children: [
                const Icon(Icons.cloud_off, size: 14, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('$pendingCount 項待判定（離線），可點右上重新判定',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),

        // 結果列表
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _inspectionItems.length,
            itemBuilder: (context, index) {
              final item = _inspectionItems[index];
              final v = item.verdict;
              final color = verdictColor(v);
              final subtitleLines = <String>[item.displayValue ?? '未填寫'];
              if (item.standardBasis != null) subtitleLines.add(item.standardBasis!);
              if (item.conversionNote != null) subtitleLines.add(item.conversionNote!);
              return ListTile(
                leading: Icon(
                  item.isCompleted
                      ? (v == '不合格'
                          ? Icons.error
                          : v == '警告'
                              ? Icons.warning_amber
                              : v == '待判定'
                                  ? Icons.hourglass_empty
                                  : Icons.check_circle)
                      : Icons.circle_outlined,
                  color: item.isCompleted ? color : Colors.grey,
                ),
                title: Text(item.label, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  subtitleLines.join('\n'),
                  style: TextStyle(
                    fontSize: 12,
                    color: item.isCompleted ? Colors.black54 : Colors.grey,
                  ),
                ),
                isThreeLine: subtitleLines.length > 1,
                trailing: item.isCompleted
                    ? Text(v,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ))
                    : null,
              );
            },
          ),
        ),

        // 底部操作列
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _currentStep = FormInspectionStep.inspecting;
                      _autoReportTriggered = false;
                      _summaryReport = null;
                    });
                  },
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回修改'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _exportFilledForm,
                  icon: const Icon(Icons.file_download),
                  label: const Text('產生填好的表單'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: Colors.green,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }

  // ========== Step 4 UI: 完成 ==========

  Widget _buildDoneView() {
    // 自動產生 AI 報告（首次進入時觸發）
    if (!_autoReportTriggered && _summaryReport == null && !_isGeneratingReport) {
      _autoReportTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _generateSummaryReport();
      });
    }

    final completed = _inspectionItems.where((i) => i.isCompleted).toList();
    // 異常 = 法規判定不合格/警告，或 AI 判定異常（量測欄位以標準判定為準）
    final problemItems = completed
        .where((i) => i.verdict == '不合格' || i.verdict == '警告')
        .toList();
    final anomalyCount = problemItems.length;
    final normalCount = completed.length - anomalyCount;

    return Column(
      children: [
        // 統計卡片
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.green[400]!, Colors.teal[400]!],
            ),
          ),
          child: Column(
            children: [
              const Icon(Icons.check_circle, size: 48, color: Colors.white),
              const SizedBox(height: 8),
              const Text('檢測完成！',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 4),
              Text('表單已儲存',
                  style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.9))),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildDoneStat('總計', '${completed.length}', Colors.white),
                  _buildDoneStat('正常', '$normalCount', Colors.lightGreenAccent),
                  _buildDoneStat('異常', '$anomalyCount',
                      anomalyCount > 0 ? Colors.redAccent[100]! : Colors.white),
                ],
              ),
            ],
          ),
        ),

        // AI 摘要報告區域
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 自動產生報告中
                if (_summaryReport == null)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('AI 正在自動產生總結報告...'),
                        ],
                      ),
                    ),
                  ),

                // 報告內容
                if (_summaryReport != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.auto_awesome, color: Colors.amber, size: 20),
                          SizedBox(width: 8),
                          Text('AI 總結報告',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.copy, size: 20),
                            tooltip: '複製報告',
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _summaryReport!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('報告已複製到剪貼簿')),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: '重新產生',
                            onPressed: () {
                              setState(() => _summaryReport = null);
                              _generateSummaryReport();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[200]!),
                    ),
                    child: SelectableText(
                      _summaryReport!,
                      style: const TextStyle(fontSize: 14, height: 1.6),
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // 異常項目快速一覽（含法規不合格/警告）
                if (anomalyCount > 0) ...[
                  const Text('⚠️ 異常 / 不合格項目',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red)),
                  const SizedBox(height: 8),
                  ...problemItems.map((item) {
                    final vColor = verdictColor(item.verdict);
                    final detail = item.standardBasis ??
                        item.aiResult?['anomaly_description'] ??
                        item.displayValue ??
                        '';
                    return Card(
                      color: vColor.withValues(alpha: 0.08),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(Icons.warning, color: vColor),
                        title: Text(item.label,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(
                          '$detail',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Text(item.verdict,
                            style: TextStyle(
                                color: vColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),

        // 底部操作列：分享 + 返回
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ★ PDF 報告（申報交付格式；純本機產生，離線可用）
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isExportingPdf ? null : _exportPdfReport,
                  icon: _isExportingPdf
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf, size: 18),
                  label: Text(_isExportingPdf ? '產生 PDF 中...' : '匯出 PDF 報告（含照片與法規判定）',
                      style: const TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.deepOrange[700],
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 分享按鈕列
              Row(
                children: [
                  // 分享文件
                  if (_exportedFilePath != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _shareFile(_exportedFilePath!),
                        icon: const Icon(Icons.description, size: 18),
                        label: const Text('分享表單', style: TextStyle(fontSize: 13)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  if (_exportedFilePath != null && _summaryReport != null)
                    const SizedBox(width: 8),
                  // 分享報告
                  if (_summaryReport != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _shareReport,
                        icon: const Icon(Icons.article, size: 18),
                        label: const Text('分享報告', style: TextStyle(fontSize: 13)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // 返回主頁
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.done),
                  label: const Text('返回主頁'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 分享檔案（離線時暫存）
  Future<void> _shareFile(String filePath) async {
    try {
      final isOnline = await ConnectivityService().checkConnection();
      if (isOnline) {
        await FileSaveService.saveAndShare(
          bytes: await File(filePath).readAsBytes(),
          fileName: p.basename(filePath),
        );
        // 更新狀態為已分享
        if (_currentRecord != null) {
          _currentRecord = _currentRecord!.copyWith(
            status: FormRecordStatus.shared,
            pendingShare: false,
          );
          await _dbService.saveFormRecord(_currentRecord!);
        }
      } else {
        // 離線：標記待分享
        if (_currentRecord != null) {
          _currentRecord = _currentRecord!.copyWith(pendingShare: true);
          await _dbService.saveFormRecord(_currentRecord!);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('目前離線，檔案已儲存。恢復網路後可重新分享。'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 分享摘要報告
  Future<void> _shareReport() async {
    if (_summaryReport == null) return;
    try {
      final reportBytes = utf8.encode(_summaryReport!);
      final reportName = '${_fileName?.replaceAll(RegExp(r'\.\w+$'), '') ?? 'inspection'}_report.txt';
      await FileSaveService.saveAndShare(
        bytes: Uint8List.fromList(reportBytes),
        fileName: reportName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享報告失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 將目前檢測狀態組成 PDF 報告資料（與 JSON 摘要匯出同源）
  PdfReportData _buildPdfReportData() {
    final items = _inspectionItems.map((item) {
      final ai = item.aiResult;
      return PdfReportItem(
        fieldId: item.fieldId,
        label: item.label,
        value: PdfReportData.formatValue(
          _filledData[item.fieldId] ?? item.manualValue,
          fieldType: item.fieldType,
          aiResult: ai,
          judgment: item.standardJudgment,
        ),
        verdict: item.verdict,
        standardBasis: item.standardBasis,
        conversionNote: item.conversionNote,
        anomalyDescription:
            (ai != null && ai['is_anomaly'] == true) ? ai['anomaly_description']?.toString() : null,
        photoPath: item.photoPath,
      );
    }).toList();

    return PdfReportData(
      title: _inspectionTitle.isNotEmpty ? _inspectionTitle : (_currentRecord?.title ?? '檢測報告'),
      sourceFileName: _fileName,
      inspectionDate: _currentRecord?.createdAt ?? DateTime.now(),
      locationName: _locationData?.locationName ?? _currentRecord?.locationName,
      latitude: _locationData?.latitude ?? _currentRecord?.latitude,
      longitude: _locationData?.longitude ?? _currentRecord?.longitude,
      recordId: _currentRecord?.recordId,
      items: items,
      summaryReport: _summaryReport,
    );
  }

  /// ★ 匯出 PDF 報告（LAUNCH_PLAN 第 5-8 週：申報場景的交付格式）
  ///
  /// 純本機產生（內嵌字型、照片降採樣），不需網路；檔案存於 app 文件目錄
  /// `induspect_exports/` 後開啟系統分享。
  Future<void> _exportPdfReport() async {
    if (_isExportingPdf) return;
    setState(() => _isExportingPdf = true);
    try {
      final data = _buildPdfReportData();
      final bytes = await PdfReportService.build(data);

      // Issue #18：使用 app 文件目錄，避免被 OS 清除
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, 'induspect_exports'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final outputPath = p.join(dir.path, PdfReportService.suggestedFileName(data));
      await File(outputPath).writeAsBytes(bytes);

      await FileSaveService.saveAndShare(bytes: bytes, fileName: p.basename(outputPath));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 報告產生失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isExportingPdf = false);
    }
  }

  Widget _buildDoneStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
        Text(label,
            style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.9))),
      ],
    );
  }
}

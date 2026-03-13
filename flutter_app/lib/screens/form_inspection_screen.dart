import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/inspection_template.dart';
import '../models/template_field.dart';
import '../models/analysis_result.dart';
import '../services/gemini_service.dart';
import '../services/local_template_creator.dart';
import '../services/backend_api_service.dart';
import '../services/file_save_service.dart';
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
  const FormInspectionScreen({Key? key}) : super(key: key);

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
  });

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

  /// 取得此項目的判定結果
  String get verdict {
    if (aiResult != null) {
      return (aiResult!['is_anomaly'] == true) ? '不合格' : '合格';
    }
    if (manualValue != null && manualValue!.isNotEmpty) {
      return '已填寫';
    }
    return '未檢測';
  }
}

class _FormInspectionScreenState extends State<FormInspectionScreen> {
  FormInspectionStep _currentStep = FormInspectionStep.uploadForm;
  InspectionMode _mode = InspectionMode.photo;

  // 上傳的原始檔案
  PlatformFile? _uploadedFile;
  Uint8List? _uploadedFileBytes;
  String? _fileName;

  // 分析出的結構
  Map<String, dynamic>? _templateJson;
  InspectionTemplate? _template;
  List<Map<String, dynamic>> _fieldMap = [];

  // 檢測項目狀態
  List<InspectionItemState> _inspectionItems = [];
  int _currentItemIndex = 0;

  // 所有填寫的資料 (fieldId -> value)
  final Map<String, dynamic> _filledData = {};

  // 服務
  final ImagePicker _imagePicker = ImagePicker();
  GeminiService? _geminiService;

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initGemini();
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
      _uploadedFileBytes = bytes;
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

      setState(() {
        _isLoading = false;
        _currentStep = FormInspectionStep.inspecting;
      });
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

    _currentItemIndex = 0;
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

    setState(() {
      item.photoPath = image.path;
      item.photoBytes = imageBytes;
      item.isAnalyzing = true;
    });

    await _runAIAnalysis(item, imageBytes, image.path);
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

    setState(() {
      item.photoPath = image.path;
      item.photoBytes = imageBytes;
      item.isAnalyzing = true;
    });

    await _runAIAnalysis(item, imageBytes, image.path);
  }

  /// 執行 AI 分析並更新項目狀態
  Future<void> _runAIAnalysis(
    InspectionItemState item,
    Uint8List imageBytes,
    String photoPath,
  ) async {
    if (_geminiService != null) {
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
      } catch (e) {
        debugPrint('AI 分析失敗: $e');
        setState(() {
          item.isAnalyzing = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('AI 分析失敗: $e\n請嘗試手動填寫'),
              backgroundColor: Colors.orange,
            ),
          );
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

  /// 手動填寫欄位值
  void _setManualValue(int index, String value) {
    setState(() {
      final item = _inspectionItems[index];
      item.manualValue = value;
      item.isCompleted = value.isNotEmpty;
      _filledData[item.fieldId] = value;
    });
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
                await FileSaveService.saveAndShare(
                  bytes: Uint8List.fromList(filledBytes),
                  fileName: 'filled_$_fileName',
                );

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
      }

      // 後端不可用時，匯出為 JSON 摘要
      await _exportAsJsonSummary();

      setState(() {
        _isLoading = false;
        _currentStep = FormInspectionStep.done;
      });
    } catch (e) {
      _showError('匯出失敗: $e');
    }
  }

  /// 匯出為 JSON 摘要檔案
  Future<void> _exportAsJsonSummary() async {
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
          'has_photo': item.photoPath != null,
          'ai_result': item.aiResult,
        };
      }).toList(),
    };

    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(summary),
    );

    final outputName = '${_fileName?.replaceAll(RegExp(r'\.\w+$'), '')}_inspection_result.json';

    await FileSaveService.saveAndShare(
      bytes: Uint8List.fromList(jsonBytes),
      fileName: outputName,
    );
  }

  // ========== UI 工具方法 ==========

  void _showError(String message) {
    setState(() {
      _isLoading = false;
      _errorMessage = message;
    });
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
      body: _errorMessage != null ? _buildErrorView() : _buildCurrentStep(),
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
                  _buildFlowStep('2', '逐項拍照檢測', 'AI 自動分析並填入結果'),
                  _buildFlowStep('3', '預覽確認', '確認所有檢測結果'),
                  _buildFlowStep('4', '產生報告', '匯出填好的定檢表'),
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
              Text('檢測進度', style: const TextStyle(fontWeight: FontWeight.bold)),
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
      final isAnomaly = item.aiResult?['is_anomaly'] == true;
      statusColor = isAnomaly ? Colors.red : Colors.green;
      statusIcon = isAnomaly ? Icons.warning : Icons.check_circle;
    } else {
      statusColor = Colors.grey;
      statusIcon = Icons.circle_outlined;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: item.isCompleted ? statusColor.withOpacity(0.3) : Colors.grey[300]!,
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (item.aiResult!['is_anomaly'] == true)
                      ? Colors.red[50]
                      : Colors.green[50],
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
                            color: (item.aiResult!['is_anomaly'] == true)
                                ? Colors.red
                                : Colors.green,
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
              ),
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
                controller: TextEditingController(text: item.manualValue ?? ''),
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
            color: Colors.black.withOpacity(0.05),
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
    final anomalyCount = completed.where((i) => i.aiResult?['is_anomaly'] == true).length;

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
              _buildStat('異常', '$anomalyCount', Colors.red),
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
              return ListTile(
                leading: Icon(
                  item.isCompleted
                      ? (item.aiResult?['is_anomaly'] == true
                          ? Icons.warning
                          : Icons.check_circle)
                      : Icons.circle_outlined,
                  color: item.isCompleted
                      ? (item.aiResult?['is_anomaly'] == true
                          ? Colors.red
                          : Colors.green)
                      : Colors.grey,
                ),
                title: Text(item.label, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  item.displayValue ?? '未填寫',
                  style: TextStyle(
                    fontSize: 12,
                    color: item.isCompleted ? Colors.black54 : Colors.grey,
                  ),
                ),
                trailing: item.isCompleted
                    ? Text(item.verdict,
                        style: TextStyle(
                          color: item.verdict == '不合格' ? Colors.red : Colors.green,
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
                color: Colors.black.withOpacity(0.1),
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
                    setState(() => _currentStep = FormInspectionStep.inspecting);
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            const Text(
              '檢測完成！',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '已完成 $_completedCount 個項目的檢測',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              '表單已儲存',
              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.done),
              label: const Text('返回主頁'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

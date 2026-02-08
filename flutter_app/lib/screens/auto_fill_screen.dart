import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/backend_api_service.dart';
import '../utils/constants.dart';

/// 自動回填畫面
///
/// 完整工作流程：
/// 1. 載入定檢 Excel/Word 文件
/// 2. 系統自動分析表格結構
/// 3. AI 映射檢查結果到欄位
/// 4. 預覽回填結果
/// 5. 確認後執行回填，匯出文件
class AutoFillScreen extends StatefulWidget {
  /// 已完成的 AI 檢查結果列表
  final List<Map<String, dynamic>> inspectionResults;

  const AutoFillScreen({
    Key? key,
    required this.inspectionResults,
  }) : super(key: key);

  @override
  State<AutoFillScreen> createState() => _AutoFillScreenState();
}

enum AutoFillStep {
  selectFile,
  analyzing,
  mapping,
  preview,
  filling,
  done,
}

class _AutoFillScreenState extends State<AutoFillScreen> {
  final BackendApiService _api = BackendApiService();

  AutoFillStep _currentStep = AutoFillStep.selectFile;

  // 檔案相關
  PlatformFile? _selectedFile;
  String? _fileName;

  // 分析結果
  List<Map<String, dynamic>> _fieldMap = [];
  String _fileType = '';

  // 映射結果
  List<Map<String, dynamic>> _fillValues = [];
  List<String> _unmappedFields = [];

  // 預覽結果
  List<Map<String, dynamic>> _previewItems = [];
  List<String> _warnings = [];
  int _filledCount = 0;

  // 錯誤
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('自動回填定檢表格'),
        actions: [
          if (_currentStep == AutoFillStep.preview)
            TextButton.icon(
              onPressed: _executeFill,
              icon: const Icon(Icons.check, color: Colors.white),
              label: const Text('確認回填', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildStepIndicator(),
          Expanded(child: _buildStepContent()),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    final steps = [
      {'label': '選擇文件', 'step': AutoFillStep.selectFile},
      {'label': '分析結構', 'step': AutoFillStep.analyzing},
      {'label': 'AI 映射', 'step': AutoFillStep.mapping},
      {'label': '預覽確認', 'step': AutoFillStep.preview},
      {'label': '完成', 'step': AutoFillStep.done},
    ];

    final currentIndex = steps.indexWhere((s) => s['step'] == _currentStep);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: List.generate(steps.length, (index) {
          final isActive = index <= currentIndex;
          final isCurrent = index == currentIndex;

          return Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    if (index > 0)
                      Expanded(
                        child: Container(
                          height: 2,
                          color: isActive ? AppColors.primary : Colors.grey[300],
                        ),
                      ),
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: isCurrent
                          ? AppColors.primary
                          : isActive
                              ? Colors.green
                              : Colors.grey[300],
                      child: isCurrent && (_currentStep == AutoFillStep.analyzing ||
                              _currentStep == AutoFillStep.mapping ||
                              _currentStep == AutoFillStep.filling)
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(Colors.white),
                              ),
                            )
                          : isActive && index < currentIndex
                              ? const Icon(Icons.check, size: 16, color: Colors.white)
                              : Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isActive ? Colors.white : Colors.grey,
                                  ),
                                ),
                    ),
                    if (index < steps.length - 1)
                      Expanded(
                        child: Container(
                          height: 2,
                          color: index < currentIndex ? AppColors.primary : Colors.grey[300],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  steps[index]['label'] as String,
                  style: TextStyle(
                    fontSize: 10,
                    color: isCurrent ? AppColors.primary : Colors.grey[600],
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStepContent() {
    if (_errorMessage != null) {
      return _buildErrorView();
    }

    switch (_currentStep) {
      case AutoFillStep.selectFile:
        return _buildSelectFileView();
      case AutoFillStep.analyzing:
        return _buildLoadingView('正在分析表格結構...', '識別欄位位置與合併儲存格');
      case AutoFillStep.mapping:
        return _buildLoadingView('AI 正在映射檢查結果...', '將分析數據對應到表格欄位');
      case AutoFillStep.preview:
        return _buildPreviewView();
      case AutoFillStep.filling:
        return _buildLoadingView('正在回填表格...', '將數據寫入原始文件');
      case AutoFillStep.done:
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
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                  _currentStep = AutoFillStep.selectFile;
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

  Widget _buildSelectFileView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.description_outlined, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 24),
            const Text(
              '選擇定檢表格文件',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '支援 Excel (.xlsx) 和 Word (.docx) 格式',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              '已有 ${widget.inspectionResults.length} 筆檢查結果待回填',
              style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('選擇檔案'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingView(String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(subtitle, style: TextStyle(color: Colors.grey[600])),
          if (_fileName != null) ...[
            const SizedBox(height: 16),
            Chip(
              avatar: const Icon(Icons.insert_drive_file, size: 18),
              label: Text(_fileName!),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreviewView() {
    return Column(
      children: [
        // 統計摘要
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.blue[50],
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatChip('總欄位', '${_fieldMap.length}', Icons.grid_on),
              _buildStatChip('已填入', '$_filledCount', Icons.check_circle, Colors.green),
              _buildStatChip('警告', '${_warnings.length}', Icons.warning, Colors.orange),
            ],
          ),
        ),

        // 警告列表
        if (_warnings.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.orange[50],
            child: ExpansionTile(
              leading: const Icon(Icons.warning_amber, color: Colors.orange),
              title: Text('${_warnings.length} 個警告', style: const TextStyle(fontSize: 14)),
              children: _warnings
                  .map((w) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.info_outline, size: 18, color: Colors.orange),
                        title: Text(w, style: const TextStyle(fontSize: 13)),
                      ))
                  .toList(),
            ),
          ),

        // 預覽列表
        Expanded(
          child: ListView.builder(
            itemCount: _previewItems.length,
            itemBuilder: (context, index) {
              final item = _previewItems[index];
              return _buildPreviewItemCard(item, index);
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
                    setState(() {
                      _currentStep = AutoFillStep.selectFile;
                      _selectedFile = null;
                    });
                  },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('重新選擇'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _executeFill,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('確認回填'),
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

  Widget _buildStatChip(String label, String value, IconData icon, [Color? color]) {
    return Column(
      children: [
        Icon(icon, color: color ?? Colors.blue, size: 28),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color ?? Colors.blue)),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }

  Widget _buildPreviewItemCard(Map<String, dynamic> item, int index) {
    final fieldName = item['field_name'] ?? '';
    final fieldType = item['field_type'] ?? 'text';
    final value = item['value'];
    final confidence = (item['confidence'] as num?)?.toDouble() ?? 0.0;
    final source = item['source'] ?? '';
    final hasTarget = item['has_target'] ?? false;

    Color confidenceColor;
    if (confidence >= 0.9) {
      confidenceColor = Colors.green;
    } else if (confidence >= 0.7) {
      confidenceColor = Colors.orange;
    } else {
      confidenceColor = Colors.red;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 欄位類型 icon
                Icon(
                  _getFieldTypeIcon(fieldType),
                  size: 20,
                  color: Colors.grey[600],
                ),
                const SizedBox(width: 8),
                // 欄位名稱
                Expanded(
                  child: Text(
                    fieldName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                // 信心度
                if (value != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: confidenceColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: confidenceColor.withOpacity(0.5)),
                    ),
                    child: Text(
                      '${(confidence * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: 12,
                        color: confidenceColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (!hasTarget)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Tooltip(
                      message: '找不到值儲存格位置',
                      child: Icon(Icons.location_off, size: 18, color: Colors.red),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // 填入值
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: value != null ? Colors.green[50] : Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: value != null ? Colors.green[200]! : Colors.grey[300]!,
                ),
              ),
              child: Text(
                value ?? '(無對應值)',
                style: TextStyle(
                  fontSize: 15,
                  color: value != null ? Colors.black87 : Colors.grey,
                  fontStyle: value != null ? FontStyle.normal : FontStyle.italic,
                ),
              ),
            ),
            if (source.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                source,
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
              '回填完成！',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '已成功將 $_filledCount 個欄位填入表格',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.done),
              label: const Text('返回'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFieldTypeIcon(String fieldType) {
    switch (fieldType) {
      case 'date':
        return Icons.calendar_today;
      case 'number':
        return Icons.numbers;
      case 'checkbox':
        return Icons.check_box;
      default:
        return Icons.text_fields;
    }
  }

  // ============ 操作方法 ============

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'docx'],
    );

    if (result == null || result.files.isEmpty) return;

    _selectedFile = result.files.first;
    _fileName = _selectedFile!.name;

    setState(() {
      _currentStep = AutoFillStep.analyzing;
    });

    await _analyzeStructure();
  }

  Future<void> _analyzeStructure() async {
    try {
      final result = await _api.analyzeFileStructure(_selectedFile!);

      if (result['success'] != true) {
        setState(() {
          _errorMessage = result['error'] ?? '分析失敗';
        });
        return;
      }

      _fieldMap = List<Map<String, dynamic>>.from(result['field_map'] ?? []);
      _fileType = result['file_type'] ?? '';

      if (_fieldMap.isEmpty) {
        setState(() {
          _errorMessage = '未識別到任何可填入欄位，請確認文件格式是否正確';
        });
        return;
      }

      setState(() {
        _currentStep = AutoFillStep.mapping;
      });

      await _mapFields();
    } catch (e) {
      setState(() {
        _errorMessage = '分析表格結構時發生錯誤: $e';
      });
    }
  }

  Future<void> _mapFields() async {
    try {
      final result = await _api.mapFieldsWithAI(
        fieldMap: _fieldMap,
        inspectionResults: widget.inspectionResults,
      );

      if (result['success'] != true) {
        setState(() {
          _errorMessage = result['error'] ?? 'AI 映射失敗';
        });
        return;
      }

      final mappings = List<Map<String, dynamic>>.from(result['mappings'] ?? []);
      _unmappedFields = List<String>.from(result['unmapped_fields'] ?? []);

      // 轉換為 fill_values 格式
      _fillValues = mappings.map((m) => {
        'field_id': m['field_id'],
        'value': m['suggested_value'] ?? '',
        'confidence': m['confidence'] ?? 0.0,
        'source': m['source'] ?? '',
      }).toList();

      // 取得預覽
      await _loadPreview();
    } catch (e) {
      setState(() {
        _errorMessage = 'AI 映射時發生錯誤: $e';
      });
    }
  }

  Future<void> _loadPreview() async {
    try {
      final result = await _api.previewAutoFill(
        fieldMap: _fieldMap,
        fillValues: _fillValues,
      );

      setState(() {
        _previewItems = List<Map<String, dynamic>>.from(result['preview_items'] ?? []);
        _warnings = List<String>.from(result['warnings'] ?? []);
        _filledCount = result['filled_count'] ?? 0;
        _currentStep = AutoFillStep.preview;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '載入預覽時發生錯誤: $e';
      });
    }
  }

  Future<void> _executeFill() async {
    setState(() {
      _currentStep = AutoFillStep.filling;
    });

    try {
      final filledBytes = await _api.executeAutoFill(
        file: _selectedFile!,
        fieldMap: _fieldMap,
        fillValues: _fillValues,
      );

      if (filledBytes == null) {
        setState(() {
          _errorMessage = '回填執行失敗';
        });
        return;
      }

      // 儲存到本地並分享
      final dir = await getTemporaryDirectory();
      final outputPath = '${dir.path}/filled_${_fileName}';
      final file = File(outputPath);
      await file.writeAsBytes(filledBytes);

      // 分享文件
      await Share.shareXFiles(
        [XFile(outputPath)],
        subject: '已回填的定檢表格',
      );

      setState(() {
        _currentStep = AutoFillStep.done;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '回填時發生錯誤: $e';
      });
    }
  }
}

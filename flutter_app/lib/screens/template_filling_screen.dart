import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/inspection_template.dart';
import '../models/template_inspection_record.dart';
import '../services/database_service.dart';
import '../utils/constants.dart';
import '../widgets/template/section_card.dart';

/// 模板填寫畫面（分區段顯示版本）
class TemplateFillingScreen extends StatefulWidget {
  final InspectionTemplate template;
  final TemplateInspectionRecord? existingRecord; // 恢復已存在的檢測記錄

  const TemplateFillingScreen({
    Key? key,
    required this.template,
    this.existingRecord,
  }) : super(key: key);

  @override
  State<TemplateFillingScreen> createState() => _TemplateFillingScreenState();
}

class _TemplateFillingScreenState extends State<TemplateFillingScreen> {
  late Map<String, dynamic> _filledData;
  late TemplateInspectionRecord _currentRecord;
  final DatabaseService _databaseService = DatabaseService();
  Timer? _autoSaveTimer;
  bool _isSaving = false;
  DateTime? _lastSaved;

  @override
  void initState() {
    super.initState();
    _initializeRecord();
    _initializeDefaultValues();
    _startAutoSave();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  /// 初始化檢測記錄
  void _initializeRecord() {
    if (widget.existingRecord != null) {
      // 恢復現有記錄
      _currentRecord = widget.existingRecord!;
      _filledData = Map<String, dynamic>.from(_currentRecord.filledData);
    } else {
      // 創建新記錄
      final now = DateTime.now();
      _currentRecord = TemplateInspectionRecord(
        recordId: const Uuid().v4(),
        templateId: widget.template.templateId,
        templateName: widget.template.templateName,
        status: RecordStatus.draft,
        filledData: {},
        createdAt: now,
        updatedAt: now,
      );
      _filledData = {};
    }
  }

  /// 初始化預設值
  void _initializeDefaultValues() {
    for (final section in widget.template.sections) {
      for (final field in section.fields) {
        if (field.defaultValue != null && !_filledData.containsKey(field.fieldId)) {
          if (field.defaultValue == 'now') {
            _filledData[field.fieldId] = DateTime.now().toIso8601String();
          } else {
            _filledData[field.fieldId] = field.defaultValue;
          }
        }
      }
    }
  }

  /// 開始自動儲存（每30秒）
  void _startAutoSave() {
    _autoSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _saveDraft(showMessage: false);
    });
  }

  /// 欄位值變更處理
  void _handleFieldChanged(String fieldId, dynamic value) {
    setState(() {
      _filledData[fieldId] = value;

      // 更新記錄中的設備資訊（方便搜尋）
      if (fieldId == 'equipment_code') {
        _currentRecord = _currentRecord.copyWith(equipmentCode: value?.toString());
      } else if (fieldId == 'equipment_name') {
        _currentRecord = _currentRecord.copyWith(equipmentName: value?.toString());
      } else if (fieldId == 'customer_name') {
        _currentRecord = _currentRecord.copyWith(customerName: value?.toString());
      }
    });
  }

  /// AI 分析處理
  Future<void> _handleAIAnalysis(String fieldId, Map<String, dynamic> aiResults) async {
    setState(() {
      aiResults.forEach((key, value) {
        if (value != null) {
          _filledData[key] = value;
        }
      });
    });

    // 顯示成功提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Text('AI 分析完成，已自動填入相關欄位'),
            ],
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// 儲存草稿
  Future<void> _saveDraft({bool showMessage = true}) async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // 更新記錄
      final updatedRecord = _currentRecord.copyWith(
        filledData: Map<String, dynamic>.from(_filledData),
        updatedAt: DateTime.now(),
        status: RecordStatus.draft,
      );

      // 儲存到資料庫
      final id = await _databaseService.saveRecord(updatedRecord);

      // 更新當前記錄（包含資料庫 ID）
      if (_currentRecord.id == null) {
        _currentRecord = updatedRecord.copyWith(id: id.toString());
      } else {
        _currentRecord = updatedRecord;
      }

      setState(() {
        _lastSaved = DateTime.now();
      });

      if (showMessage && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('草稿已儲存'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('儲存草稿失敗: $e');
      if (showMessage && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('儲存失敗: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  /// 完成並儲存
  Future<void> _completeAndSave() async {
    // 驗證所有必填欄位
    final errors = widget.template.validateAll(_filledData);

    if (errors.isNotEmpty) {
      // 顯示錯誤對話框
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('填寫未完成'),
          content: Text('還有 ${errors.length} 個必填欄位未填寫\n\n是否要繼續儲存為草稿？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('儲存草稿'),
            ),
          ],
        ),
      );

      if (proceed == true) {
        await _saveDraft(showMessage: true);
      }
      return;
    }

    // 所有必填欄位已填寫，標記為完成
    setState(() {
      _isSaving = true;
    });

    try {
      final completedRecord = _currentRecord.copyWith(
        filledData: Map<String, dynamic>.from(_filledData),
        updatedAt: DateTime.now(),
        status: RecordStatus.completed,
        hasValidationErrors: false,
      );

      await _databaseService.saveRecord(completedRecord);

      if (mounted) {
        // 顯示成功訊息並返回
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 32),
                SizedBox(width: 12),
                Text('檢測完成！'),
              ],
            ),
            content: const Text('檢測記錄已儲存\n您可以在檢測記錄列表中查看'),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context); // 關閉對話框
                  Navigator.pop(context); // 返回上一頁
                },
                child: const Text('確定'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('儲存檢測記錄失敗: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('儲存失敗: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  /// 返回確認
  Future<bool> _onWillPop() async {
    // 自動儲存草稿
    await _saveDraft(showMessage: false);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認離開'),
        content: const Text('您的填寫進度已自動儲存為草稿'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('繼續填寫'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('離開'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final totalFields = widget.template.getAllFields().length;
    final completionPercentage = _currentRecord.getCompletionPercentage(totalFields);

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.template.templateName),
              if (_lastSaved != null)
                Text(
                  '上次儲存: ${_lastSaved!.hour}:${_lastSaved!.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
          actions: [
            // 儲存草稿按鈕
            IconButton(
              icon: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.save),
              onPressed: _isSaving ? null : () => _saveDraft(showMessage: true),
              tooltip: '儲存草稿',
            ),
          ],
        ),
        body: Column(
          children: [
            // 整體進度條
            _buildOverallProgressBar(completionPercentage),

            // 區段列表
            Expanded(
              child: ListView.builder(
                itemCount: widget.template.sections.length,
                itemBuilder: (context, index) {
                  final section = widget.template.sections[index];
                  return SectionCard(
                    section: section,
                    filledData: _filledData,
                    onFieldChanged: _handleFieldChanged,
                    onAIAnalysis: _handleAIAnalysis,
                    initiallyExpanded: index == 0, // 第一個區段預設展開
                    recordId: _currentRecord.recordId,
                  );
                },
              ),
            ),

            // 底部操作列
            _buildBottomActionBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildOverallProgressBar(double percentage) {
    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '整體進度',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${percentage.toStringAsFixed(0)}% 完成',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: percentage / 100,
              minHeight: 10,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                percentage >= 100 ? Colors.green : AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActionBar() {
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
          // 儲存草稿按鈕
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isSaving ? null : () => _saveDraft(showMessage: true),
              icon: const Icon(Icons.save_outlined),
              label: const Text('儲存草稿'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 完成按鈕
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _completeAndSave,
              icon: const Icon(Icons.check_circle),
              label: const Text('完成檢測'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.green,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

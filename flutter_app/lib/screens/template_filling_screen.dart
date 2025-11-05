import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/inspection_template.dart';
import '../models/template_field.dart';
import '../utils/constants.dart';
import '../widgets/field_inputs/text_field_input.dart';
import '../widgets/field_inputs/number_field_input.dart';
import '../widgets/field_inputs/radio_field_input.dart';
import '../widgets/field_inputs/checkbox_field_input.dart';
import '../widgets/field_inputs/dropdown_field_input.dart';
import '../widgets/field_inputs/datetime_field_input.dart';
import '../widgets/field_inputs/photo_field_input.dart';
import '../widgets/field_inputs/textarea_field_input.dart';
import '../widgets/field_inputs/signature_field_input.dart';

/// 引導式模板填寫畫面
class TemplateFillingScreen extends StatefulWidget {
  final InspectionTemplate template;
  final TemplateFillingRecord? existingRecord; // 恢復已存在的填寫記錄

  const TemplateFillingScreen({
    Key? key,
    required this.template,
    this.existingRecord,
  }) : super(key: key);

  @override
  State<TemplateFillingScreen> createState() => _TemplateFillingScreenState();
}

class _TemplateFillingScreenState extends State<TemplateFillingScreen> {
  late int _currentSectionIndex;
  late int _currentFieldIndex;
  late Map<String, dynamic> _filledData;
  final Map<String, String> _validationErrors = {};
  final Map<String, String> _warnings = {};
  bool _showValidationErrors = false;

  @override
  void initState() {
    super.initState();
    _currentSectionIndex = 0;
    _currentFieldIndex = 0;
    _filledData = widget.existingRecord?.filledData ?? {};

    // 初始化預設值
    _initializeDefaultValues();
  }

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

  TemplateSection get _currentSection {
    return widget.template.sections[_currentSectionIndex];
  }

  List<TemplateField> get _visibleFields {
    return _currentSection.getVisibleFields(_filledData);
  }

  TemplateField? get _currentField {
    if (_currentFieldIndex >= _visibleFields.length) return null;
    return _visibleFields[_currentFieldIndex];
  }

  int get _totalVisibleFields {
    return widget.template.sections
        .expand((section) => section.getVisibleFields(_filledData))
        .length;
  }

  int get _currentGlobalFieldIndex {
    int count = 0;
    for (int i = 0; i < _currentSectionIndex; i++) {
      count += widget.template.sections[i].getVisibleFields(_filledData).length;
    }
    count += _currentFieldIndex;
    return count;
  }

  double get _progress {
    if (_totalVisibleFields == 0) return 0.0;
    return (_currentGlobalFieldIndex + 1) / _totalVisibleFields;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.template.templateName),
          actions: [
            // 儲存草稿
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveDraft,
              tooltip: '儲存草稿',
            ),
            // 查看總覽
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: _showOverview,
              tooltip: '查看總覽',
            ),
          ],
        ),
        body: Column(
          children: [
            // 進度條
            _buildProgressBar(),

            // 主要內容
            Expanded(
              child: _currentField == null
                  ? _buildCompletionView()
                  : _buildFieldInput(),
            ),

            // 導航按鈕
            _buildNavigationBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
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
          // 進度文字
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_currentSection.sectionTitle}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${_currentGlobalFieldIndex + 1} / $_totalVisibleFields',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // 進度條
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 8,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.primary,
              ),
            ),
          ),

          const SizedBox(height: 4),

          // 完成百分比
          Text(
            '${(_progress * 100).toStringAsFixed(0)}% 完成',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldInput() {
    final field = _currentField!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 欄位標籤
          Row(
            children: [
              Expanded(
                child: Text(
                  field.label,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (field.required)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '必填',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red[700],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 20),

          // 欄位輸入組件
          _buildFieldInputWidget(field),

          // 驗證錯誤訊息
          if (_showValidationErrors && _validationErrors.containsKey(field.fieldId)) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _validationErrors[field.fieldId]!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // 警告訊息
          if (_warnings.containsKey(field.fieldId)) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _warnings[field.fieldId]!,
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // AI 輔助提示
          if (field.aiFillable) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.blue, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      field.fieldType == FieldType.photo ||
                              field.fieldType == FieldType.photoMultiple
                          ? 'AI 會自動分析照片並填入相關欄位'
                          : 'AI 可協助填寫此欄位',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldInputWidget(TemplateField field) {
    final value = _filledData[field.fieldId];

    switch (field.fieldType) {
      case FieldType.text:
        return TextFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.number:
        return NumberFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.radio:
        return RadioFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.checkbox:
        return CheckboxFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.dropdown:
        return DropdownFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.datetime:
      case FieldType.date:
        return DateTimeFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.photo:
      case FieldType.photoMultiple:
        return PhotoFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
          onAIAnalysis: _handleAIAnalysis,
        );

      case FieldType.textarea:
        return TextAreaFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      case FieldType.signature:
        return SignatureFieldInput(
          field: field,
          value: value,
          onChanged: (newValue) => _updateField(field.fieldId, newValue),
        );

      default:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('此欄位類型尚未實作：${field.fieldType}'),
        );
    }
  }

  void _updateField(String fieldId, dynamic value) {
    setState(() {
      _filledData[fieldId] = value;

      // 清除該欄位的驗證錯誤
      _validationErrors.remove(fieldId);

      // 檢查警告
      final field = widget.template.getFieldById(fieldId);
      if (field != null) {
        final warning = field.checkWarning(value);
        if (warning != null) {
          _warnings[fieldId] = warning;
        } else {
          _warnings.remove(fieldId);
        }
      }
    });
  }

  Future<void> _handleAIAnalysis(String fieldId, Map<String, dynamic> aiResults) async {
    // AI 分析完成後，自動填入相關欄位
    setState(() {
      aiResults.forEach((key, value) {
        if (value != null) {
          _filledData[key] = value;
        }
      });
    });

    // 顯示成功提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: const [
            Icon(Icons.check_circle, color: Colors.white),
            SizedBox(width: 8),
            Text('AI 分析完成，已自動填入相關欄位'),
          ],
        ),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildNavigationBar() {
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
          // 上一項按鈕
          if (_hasPrevious())
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _goToPrevious,
                icon: const Icon(Icons.arrow_back),
                label: const Text('上一項'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),

          if (_hasPrevious()) const SizedBox(width: 12),

          // 下一項 / 完成按鈕
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _hasNext() ? _goToNext : _complete,
              icon: Icon(_hasNext() ? Icons.arrow_forward : Icons.check),
              label: Text(_hasNext() ? '下一項' : '完成填寫'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _hasPrevious() {
    return _currentSectionIndex > 0 || _currentFieldIndex > 0;
  }

  bool _hasNext() {
    return _currentFieldIndex < _visibleFields.length - 1 ||
        _currentSectionIndex < widget.template.sections.length - 1;
  }

  void _goToPrevious() {
    setState(() {
      if (_currentFieldIndex > 0) {
        _currentFieldIndex--;
      } else if (_currentSectionIndex > 0) {
        _currentSectionIndex--;
        _currentFieldIndex = widget.template.sections[_currentSectionIndex]
            .getVisibleFields(_filledData)
            .length - 1;
      }
    });
  }

  void _goToNext() {
    // 驗證當前欄位
    if (_currentField != null) {
      final error = _currentField!.validate(_filledData[_currentField!.fieldId]);
      if (error != null) {
        setState(() {
          _validationErrors[_currentField!.fieldId] = error;
          _showValidationErrors = true;
        });
        return;
      }
    }

    setState(() {
      _showValidationErrors = false;

      if (_currentFieldIndex < _visibleFields.length - 1) {
        _currentFieldIndex++;
      } else if (_currentSectionIndex < widget.template.sections.length - 1) {
        _currentSectionIndex++;
        _currentFieldIndex = 0;
      }
    });
  }

  Widget _buildCompletionView() {
    final allErrors = widget.template.validateAll(_filledData);
    final isComplete = allErrors.isEmpty;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isComplete ? Icons.check_circle : Icons.warning,
              size: 80,
              color: isComplete ? Colors.green : Colors.orange,
            ),
            const SizedBox(height: 24),
            Text(
              isComplete ? '✅ 所有欄位填寫完成！' : '⚠️ 還有必填欄位未填寫',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isComplete
                  ? '您可以儲存此檢測記錄或生成 PDF 報告'
                  : '還有 ${allErrors.length} 個必填欄位需要填寫',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (!isComplete) ...[
              ElevatedButton(
                onPressed: _goToFirstError,
                child: const Text('前往未填寫的欄位'),
              ),
              const SizedBox(height: 16),
            ],
            if (isComplete) ...[
              ElevatedButton.icon(
                onPressed: _saveRecord,
                icon: const Icon(Icons.save),
                label: const Text('儲存檢測記錄'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _generatePDF,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('生成 PDF 報告'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _goToFirstError() {
    final allErrors = widget.template.validateAll(_filledData);
    if (allErrors.isEmpty) return;

    final firstErrorFieldId = allErrors.keys.first;
    final field = widget.template.getFieldById(firstErrorFieldId);
    if (field == null) return;

    // 找到該欄位所在的區段
    for (int sectionIdx = 0; sectionIdx < widget.template.sections.length; sectionIdx++) {
      final section = widget.template.sections[sectionIdx];
      final visibleFields = section.getVisibleFields(_filledData);
      final fieldIdx = visibleFields.indexWhere((f) => f.fieldId == firstErrorFieldId);

      if (fieldIdx != -1) {
        setState(() {
          _currentSectionIndex = sectionIdx;
          _currentFieldIndex = fieldIdx;
          _showValidationErrors = true;
        });
        break;
      }
    }
  }

  Future<void> _complete() async {
    final allErrors = widget.template.validateAll(_filledData);

    if (allErrors.isNotEmpty) {
      // 顯示未完成提示
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('填寫未完成'),
          content: Text('還有 ${allErrors.length} 個必填欄位未填寫，是否要繼續？'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _goToFirstError();
              },
              child: const Text('前往填寫'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _showCompletionScreen();
              },
              child: const Text('稍後填寫'),
            ),
          ],
        ),
      );
    } else {
      _showCompletionScreen();
    }
  }

  void _showCompletionScreen() {
    setState(() {
      _currentSectionIndex = widget.template.sections.length;
      _currentFieldIndex = 0;
    });
  }

  Future<void> _saveDraft() async {
    // TODO: 實作儲存草稿功能
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('草稿已儲存')),
    );
  }

  void _showOverview() {
    // TODO: 實作總覽畫面
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('總覽功能開發中...')),
    );
  }

  Future<void> _saveRecord() async {
    // TODO: 實作儲存檢測記錄
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('檢測記錄已儲存')),
    );
  }

  Future<void> _generatePDF() async {
    // TODO: 實作 PDF 生成
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PDF 生成功能開發中...')),
    );
  }

  Future<bool> _onWillPop() async {
    // 確認是否要離開
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認離開'),
        content: const Text('您的填寫進度將會保存為草稿，確定要離開嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _saveDraft();
              Navigator.pop(context, true);
            },
            child: const Text('儲存並離開'),
          ),
        ],
      ),
    );

    return result ?? false;
  }
}

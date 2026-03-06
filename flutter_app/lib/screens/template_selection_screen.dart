import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../models/inspection_template.dart';
import '../models/template_inspection_record.dart';
import '../services/template_service.dart';
import '../services/database_service.dart';
import '../services/backend_api_service.dart';
import '../services/local_template_creator.dart';
import '../utils/constants.dart';
import 'template_filling_screen.dart';

/// 模板選擇畫面
class TemplateSelectionScreen extends StatefulWidget {
  const TemplateSelectionScreen({Key? key}) : super(key: key);

  @override
  State<TemplateSelectionScreen> createState() => _TemplateSelectionScreenState();
}

class _TemplateSelectionScreenState extends State<TemplateSelectionScreen> {
  final TemplateService _templateService = TemplateService();
  final DatabaseService _databaseService = DatabaseService();
  List<InspectionTemplate> _templates = [];
  Map<String, TemplateInspectionRecord> _latestRecords = {}; // templateId -> latest record
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    setState(() => _isLoading = true);

    try {
      await _templateService.init();
      final templates = await _templateService.getAllTemplates();

      // Load latest record for each template
      final latestRecords = <String, TemplateInspectionRecord>{};
      for (final template in templates) {
        final record = await _databaseService.getLatestRecordByTemplate(template.templateId);
        if (record != null) {
          latestRecords[template.templateId] = record;
        }
      }

      if (mounted) {
        setState(() {
          _templates = templates;
          _latestRecords = latestRecords;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ Failed to load templates: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load templates: $e')),
        );
      }
    }
  }

  List<InspectionTemplate> get _filteredTemplates {
    var filtered = _templates;

    // 分類篩選
    if (_selectedCategory != null) {
      filtered = filtered.where((t) => t.category == _selectedCategory).toList();
    }

    // 搜尋篩選
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((t) {
        return t.templateName.toLowerCase().contains(query) ||
            t.category.toLowerCase().contains(query);
      }).toList();
    }

    return filtered;
  }

  Set<String> get _categories {
    return _templates.map((t) => t.category).toSet();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('選擇檢測模板'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTemplates,
            tooltip: '重新載入',
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜尋與篩選區
          _buildSearchAndFilter(),

          // 模板列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredTemplates.isEmpty
                    ? _buildEmptyState()
                    : _buildTemplateList(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportDialog,
        icon: const Icon(Icons.upload_file),
        label: const Text('匯入模板'),
      ),
    );
  }

  Widget _buildSearchAndFilter() {
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
        children: [
          // 搜尋框
          TextField(
            decoration: InputDecoration(
              hintText: '搜尋模板名稱或類別...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (value) {
              setState(() => _searchQuery = value);
            },
          ),

          const SizedBox(height: 12),

          // 分類篩選
          if (_categories.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildCategoryChip('全部', null),
                  const SizedBox(width: 8),
                  ..._categories.map((category) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildCategoryChip(category, category),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCategoryChip(String label, String? category) {
    final isSelected = _selectedCategory == category;

    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _selectedCategory = selected ? category : null;
        });
      },
      backgroundColor: Colors.grey[200],
      selectedColor: AppColors.primary.withOpacity(0.2),
      checkmarkColor: AppColors.primary,
    );
  }

  Widget _buildTemplateList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredTemplates.length,
      itemBuilder: (context, index) {
        final template = _filteredTemplates[index];
        return _buildTemplateCard(template);
      },
    );
  }

  Widget _buildTemplateCard(InspectionTemplate template) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => _startInspection(template),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 標題與類別
              Row(
                children: [
                  // 圖示
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.assignment,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ),

                  const SizedBox(width: 12),

                  // 名稱與類別
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          template.templateName,
                          style: AppTextStyles.heading3,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue[50],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                template.category,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.blue[700],
                                ),
                              ),
                            ),
                            if (template.isFromRealForm) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green[50],
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  template.sourceFile!.fileType.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.green[700],
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 箭頭
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),

              const SizedBox(height: 16),

              // 統計資訊
              Row(
                children: [
                  _buildInfoChip(
                    Icons.list_alt,
                    '${template.sections.length} 個區段',
                    Colors.purple,
                  ),
                  const SizedBox(width: 12),
                  _buildInfoChip(
                    Icons.check_box,
                    '${template.getTotalFieldCount()} 個欄位',
                    Colors.green,
                  ),
                  const SizedBox(width: 12),
                  _buildInfoChip(
                    Icons.timer,
                    '約 ${template.metadata.estimatedDurationMinutes} 分鐘',
                    Colors.orange,
                  ),
                ],
              ),

              // 週期與說明
              if (template.metadata.safetyNotes != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          template.metadata.safetyNotes!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isNotEmpty ? '找不到符合的模板' : '尚無可用模板',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '請點擊下方「匯入模板」按鈕',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showImportDialog,
            icon: const Icon(Icons.upload_file),
            label: const Text('匯入模板'),
          ),
        ],
      ),
    );
  }

  Future<void> _startInspection(InspectionTemplate template) async {
    // Check if there's a previous record for this template
    final previousRecord = _latestRecords[template.templateId];

    if (previousRecord != null) {
      // Ask if user wants to copy previous data
      final shouldCopy = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Found Previous Inspection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Would you like to copy data from your previous inspection?'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.access_time, size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        Text(
                          _formatDateTime(previousRecord.updatedAt),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                    if (previousRecord.equipmentCode != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Equipment: ${previousRecord.equipmentCode}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'This will copy all filled data as a starting point.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Start Fresh'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Copy Previous'),
            ),
          ],
        ),
      );

      if (!mounted) return;

      if (shouldCopy == true) {
        // Copy previous data but create a new record
        final copiedRecord = TemplateInspectionRecord(
          recordId: DateTime.now().millisecondsSinceEpoch.toString(),
          templateId: template.templateId,
          templateName: template.templateName,
          status: RecordStatus.draft,
          filledData: Map<String, dynamic>.from(previousRecord.filledData),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          equipmentCode: previousRecord.equipmentCode,
          equipmentName: previousRecord.equipmentName,
          customerName: previousRecord.customerName,
        );

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TemplateFillingScreen(
              template: template,
              existingRecord: copiedRecord,
            ),
          ),
        );
        return;
      }
    }

    // Start fresh inspection
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TemplateFillingScreen(template: template),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} hours ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${dateTime.year}/${dateTime.month}/${dateTime.day}';
    }
  }

  void _showImportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('建立 / 匯入模板'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 主要功能：從真實表單建立模板
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.primary, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(Icons.auto_awesome, color: AppColors.primary, size: 28),
                title: const Text(
                  '從定檢表單建立模板',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('上傳 Excel/Word 表單，AI 自動建立模板'),
                onTap: () {
                  Navigator.pop(context);
                  _createTemplateFromVendorForm();
                },
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.file_upload, color: AppColors.primary),
              title: const Text('從 JSON 檔案匯入'),
              subtitle: const Text('選擇已有的 JSON 模板檔案'),
              onTap: () {
                Navigator.pop(context);
                _importFromFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.code, color: Colors.green),
              title: const Text('從 JSON 文字匯入'),
              subtitle: const Text('貼上 JSON 模板內容'),
              onTap: () {
                Navigator.pop(context);
                _importFromText();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 從真實廠商表單自動建立模板（核心功能）
  Future<void> _createTemplateFromVendorForm() async {
    // Step 1: 選擇 Excel/Word 檔案
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls', 'docx'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;

    if (!mounted) return;

    // Step 2: 填寫模板基本資訊
    final nameController = TextEditingController(
      text: file.name.replaceAll(RegExp(r'\.(xlsx|xls|docx)$'), ''),
    );
    final categoryController = TextEditingController(text: '一般設備');
    final companyController = TextEditingController();
    final departmentController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('模板基本資訊'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.description, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '檔案：${file.name}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '模板名稱 *',
                  hintText: '例如：電機設備定期檢查表',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: categoryController,
                decoration: const InputDecoration(
                  labelText: '設備類別',
                  hintText: '例如：電機設備、泵浦、閥門',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: companyController,
                decoration: const InputDecoration(
                  labelText: '公司名稱',
                  hintText: '例如：台灣電力公司',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: departmentController,
                decoration: const InputDecoration(
                  labelText: '部門',
                  hintText: '例如：維護部',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'AI 將自動分析表單結構，建立可重複使用的檢測模板',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('開始建立'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final templateName = nameController.text.trim();
    if (templateName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請輸入模板名稱')),
      );
      return;
    }

    // Step 3: 顯示建立進度
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在分析「${file.name}」...'),
            const SizedBox(height: 8),
            const Text(
              'AI 正在識別表單欄位並建立模板',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );

    final categoryText = categoryController.text.trim().isEmpty
        ? '一般設備'
        : categoryController.text.trim();
    final companyText = companyController.text.trim();
    final departmentText = departmentController.text.trim();

    try {
      Map<String, dynamic> response;

      // 先嘗試後端 API
      try {
        final api = BackendApiService();
        response = await api.createTemplateFromFile(
          file: file,
          templateName: templateName,
          category: categoryText,
          company: companyText,
          department: departmentText,
        );
      } catch (_) {
        // 後端連線失敗，使用本地建立
        response = {'success': false, 'error': 'backend_unavailable'};
      }

      // 如果後端失敗，使用本地離線建立
      if (response['success'] != true) {
        print('⚡ 後端不可用，使用本地離線模板建立');

        final bytes = file.bytes ?? (file.path != null
            ? await _readFileBytes(file.path!)
            : null);

        if (bytes == null) {
          if (mounted) Navigator.pop(context);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('無法讀取檔案內容'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        final localCreator = LocalTemplateCreator();
        response = await localCreator.createTemplateFromBytes(
          bytes: bytes,
          fileName: file.name,
          templateName: templateName,
          category: categoryText,
          company: companyText,
          department: departmentText,
        );
      }

      // 關閉進度對話框
      if (mounted) Navigator.pop(context);

      if (response['success'] == true && response['template'] != null) {
        // 將模板儲存到本地
        final templateJson = json.encode(response['template']);
        await _templateService.loadTemplateFromJson(templateJson);
        await _loadTemplates();

        if (mounted) {
          final sectionCount = response['section_count'] ?? 0;
          final fieldCount = response['field_count'] ?? 0;
          final isLocal = response['created_locally'] == true;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '模板建立成功！$sectionCount 個區段、$fieldCount 個欄位'
                '${isLocal ? '（離線建立）' : ''}',
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('建立失敗：${response['error'] ?? '未知錯誤'}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      // 關閉進度對話框
      if (mounted) Navigator.pop(context);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('建立失敗：$e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _importFromFile() async {
    // 選擇 JSON 模板檔案
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true, // 確保取得 bytes（跨平台相容）
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無法讀取檔案內容')),
        );
      }
      return;
    }

    final jsonString = utf8.decode(file.bytes!);

    try {
      await _templateService.loadTemplateFromJson(jsonString);
      await _loadTemplates();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模板匯入成功！')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('匯入失敗：$e')),
        );
      }
    }
  }

  Future<void> _importFromText() async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('貼上 JSON 模板'),
        content: TextField(
          controller: controller,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: '請貼上 JSON 格式的模板內容...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('匯入'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        await _templateService.loadTemplateFromJson(result);
        await _loadTemplates();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('模板匯入成功！')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('匯入失敗：$e')),
          );
        }
      }
    }
  }

  /// 從檔案路徑讀取 bytes
  Future<Uint8List?> _readFileBytes(String path) async {
    try {
      final file = File(path);
      return await file.readAsBytes();
    } catch (e) {
      print('讀取檔案失敗: $e');
      return null;
    }
  }
}
